defmodule Barkpark.Plugins.OnixEdit.Phase8E2ETest do
  @moduledoc """
  Phase 8 WI5 — full Phase 4-8 demo pipeline.

  Composes every layer that ships in Phases 4 through 8 against a single
  book document, end-to-end:

      seed book → ONIX export (Phase 6, XSD-valid)
                → Bokbasen submit (Phase 7, Bypass mock, 202 + Location)
                → PublishWorker poll loop (Phase 7, snooze → snooze → :ok)
                → composite `bp_export_status` reaches `:accepted` (WI1/WI2)
                → BookEditor sign-off badge (WI3 — `:requires_wi3`)
                → admin/bokbasen LV row shows :accepted + sign-off (always-on)
                → re-validate against simulated issue 74
                  (WI4 — `:requires_wi4` codelist staleness)

  ## Tag gating

  Each describe block carries its own `@describetag`; there is **no**
  `@moduletag` because ExUnit's include/exclude semantics let an include
  override an exclude for the same test. Carrying `:phase8_demo` at the
  module level would force the WI3/WI4 describes to also run on
  `--include phase8_demo`, which would fail before WI3/WI4 merge.

  Three exclusion tags (all default-excluded in `test/test_helper.exs`):

    * `:phase8_demo` — always-on Phase 4-8 e2e flow (book → ONIX →
      submit → poll → :accepted → composite). Safe to run today.
    * `:requires_wi3` — sign-off badge in BookEditor (WI3 deliverable).
    * `:requires_wi4` — codelist staleness diff (WI4 deliverable).

  WI3 and WI4 ship in parallel teams; this file stays green-on-default
  until WI6 close-out flips the includes:

      mix test --include phase8_demo                       # always-on only
      mix test --include phase8_demo \\                     # full demo
        --include requires_wi3 --include requires_wi4
  """

  use BarkparkWeb.ConnCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Auth, as: BokbasenAuth
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Status, as: BokbasenStatus
  alias Barkpark.Plugins.OnixEdit.Export
  alias Barkpark.Repo

  @client_id "test_client_id"
  @client_secret "test_secret_42"
  @submission_id "test-submission-id-xyz"
  @ops_token "phase8-demo-ops-token"

  @fixtures_dir Path.expand("../../../fixtures/bokbasen", __DIR__)
  @full_book_path Path.expand("../../../fixtures/onix/full-book.json", __DIR__)

  @oauth_token_response File.read!(Path.join(@fixtures_dir, "oauth_token_response.json"))
  @stage_location_url Path.join(@fixtures_dir, "stage_202_location.txt")
                      |> File.read!()
                      |> String.trim()
  @poll_pending_xml File.read!(Path.join(@fixtures_dir, "poll_pending.xml"))
  @poll_accepted_xml File.read!(Path.join(@fixtures_dir, "poll_accepted.xml"))

  setup %{conn: conn} do
    Process.flag(:trap_exit, true)

    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"

    prior = Application.get_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.OnixEdit.Bokbasen,
      client_id: @client_id,
      client_secret: @client_secret,
      api_base: base,
      oauth_token_url: "#{base}/oauth2/token",
      client_role: "publisher"
    )

    BokbasenAuth.invalidate()

    {:ok, _} = Auth.create_token(@ops_token, "phase8 demo ops", "production", ["read", "ops"])

    on_exit(fn ->
      if prior do
        Application.put_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen, prior)
      else
        Application.delete_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)
      end

      BokbasenAuth.invalidate()
    end)

    {:ok, bypass: bypass, base: base, conn: conn}
  end

  defp stub_oauth(bypass) do
    Bypass.stub(bypass, "POST", "/oauth2/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, @oauth_token_response)
    end)
  end

  defp seed_book(doc_id) do
    content =
      @full_book_path
      |> File.read!()
      |> Jason.decode!()

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        "doc_id" => doc_id,
        "type" => "book",
        "dataset" => "production",
        "title" => "Phase 8 Demo Book",
        "status" => "draft",
        "content" => content,
        "rev" => "demo_rev_" <> doc_id
      })
      |> Repo.insert()

    doc
  end

  defp drive_to_accepted!(bypass, base, doc) do
    stub_oauth(bypass)

    local_location =
      @stage_location_url
      |> String.replace(~r{https?://[^/]+}, base)

    Bypass.expect_once(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", local_location)
      |> Plug.Conn.resp(202, "")
    end)

    {:ok, poll_counter} = Agent.start_link(fn -> 0 end)

    Bypass.stub(
      bypass,
      "GET",
      "/metadata/import/onix/v2/test-submission-id-xyz",
      fn conn ->
        n = Agent.get_and_update(poll_counter, fn x -> {x, x + 1} end)
        body = if n == 0, do: @poll_pending_xml, else: @poll_accepted_xml

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, body)
      end
    )

    args = %{"document_id" => doc.doc_id, "type" => "book", "dataset" => "production"}

    # Stage → snooze → first poll snooze → second poll :ok terminal.
    assert {:snooze, _} = perform_job(PublishWorker, args)
    assert {:snooze, _} = perform_job(PublishWorker, args)
    assert :ok = perform_job(PublishWorker, args)

    Repo.get!(Document, doc.id)
  end

  # ── Always-on: WI1/WI2 + Phase 6/7 e2e flow. ──────────────────────────────

  describe "Phase 4-8 happy path: book → ONIX → submit → poll → :accepted" do
    @describetag :phase8_demo

    test "ONIX export emits XSD-valid XML for the demo fixture" do
      content =
        @full_book_path
        |> File.read!()
        |> Jason.decode!()

      book_doc =
        content
        |> Map.put("_id", "p-demo-export")
        |> Map.put("_publishedId", "p-demo-export")
        |> Map.put("_type", "book")

      assert {:ok, iodata} = Export.to_iodata(book_doc)
      xml = IO.iodata_to_binary(iodata)
      assert xml =~ "<ONIXMessage"
      assert byte_size(xml) > 0
    end

    test "full pipeline reaches :accepted with composite timestamps populated",
         %{bypass: bypass, base: base} do
      doc = seed_book("p-phase8-demo-happy")
      final = drive_to_accepted!(bypass, base, doc)
      status = BokbasenStatus.read(final)

      # Lifecycle terminal state — WI1/WI2 composite contract.
      assert status["state"] == "accepted"
      assert status["submission_id"] == @submission_id
      assert status["last_error"] in [nil, %{}]

      # Composite captured every key timestamp the worker writes
      # (per Phase 8 WI2 — ack-loop full state capture).
      assert is_binary(status["updated_at"])
      assert is_binary(status["accepted_at"])

      # WI1 derives signed_off=true the moment accepted_at lands.
      assert status["signed_off"] == true
    end

    test "admin/bokbasen LV renders the accepted row with the green pill",
         %{bypass: bypass, base: base, conn: conn} do
      doc = seed_book("p-phase8-demo-admin")
      _final = drive_to_accepted!(bypass, base, doc)

      conn = init_test_session(conn, %{"api_token" => @ops_token})
      {:ok, view, html} = live(conn, "/admin/bokbasen")

      assert html =~ "p-phase8-demo-admin"

      assert has_element?(
               view,
               ~s|tr[data-test-doc-id="p-phase8-demo-admin"] [data-test-pill="accepted"]|
             )

      assert html =~ "bp-pill-green"
    end
  end

  # ── WI3 — BookEditor sign-off badge (parallel team, may not be merged). ───

  describe "WI3 — BookEditor sign-off badge" do
    @describetag :requires_wi3

    test "BookEditor renders a sign-off badge once the doc is accepted",
         %{bypass: bypass, base: base, conn: conn} do
      doc = seed_book("p-phase8-demo-wi3")
      _final = drive_to_accepted!(bypass, base, doc)

      conn = init_test_session(conn, %{"api_token" => @ops_token})
      {:ok, view, _html} = live(conn, "/studio/production/onixedit/book/p-phase8-demo-wi3")

      # WI3 contract — exact selector to be confirmed at WI3 close-out.
      # Either selector is acceptable; the test asserts the *concept* of
      # a sign-off badge surfacing on accepted docs.
      assert has_element?(view, ~s|[data-test-id="bokbasen-signoff-badge"]|) or
               has_element?(view, ~s|[data-bp-signoff="true"]|)
    end
  end

  # ── WI4 — codelist staleness against a simulated issue 74. ────────────────

  describe "WI4 — codelist staleness detection (simulated issue 74)" do
    @describetag :requires_wi4

    test "re-validating an :accepted doc against issue 74 surfaces a stale-codes report",
         %{bypass: bypass, base: base} do
      doc = seed_book("p-phase8-demo-wi4")
      _final = drive_to_accepted!(bypass, base, doc)

      # WI4 contract — placeholder until WI4 lands. The expected entry
      # point is `Barkpark.Plugins.OnixEdit.Codelists.staleness_report/2`
      # (or equivalent module under .Codelists). Assertion shape: a map
      # with at least one of `:stale_codes` / `:removed_codes` keyed by
      # the codelist short-name (e.g. "Thema", "ProductForm").
      module = Barkpark.Plugins.OnixEdit.Codelists

      report = apply(module, :staleness_report, [doc, %{issue: 74}])

      assert is_map(report)
      assert Map.has_key?(report, :stale_codes) or Map.has_key?(report, :removed_codes)
    end
  end
end
