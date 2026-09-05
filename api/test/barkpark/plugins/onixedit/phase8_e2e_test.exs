defmodule Barkpark.Plugins.OnixEdit.Phase8E2ETest do
  @moduledoc """
  Phase 8 WI5 — full Phase 4-8 demo pipeline.

  Composes every layer that ships in Phases 4 through 8 against a single
  book document, end-to-end:

      seed book → ONIX export (Phase 6, XSD-valid)
                → Bokbasen submit (Phase 7, Bypass mock, 202 + Location)
                → PublishWorker poll loop (Phase 7, snooze → snooze → :ok)
                → composite `bp_export_status` reaches `:accepted` (WI1/WI2)
                → admin/onixedit/bokbasen LV row shows :accepted + sign-off
                → codelist staleness re-validation against issue 74

  ## No tag gating — this file runs in the default lane

  This file used to carry three `@describetag`s — `:phase8_demo`,
  `:requires_wi3` and `:requires_wi4` — all three default-excluded in
  `test/test_helper.exs` "until WI6 close-out flips the includes". WI6
  closed, nothing flipped them, and no CI step ever passed `--include`
  for any of them. The three describes therefore issued NO signal for
  months and rotted red unobserved. All three tags are now removed: the
  file runs on a bare `mix test` like every other test.

  The three parked rows were dispositioned as follows.

    * **:phase8_demo** — REPAIRED AND RE-ENABLED. The admin console LV
      moved from `/admin/bokbasen` to `/admin/onixedit/bokbasen` (the
      old path is now a 301 in `LegacyRedirectController`), so the
      `live/2` call raised a redirect `MatchError`. Call site repointed.

    * **:requires_wi3** — DELETED, capability retired. The describe drove
      `live(conn, "/studio/:dataset/onixedit/book/:id")` and asserted a
      `bokbasen-signoff-badge` element. That URL is no longer a LiveView
      at all — it is a back-compat `get` redirect, because the plugin
      `BookEditor` / `BookView` LiveViews that hosted the badge were
      DELETED on purpose in Goal `barkpark-zdy`; `book` documents now
      open in native StudioLive, which is plugin-agnostic and renders no
      Bokbasen chrome. Neither selector the test accepted
      (`[data-test-id="bokbasen-signoff-badge"]`, `[data-bp-signoff]`)
      exists anywhere in `lib/`, and never did — the test was written as
      a placeholder for a WI3 deliverable whose host surface was
      subsequently retired. Deleting it is not papering over a
      regression: the `signed_off` signal itself is alive
      (`Bokbasen.Status` derives it, and the always-on demo test above
      asserts `status["signed_off"] == true`), and the accepted pill is
      asserted on the admin console. What is genuinely absent is any
      PER-DOCUMENT editor surface for sign-off, which is a product gap
      to decide on, not a broken test to keep red.

    * **:requires_wi4** — REPAIRED AND RE-ENABLED. The describe called
      `apply(Barkpark.Plugins.OnixEdit.Codelists, :staleness_report, …)`
      — a module that does not exist, reached through `apply/3` so the
      compiler could not see it. WI4 DID land, under another name:
      `Barkpark.Plugins.OnixEdit.Codelists.StalenessChecker`, exposing
      `detect_stale/2` and `revalidate/2` (and a live admin console at
      `/admin/onixedit/staleness`). The test now calls the real API by
      direct reference, so a future rename breaks the build instead of
      hiding behind `apply/3`.
  """

  use BarkparkWeb.ConnCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Auth, as: BokbasenAuth
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Status, as: BokbasenStatus
  alias Barkpark.Plugins.OnixEdit.Codelists.StalenessChecker
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
      {:ok, view, html} = live(conn, "/admin/onixedit/bokbasen")

      assert html =~ "p-phase8-demo-admin"

      assert has_element?(
               view,
               ~s|tr[data-test-doc-id="p-phase8-demo-admin"] [data-test-pill="accepted"]|
             )

      assert html =~ "bp-pill-green"
    end
  end

  # ── WI3 — DELETED. The BookEditor LV that hosted the sign-off badge was
  # removed on purpose in Goal `barkpark-zdy`; `/studio/:dataset/onixedit/
  # book/:id` is a back-compat 301 today, not a LiveView, and no
  # per-document editor renders Bokbasen chrome. Full reasoning in the
  # moduledoc. The `signed_off` derivation is still covered by the
  # always-on pipeline test above.

  # ── WI4 — codelist staleness against a simulated issue 74. ────────────────

  describe "WI4 — codelist staleness detection (simulated issue 74)" do
    test "re-validating an :accepted doc against issue 74 surfaces stale codelist refs",
         %{bypass: bypass, base: base} do
      doc = seed_book("p-phase8-demo-wi4")
      final = drive_to_accepted!(bypass, base, doc)

      # StalenessChecker only sees refs carrying BOTH `codelistId` and
      # `issue_version` (see its moduledoc). The shipped ONIX fixture has
      # no pin slots, so pin two refs here: one behind the current issue
      # and one already on it. Pure function — no DB write needed, and
      # nothing outside this doc is touched.
      pinned =
        final.content
        |> Map.put("contributorRoleRef", %{
          "codelistId" => "onixedit:contributor_role",
          "issue_version" => "73",
          "code" => "A01"
        })
        |> Map.put("productFormRef", %{
          "codelistId" => "onixedit:product_form",
          "issue_version" => "74",
          "code" => "BB"
        })

      doc_at_74 = %{final | content: pinned}

      # ── detect_stale/2 — per-ref classification against issue 74. ──────
      report = StalenessChecker.detect_stale(doc_at_74, "74")

      assert is_list(report)

      by_path = Map.new(report, &{&1.path, &1})

      assert %{status: :stale, ref_issue: "73", current_issue: "74"} =
               by_path["contributorRoleRef"]

      assert %{status: :current} = by_path["productFormRef"]

      # ── revalidate/2 — the diff the admin console renders. ─────────────
      diff =
        StalenessChecker.revalidate(doc_at_74, %{
          "onixedit:contributor_role" => %{issue_version: "74", codes: ["A01"]},
          "onixedit:product_form" => %{issue_version: "74", codes: ["BB"]}
        })

      assert %{added: _, removed: _, changed: changed} = diff

      assert Enum.any?(changed, fn c ->
               c.codelist == "onixedit:contributor_role" and c.from == "73" and c.to == "74"
             end),
             "expected the issue-73 ref to appear in :changed, got: #{inspect(changed)}"
    end
  end
end
