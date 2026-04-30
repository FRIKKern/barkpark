defmodule Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorkerTest do
  # async: false because Auth is a singleton GenServer and tests
  # mutate Application env for credentials.
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import ExUnit.CaptureLog

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Auth
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Barkpark.Repo

  @moduletag :bokbasen_worker

  @client_id "test_client_id"
  @client_secret "test_secret_42"
  @bearer "test_access_token_xyz"

  @full_book_path Path.expand("../../../../fixtures/onix/full-book.json", __DIR__)

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
    end)

    {:ok, bypass: bypass, base: base}
  end

  defp stub_token(bypass) do
    Bypass.stub(bypass, "POST", "/oauth2/token", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"access_token" => @bearer, "expires_in" => 3600}))
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
        "title" => "Test Book",
        "status" => "draft",
        "content" => content,
        "rev" => "test_rev_" <> doc_id
      })
      |> Repo.insert()

    doc
  end

  defp seed_minimal_book(doc_id, bp_export_status_json) do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        "doc_id" => doc_id,
        "type" => "book",
        "dataset" => "production",
        "title" => "Resume Book",
        "status" => "draft",
        "content" => %{"bp_export_status" => bp_export_status_json},
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

  describe "happy path" do
    test "stage → poll(pending) → poll(accepted) and persists submission_id", %{
      bypass: bypass,
      base: base
    } do
      stub_token(bypass)
      doc = seed_book("p9")

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        body =
          Jason.encode!(%{
            "submission_id" => "sub-happy",
            "poll_url" => "#{base}/metadata/import/onix/v2/status/sub-happy"
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(202, body)
      end)

      {:ok, poll_counter} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "GET", "/metadata/import/onix/v2/status/sub-happy", fn conn ->
        n = Agent.get_and_update(poll_counter, fn x -> {x, x + 1} end)
        body = if n == 0, do: ~s({"status":"pending"}), else: ~s({"status":"accepted"})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      # 1st perform: stage → snooze
      assert {:snooze, _} = perform_job(PublishWorker, args(doc.doc_id))
      reloaded = reload(doc)
      s = status_of(reloaded)
      assert s["state"] == "staged"
      assert s["bokbasen_submission_id"] == "sub-happy"

      # 2nd perform: poll → pending → snooze
      assert {:snooze, _} = perform_job(PublishWorker, args(doc.doc_id))
      assert status_of(reload(doc))["state"] == "polling"

      # 3rd perform: poll → accepted → :ok
      assert :ok = perform_job(PublishWorker, args(doc.doc_id))
      final = status_of(reload(doc))
      assert final["state"] == "accepted"
      assert final["bokbasen_submission_id"] == "sub-happy"
    end
  end

  describe "NetworkError retry" do
    test "Bypass.down on stage → {:error, NetworkError} on attempt 1, terminal failed at attempt 3",
         %{bypass: bypass} do
      stub_token(bypass)
      # Warm token cache while server is up.
      assert {:ok, _} = Auth.token()

      doc = seed_book("p-net")
      Bypass.down(bypass)

      # attempt 1 — network error, retry
      assert {:error, _} = perform_job(PublishWorker, args(doc.doc_id), attempt: 1)

      # attempt 3 — exhausted, terminal :failed
      assert {:cancel, :exhausted} = perform_job(PublishWorker, args(doc.doc_id), attempt: 3)

      s = status_of(reload(doc))
      assert s["state"] == "failed"
      assert s["last_error"]["type"] == "network_exhausted"
    end
  end

  describe "AuthError terminal" do
    test "401 → :failed, no retry", %{bypass: bypass} do
      stub_token(bypass)

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        Plug.Conn.resp(conn, 401, ~s({"error":"unauthorized"}))
      end)

      doc = seed_book("p-auth")

      assert {:cancel, :auth_failed} = perform_job(PublishWorker, args(doc.doc_id), attempt: 1)

      s = status_of(reload(doc))
      assert s["state"] == "failed"
      assert s["last_error"]["type"] == "auth"
    end
  end

  describe "SchemaRejectionError terminal" do
    test "422 → :failed with details persisted", %{bypass: bypass} do
      stub_token(bypass)

      details_body = ~s({"errors":[{"code":"INVALID_ISBN","field":"product_identifier"}]})

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(422, details_body)
      end)

      doc = seed_book("p-rej")

      assert {:cancel, :schema_rejected} =
               perform_job(PublishWorker, args(doc.doc_id), attempt: 1)

      s = status_of(reload(doc))
      assert s["state"] == "failed"
      assert s["last_error"]["type"] == "schema_rejection"
      assert s["last_error"]["summary"] =~ "INVALID_ISBN"
    end
  end

  describe "idempotent re-enqueue" do
    test "submission_id already present skips stage and resumes polling", %{bypass: bypass} do
      stub_token(bypass)

      pre =
        Jason.encode!(%{
          "state" => "staged",
          "bokbasen_submission_id" => "pre-set-123",
          "poll_url" => nil,
          "last_error" => nil
        })

      doc = seed_minimal_book("p-idem", pre)

      stage_calls = Agent.start_link(fn -> 0 end) |> elem(1)

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        Agent.update(stage_calls, &(&1 + 1))
        Plug.Conn.resp(conn, 500, "should-not-be-called")
      end)

      Bypass.stub(bypass, "GET", "/metadata/import/onix/v2/status/pre-set-123", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"status":"accepted"}))
      end)

      assert :ok = perform_job(PublishWorker, args(doc.doc_id))

      assert Agent.get(stage_calls, & &1) == 0
      s = status_of(reload(doc))
      assert s["state"] == "accepted"
      assert s["bokbasen_submission_id"] == "pre-set-123"
    end
  end

  describe "concurrent enqueue blocked" do
    test "second insert within unique window returns the existing job", %{bypass: _bypass} do
      doc = seed_book("p-uniq")

      {:ok, job1} = Oban.insert(PublishWorker.new(args(doc.doc_id)))
      {:ok, job2} = Oban.insert(PublishWorker.new(args(doc.doc_id)))

      assert job1.id == job2.id

      count =
        Repo.aggregate(
          from(j in Oban.Job,
            where:
              j.worker == "Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker" and
                j.state in ["available", "scheduled"]
          ),
          :count,
          :id
        )

      assert count == 1
    end
  end

  describe "cancel/3" do
    test "204 from Bokbasen → :ok, state cancelled", %{bypass: bypass} do
      stub_token(bypass)

      pre =
        Jason.encode!(%{
          "state" => "polling",
          "bokbasen_submission_id" => "sub-cancel",
          "poll_url" => nil,
          "last_error" => nil
        })

      doc = seed_minimal_book("p-cancel-ok", pre)

      Bypass.expect(bypass, "DELETE", "/metadata/import/onix/v2/sub-cancel", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = PublishWorker.cancel(doc.doc_id, "book", "production")

      s = status_of(reload(doc))
      assert s["state"] == "cancelled"
      assert s["bokbasen_submission_id"] == "sub-cancel"
    end

    test "404 from Bokbasen → :cannot_cancel with warning logged", %{bypass: bypass} do
      stub_token(bypass)

      pre =
        Jason.encode!(%{
          "state" => "polling",
          "bokbasen_submission_id" => "sub-stuck",
          "poll_url" => nil,
          "last_error" => nil
        })

      doc = seed_minimal_book("p-cancel-404", pre)

      Bypass.stub(bypass, "DELETE", "/metadata/import/onix/v2/sub-stuck", fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"error":"not_found"}))
      end)

      log =
        capture_log(fn ->
          assert {:error, :cannot_cancel} = PublishWorker.cancel(doc.doc_id, "book", "production")
        end)

      assert log =~ "404"
      assert log =~ "NotificationType"

      s = status_of(reload(doc))
      assert s["state"] == "cannot_cancel"
      assert s["last_error"]["type"] == "cannot_cancel"
      assert s["last_error"]["http_status"] == 404
      assert s["last_error"]["note"] =~ "NotificationType=05"
    end
  end

  describe "PubSub broadcast on persist_status (WI5)" do
    test "stage success broadcasts {:bokbasen_status_update, status_map}", %{
      bypass: bypass,
      base: base
    } do
      stub_token(bypass)
      doc = seed_book("p-broadcast")

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        body =
          Jason.encode!(%{
            "submission_id" => "sub-bcast",
            "poll_url" => "#{base}/metadata/import/onix/v2/status/sub-bcast"
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(202, body)
      end)

      :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, "bokbasen:document:#{doc.doc_id}")

      assert {:snooze, _} = perform_job(PublishWorker, args(doc.doc_id))

      # `stage_step` calls persist_status twice: once with state=staging, then
      # again with state=staged after Bokbasen accepts the upload. We assert
      # both transitions arrive on the per-doc topic in order.
      assert_receive {:bokbasen_status_update, %{"state" => "staging"}}, 1_000
      assert_receive {:bokbasen_status_update, %{"state" => "staged"} = staged}, 1_000
      assert staged["bokbasen_submission_id"] == "sub-bcast"
    end

    test "persist_status/2 is callable directly and broadcasts" do
      doc = seed_book("p-direct")

      :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, "bokbasen:document:#{doc.doc_id}")

      _updated = PublishWorker.persist_status(doc, %{"state" => "pending"})

      assert_receive {:bokbasen_status_update, %{"state" => "pending"}}, 1_000
    end
  end

  describe "poll parse graceful failure" do
    test "malformed poll body → :rejected with parse-error context, no crash", %{bypass: bypass} do
      stub_token(bypass)

      pre =
        Jason.encode!(%{
          "state" => "polling",
          "bokbasen_submission_id" => "sub-malformed",
          "poll_url" => nil,
          "last_error" => nil
        })

      doc = seed_minimal_book("p-malformed", pre)

      Bypass.stub(bypass, "GET", "/metadata/import/onix/v2/status/sub-malformed", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, "<<<garbage that is neither valid JSON nor parseable XML>>>")
      end)

      assert {:cancel, :poll_parse_error} = perform_job(PublishWorker, args(doc.doc_id))

      s = status_of(reload(doc))
      assert s["state"] == "rejected"
      assert s["last_error"]["type"] == "poll_parse_error"
      assert s["last_error"]["http_status"] == 200
    end
  end
end
