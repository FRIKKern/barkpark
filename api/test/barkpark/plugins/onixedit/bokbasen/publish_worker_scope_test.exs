defmodule Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorkerScopeTest do
  @moduledoc """
  barkpark-zdvi — cross-tenant isolation for the OnixEdit publish/cancel
  book reads.

  Before the fix, `PublishWorker.perform/1`, `PublishWorker.cancel/4`, and
  `Actions.publish_to_bokbasen/3` resolved the book via an UNSCOPED
  `Content.get_document(doc_id, "book", dataset)`. Two workspaces sharing the
  `"production"` dataset string therefore resolved to the SAME (or the wrong)
  tenant's row. These tests stand up two distinct workspaces and assert:

    * a job/action resolved to workspace B does NOT load workspace A's book,
    * an in-scope (workspace A) publish/cancel loads the right book,
    * a legacy job with NO scope args still works (Default resolution, no
      crash).
  """
  # async: false because Auth is a singleton GenServer and tests mutate
  # Application env for credentials (mirrors PublishWorkerTest).
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Plugins.OnixEdit.Actions
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Auth
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker

  @moduletag :bokbasen_worker

  @client_id "test_client_id"
  @client_secret "test_secret_42"
  @bearer "test_access_token_xyz"

  @full_book_path Path.expand("../../../../fixtures/onix/full-book.json", __DIR__)

  setup do
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

    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    {:ok,
     bypass: bypass,
     base: base,
     scope_a: [workspace_id: ws_a.id, project_id: proj_a.id],
     scope_b: [workspace_id: ws_b.id, project_id: proj_b.id]}
  end

  defp stub_token(bypass) do
    Bypass.stub(bypass, "POST", "/oauth2/token", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"access_token" => @bearer, "expires_in" => 3600}))
    end)
  end

  # Seed a full (XSD-valid) book in the given workspace/project scope via the
  # canonical create path so workspace_id/project_id/dataset_id are stamped.
  defp seed_book_in(scope, doc_id) do
    content =
      @full_book_path
      |> File.read!()
      |> Jason.decode!()

    {:ok, doc} =
      Content.create_document(
        "book",
        %{"doc_id" => doc_id, "title" => "Scoped Book", "content" => content},
        "production",
        scope
      )

    doc
  end

  # Seed a minimal book carrying a recorded submission_id (for cancel tests).
  defp seed_book_with_submission(scope, doc_id, sub_id) do
    status =
      Jason.encode!(%{
        "state" => "polling",
        "bokbasen_submission_id" => sub_id,
        "poll_url" => nil,
        "last_error" => nil
      })

    {:ok, doc} =
      Content.create_document(
        "book",
        %{
          "doc_id" => doc_id,
          "title" => "Cancel Book",
          "content" => %{"bp_export_status" => status}
        },
        "production",
        scope
      )

    doc
  end

  # Read the scope keys back out of an Oban arg map into get_document opts.
  defp scope_args(scope), do: PublishWorker.put_scope_args(%{}, scope)

  defp worker_args(doc_id, scope) do
    %{"document_id" => doc_id, "type" => "book", "dataset" => "production"}
    |> Map.merge(scope_args(scope))
  end

  describe "perform/1 cross-tenant isolation" do
    test "job scoped to workspace B does NOT load workspace A's book", %{
      bypass: bypass,
      scope_a: scope_a,
      scope_b: scope_b
    } do
      stub_token(bypass)
      doc_a = seed_book_in(scope_a, "book-iso-1")

      # No Bokbasen stage stub on purpose — if the worker DID find A's book it
      # would attempt a stage POST and crash/error; instead the scoped-to-B
      # read must miss and the worker must cancel with :document_missing.
      assert {:cancel, :document_missing} =
               perform_job(PublishWorker, worker_args(doc_a.doc_id, scope_b))

      # A's book is untouched: a B-scoped run must not write a worker
      # transition state ("staging"/"staged"/…) onto A's doc. (The book may
      # carry an initial bp_export_status from the schema's initial_values;
      # what matters is the worker never advanced A's state.)
      assert {:ok, reloaded} = Content.get_document(doc_a.doc_id, "book", "production", scope_a)
      status = reloaded.content["bp_export_status"]
      status = if is_binary(status), do: Jason.decode!(status), else: status || %{}
      refute Map.get(status, "state") in ~w(staging staged polling)
    end

    test "in-scope (workspace A) job loads A's book and stages", %{
      bypass: bypass,
      base: base,
      scope_a: scope_a
    } do
      stub_token(bypass)
      doc_a = seed_book_in(scope_a, "book-iso-2")

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        body =
          Jason.encode!(%{
            "submission_id" => "sub-scoped-a",
            "poll_url" => "#{base}/metadata/import/onix/v2/status/sub-scoped-a"
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(202, body)
      end)

      assert {:snooze, _} = perform_job(PublishWorker, worker_args(doc_a.doc_id, scope_a))

      assert {:ok, reloaded} = Content.get_document(doc_a.doc_id, "book", "production", scope_a)
      status = reloaded.content["bp_export_status"]
      status = if is_binary(status), do: Jason.decode!(status), else: status
      assert status["state"] == "staged"
      assert status["submission_id"] == "sub-scoped-a"
    end

    test "back-compat: a legacy job with NO scope args still resolves (Default)", %{
      bypass: bypass,
      base: base
    } do
      stub_token(bypass)
      # Default-scoped book (flat back-compat write — no explicit workspace).
      {:ok, doc} =
        Content.create_document(
          "book",
          %{
            "doc_id" => "book-legacy-1",
            "title" => "Legacy Book",
            "content" => @full_book_path |> File.read!() |> Jason.decode!()
          },
          "production",
          []
        )

      Bypass.stub(bypass, "POST", "/metadata/import/onix/v2", fn conn ->
        body =
          Jason.encode!(%{
            "submission_id" => "sub-legacy",
            "poll_url" => "#{base}/metadata/import/onix/v2/status/sub-legacy"
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(202, body)
      end)

      # args WITHOUT workspace_id/project_id — the shape an old enqueued job has.
      legacy_args = %{"document_id" => doc.doc_id, "type" => "book", "dataset" => "production"}
      assert {:snooze, _} = perform_job(PublishWorker, legacy_args)

      assert {:ok, reloaded} = Content.get_document(doc.doc_id, "book", "production", [])
      status = reloaded.content["bp_export_status"]
      status = if is_binary(status), do: Jason.decode!(status), else: status
      assert status["state"] == "staged"
    end
  end

  describe "cancel/4 cross-tenant isolation" do
    test "cancel scoped to workspace B does NOT touch workspace A's book", %{
      bypass: bypass,
      scope_a: scope_a,
      scope_b: scope_b
    } do
      stub_token(bypass)
      doc_a = seed_book_with_submission(scope_a, "book-cancel-iso", "sub-a-only")

      # No DELETE stub — a leak would try to cancel A's submission. Scoped to B
      # the read must miss → :not_found, and A's state stays "polling".
      assert {:error, :not_found} =
               PublishWorker.cancel(doc_a.doc_id, "book", "production", scope_b)

      assert {:ok, reloaded} = Content.get_document(doc_a.doc_id, "book", "production", scope_a)
      status = reloaded.content["bp_export_status"]
      status = if is_binary(status), do: Jason.decode!(status), else: status
      assert status["state"] == "polling"
    end

    test "in-scope (workspace A) cancel loads A's book and cancels", %{
      bypass: bypass,
      scope_a: scope_a
    } do
      stub_token(bypass)
      doc_a = seed_book_with_submission(scope_a, "book-cancel-ok", "sub-cancel-a")

      Bypass.expect(bypass, "DELETE", "/metadata/import/onix/v2/sub-cancel-a", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = PublishWorker.cancel(doc_a.doc_id, "book", "production", scope_a)

      assert {:ok, reloaded} = Content.get_document(doc_a.doc_id, "book", "production", scope_a)
      status = reloaded.content["bp_export_status"]
      status = if is_binary(status), do: Jason.decode!(status), else: status
      assert status["state"] == "cancelled"
    end
  end

  describe "Actions.publish_to_bokbasen/4 cross-tenant isolation" do
    test "dryrun scoped to workspace B does NOT load workspace A's book", %{
      scope_a: scope_a,
      scope_b: scope_b
    } do
      _doc_a = seed_book_in(scope_a, "book-action-iso")

      assert {:error, :no_doc} =
               Actions.publish_to_bokbasen("book-action-iso", "production", :dryrun, scope_b)
    end

    test "in-scope (workspace A) dryrun loads A's book and previews", %{scope_a: scope_a} do
      _doc_a = seed_book_in(scope_a, "book-action-ok")

      assert {:ok, %{kind: :xml, xml: xml}} =
               Actions.publish_to_bokbasen("book-action-ok", "production", :dryrun, scope_a)

      assert is_binary(xml)
    end

    test "real publish enqueues a job carrying the action's scope", %{scope_a: scope_a} do
      _doc_a = seed_book_in(scope_a, "book-action-real")

      assert {:ok, %{job: job}} =
               Actions.publish_to_bokbasen("book-action-real", "production", :real, scope_a)

      assert job.args["workspace_id"] == Keyword.fetch!(scope_a, :workspace_id)
      assert job.args["project_id"] == Keyword.fetch!(scope_a, :project_id)
    end

    test "back-compat arity-3 publish still works (Default resolution)", %{} do
      {:ok, _doc} =
        Content.create_document(
          "book",
          %{
            "doc_id" => "book-action-legacy",
            "title" => "Legacy Action Book",
            "content" => @full_book_path |> File.read!() |> Jason.decode!()
          },
          "production",
          []
        )

      assert {:ok, %{kind: :xml}} =
               Actions.publish_to_bokbasen("book-action-legacy", "production", :dryrun)
    end
  end
end
