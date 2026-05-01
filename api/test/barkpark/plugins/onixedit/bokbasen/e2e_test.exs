defmodule Barkpark.Plugins.OnixEdit.Bokbasen.E2ETest do
  @moduledoc """
  WI7 — End-to-end happy-path integration test for the Bokbasen
  publishing pipeline.

  Drives `Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker` against a
  Bypass mock that loads its responses from the redacted fixtures under
  `api/test/fixtures/bokbasen/`. Exercises the full state machine:

      :pending → :staging → :staged → :polling → :accepted

  All credentials and IDs in these fixtures are synthetic — `test_*`
  prefixes, `api.example.com` URLs — and the test never reaches a real
  Bokbasen endpoint. This is the closing artifact of Phase 7 and the
  one place a future contributor can read to see how the WI2/WI3/WI4/WI5
  modules compose against an external mock.

  ## Tag gate

  `@moduletag :bokbasen_integration` — excluded by default via
  `test/test_helper.exs`. Run explicitly with:

      cd api && mix test --include bokbasen_integration

  See `docs/spec/bokbasen-api-contract.md` ("How to test") and
  the README's "Phase 7: Bokbasen integration" section.
  """

  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Auth
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Client
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Barkpark.Plugins.OnixEdit.Export
  alias Barkpark.Repo

  @moduletag :bokbasen_integration

  @client_id "test_client_id"
  @client_secret "test_secret_42"

  @fixtures_dir Path.expand("../../../../fixtures/bokbasen", __DIR__)
  @full_book_path Path.expand("../../../../fixtures/onix/full-book.json", __DIR__)

  @oauth_token_response File.read!(Path.join(@fixtures_dir, "oauth_token_response.json"))
  @stage_location_url Path.join(@fixtures_dir, "stage_202_location.txt")
                      |> File.read!()
                      |> String.trim()
  @poll_pending_xml File.read!(Path.join(@fixtures_dir, "poll_pending.xml"))
  @poll_accepted_xml File.read!(Path.join(@fixtures_dir, "poll_accepted.xml"))
  @poll_rejected_xml File.read!(Path.join(@fixtures_dir, "poll_rejected.xml"))
  @error_401_body File.read!(Path.join(@fixtures_dir, "error_401.json"))
  @error_429_body File.read!(Path.join(@fixtures_dir, "error_429.json"))
  @error_500_body File.read!(Path.join(@fixtures_dir, "error_500.json"))

  # The poll URL we instruct Bokbasen to give us back is rewritten to point
  # at the local Bypass server in setup, so the fixture's `api.example.com`
  # URL never escapes into a real network call.
  @submission_id "test-submission-id-xyz"

  setup do
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

    Auth.invalidate()

    on_exit(fn ->
      if prior do
        Application.put_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen, prior)
      else
        Application.delete_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)
      end

      Auth.invalidate()
    end)

    {:ok, bypass: bypass, base: base}
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
        "title" => "WI7 E2E Test Book",
        "status" => "draft",
        "content" => content,
        "rev" => "test_rev_" <> doc_id
      })
      |> Repo.insert()

    doc
  end

  defp reload(%Document{} = doc), do: Repo.get!(Document, doc.id)

  defp status_of(%Document{content: content}) do
    case Map.get(content, "bp_export_status") do
      nil -> %{}
      str when is_binary(str) -> Jason.decode!(str)
      m when is_map(m) -> m
    end
  end

  defp args(doc_id),
    do: %{"document_id" => doc_id, "type" => "book", "dataset" => "production"}

  # ---------------------------------------------------------------------------
  # Pre-flight: rendered ONIX must clear XSD validation so the worker won't
  # short-circuit with {:error, {:xsd_invalid, _}} before even reaching the
  # HTTP layer. This is the same gate Phase 6 WI8 (proof fixture) enforces.
  # ---------------------------------------------------------------------------

  describe "pre-flight: ONIX export validates against XSD" do
    test "Export.to_iodata/1 on full-book fixture is XSD-valid" do
      content =
        @full_book_path
        |> File.read!()
        |> Jason.decode!()

      book_doc =
        content
        |> Map.put("_id", "p9")
        |> Map.put("_publishedId", "p9")
        |> Map.put("_type", "book")

      assert {:ok, iodata} = Export.to_iodata(book_doc)
      assert IO.iodata_length(iodata) > 0
    end
  end

  # ---------------------------------------------------------------------------
  # Happy path — the whole point of WI7.
  #
  # 1. PublishWorker reads document, renders ONIX, posts to /metadata/...
  # 2. Bypass returns 202 + Location → submission_id parsed.
  # 3. Worker snoozes; on second perform_job it polls.
  # 4. First poll returns the UNPROCESSED XML fixture → status :pending.
  # 5. Second poll returns the COMPLETED XML fixture → status :accepted.
  # 6. Document content's `bp_export_status` JSON ends in
  #    state="accepted" with the submission_id persisted.
  # 7. Phoenix.PubSub broadcasts arrive in lifecycle order:
  #    staging → staged → polling → accepted.
  # ---------------------------------------------------------------------------

  describe "happy path: stage → poll(pending) → poll(accepted)" do
    test "drives full lifecycle from redacted fixtures and persists final status",
         %{bypass: bypass, base: base} do
      stub_oauth(bypass)

      # Rewrite the fixture's example.com Location URL so it points at the
      # local Bypass server. The fixture is the source of truth for the
      # *shape* of the URL; the host swap is purely a test-side rewrite.
      local_location =
        @stage_location_url
        |> String.replace(~r{https?://[^/]+}, base)

      Bypass.expect_once(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        # Sanity: the worker did send our Authorization bearer.
        ["Bearer test_access_token_xyz"] = Plug.Conn.get_req_header(conn, "authorization")

        # And the Onix-Block-access header for publisher role.
        [block_access] = Plug.Conn.get_req_header(conn, "onix-block-access")
        assert block_access == "0,1,2,3,4,5,6,7,8,9,10,11,12"

        # And the body is XML (don't deeply parse — the export pipeline has
        # its own coverage; we just confirm the worker handed us non-empty
        # ONIX).
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "<ONIXMessage"

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

      doc = seed_book("p-e2e-happy")

      :ok =
        Phoenix.PubSub.subscribe(
          Barkpark.PubSub,
          "bokbasen:document:#{doc.doc_id}"
        )

      # 1) Stage step → snooze waiting for the first poll.
      assert {:snooze, secs1} = perform_job(PublishWorker, args(doc.doc_id))
      assert is_integer(secs1) and secs1 > 0

      after_stage = status_of(reload(doc))
      assert after_stage["state"] == "staged"
      assert after_stage["submission_id"] == @submission_id
      assert after_stage["last_error"] in [nil, %{}]

      # PubSub: staging then staged.
      assert_receive {:bokbasen_status_update, %{"state" => "staging"}}, 1_000
      assert_receive {:bokbasen_status_update, %{"state" => "staged"} = staged_msg}, 1_000
      assert staged_msg["submission_id"] == @submission_id

      # 2) First poll → UNPROCESSED → :pending → snooze.
      assert {:snooze, secs2} = perform_job(PublishWorker, args(doc.doc_id))
      assert is_integer(secs2) and secs2 > 0

      after_poll1 = status_of(reload(doc))
      assert after_poll1["state"] == "polling"
      assert after_poll1["submission_id"] == @submission_id
      assert after_poll1["last_error"] in [nil, %{}]

      assert_receive {:bokbasen_status_update, %{"state" => "polling"}}, 1_000

      # 3) Second poll → COMPLETED → :accepted → :ok terminal.
      assert :ok = perform_job(PublishWorker, args(doc.doc_id))

      assert_receive {:bokbasen_status_update, %{"state" => "accepted"}}, 1_000

      final = status_of(reload(doc))

      # Contract shape per docs/spec/bokbasen-api-contract.md and WI4 worker:
      assert final["state"] == "accepted"
      assert final["submission_id"] == @submission_id
      assert final["last_error"] in [nil, %{}]
      assert is_binary(final["updated_at"])
      # XML-poll details survive the parse so operators can inspect raw
      # response shape post-hoc.
      assert is_map(final["details"])
      assert final["details"]["state"] == "COMPLETED"

      assert Agent.get(poll_counter, & &1) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Secondary: prove the rejected/failed fixtures parse the way the contract
  # expects. Drives `Client.poll/2` directly so the test is fast and targets
  # the parse path the worker depends on.
  # ---------------------------------------------------------------------------

  describe "rejected fixture parses to {:rejected, _}" do
    test "Client.poll/2 maps <state>FAILED</state> XML to :rejected", %{
      bypass: bypass,
      base: base
    } do
      stub_oauth(bypass)

      Bypass.expect_once(
        bypass,
        "GET",
        "/metadata/import/onix/v2/status/test-submission-id-xyz",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/xml")
          |> Plug.Conn.resp(200, @poll_rejected_xml)
        end
      )

      assert {:ok, %{status: :rejected, details: details}} =
               Client.poll(@submission_id, base_url: base, max_retries: 0)

      assert details["state"] == "FAILED"
      assert is_binary(details["raw"])
      assert details["raw"] =~ "Synthetic ONIX validation error"
    end
  end

  # ---------------------------------------------------------------------------
  # Sanity: the redacted fixtures contain no real-looking credentials. This
  # is a belt-and-suspenders check on top of the pre-stage `git diff` grep
  # in the WI7 brief.
  # ---------------------------------------------------------------------------

  describe "fixture redaction guard" do
    test "fixtures contain only synthetic test_* / example.com markers" do
      blob =
        Enum.join(
          [
            @oauth_token_response,
            @stage_location_url,
            @poll_pending_xml,
            @poll_accepted_xml,
            @poll_rejected_xml,
            @error_401_body,
            @error_429_body,
            @error_500_body
          ],
          "\n"
        )

      refute blob =~ ~r/bokbasen\.no/i
      refute blob =~ ~r/login\.boknett\.no/i
      # No long opaque hex blobs that could pass for a real bearer.
      refute blob =~ ~r/[A-Fa-f0-9]{32,}/
    end
  end
end
