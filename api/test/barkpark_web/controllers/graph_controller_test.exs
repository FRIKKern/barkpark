defmodule BarkparkWeb.GraphControllerTest do
  @moduledoc """
  Goal ges/graph-edge-seam Phase 4 — contract tests for the `/v1/graph/*`
  surface (`graph_show`, `graph_orphans`, `graph_dangling` on
  `BarkparkWeb.TasksController`).

  The headline test is the ROUTE-PRESENCE assertion: `GET /v1/graph/<id>` MUST
  NOT 404. Because `register_routes/1` is read at MACRO EXPANSION via
  `Registry.collect_routes/1`, a STALE router beam yields a 404 identical to a
  missing route. This test is the trip-wire that catches a future stale beam —
  the Phase-4 verify recipe nukes the test router beam before compiling
  precisely so this passes.

    * route presence: GET /v1/graph/<id> is NOT 404 (the stale-beam guard).
    * graph_show roots on a NON-task content doc (gap #4 generic root).
    * graph_show 404s for an unknown id.
    * graph_orphans returns 200 with an `orphans` list.
    * graph_dangling returns 200 with a `dangling` list.
    * auth: 401 without a token.
  """

  use BarkparkWeb.ConnCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.EdgeProjector.ProjectorWorker

  @token "barkpark-test-graph-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-graph", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    # A plain non-task content schema so we prove graph_show roots on ANY type
    # (gap #4) — NOT just tasks.
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    %{scope: scope}
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp mk_post!(doc_id, scope) do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => %{}},
        @dataset,
        scope
      )

    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "auth gating" do
    test "GET /v1/graph/orphans returns 401 without a token", %{conn: conn} do
      resp = get(conn, "/v1/graph/orphans")
      assert resp.status == 401
    end
  end

  describe "route presence (stale-router-beam guard)" do
    test "GET /v1/graph/<id> is NOT 404 — the route is mounted", %{conn: conn, scope: scope} do
      doc_id = uniq("graph-route")
      _post = mk_post!(doc_id, scope)

      resp = conn |> authed() |> get("/v1/graph/#{doc_id}")

      # The CARDINAL assertion: a NET-NEW route read at macro-expansion is only
      # live if the router beam was recompiled. A stale beam → 404. We assert the
      # route resolves (200), which can ONLY happen if the route is mounted.
      refute resp.status == 404,
             "GET /v1/graph/:id 404ed — router beam is STALE (recompile required)"

      assert resp.status == 200
    end
  end

  describe "GET /v1/graph/:id" do
    test "roots on a NON-task content doc (gap #4 generic root)", %{conn: conn, scope: scope} do
      doc_id = uniq("graph-post")
      _post = mk_post!(doc_id, scope)

      resp = conn |> authed() |> get("/v1/graph/#{doc_id}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert body["root"] == doc_id
      assert is_list(body["nodes"])
      assert is_list(body["edges"])
      assert is_list(body["dependents"])
      assert Map.has_key?(body, "truncated")
      assert Map.has_key?(body, "truncation_reason")
    end

    test "404s for an unknown id", %{conn: conn} do
      resp =
        conn |> authed() |> get("/v1/graph/no-such-doc-#{System.unique_integer([:positive])}")

      assert resp.status == 404
    end
  end

  describe "GET /v1/graph/orphans" do
    test "returns 200 with an orphans list", %{conn: conn, scope: scope} do
      _orphan = mk_post!(uniq("orphan"), scope)

      resp = conn |> authed() |> get("/v1/graph/orphans?dataset=#{@dataset}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert is_list(body["orphans"])
    end
  end

  describe "GET /v1/graph/dangling" do
    test "returns 200 with a dangling list", %{conn: conn} do
      resp = conn |> authed() |> get("/v1/graph/dangling?dataset=#{@dataset}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert is_list(body["dangling"])
    end
  end

  # ── GET /v1/graph/:id/tasks — the expectation reverse view (lvw-t8) ────────

  describe "GET /v1/graph/:id/tasks" do
    # The REAL task schemas (edge extraction is schema-declared; the
    # `design_doc` reference field must be the genuine article).
    defp register_task_schemas!(scope) do
      for schema_def <- Tasks.schema_definitions(@dataset) do
        attrs =
          schema_def
          |> Map.from_struct()
          |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
      end
    end

    defp publish_task_citing!(paper_doc_id, task_doc_id, scope, content_extra) do
      content =
        Map.merge(
          %{"kind" => "task", "lifecycle_status" => "open", "design_doc" => paper_doc_id},
          content_extra
        )

      {:ok, _} =
        Content.create_document(
          "task",
          %{"doc_id" => task_doc_id, "title" => task_doc_id, "content" => content},
          @dataset,
          scope
        )

      # Dedup wrinkle (lvw-t11-followup-dedup): drop pending rebuilds so this
      # publish enqueues its own `types: ["task"]` job (see expectations_test).
      Repo.delete_all(Oban.Job)

      {:ok, doc} = Content.publish_document(task_doc_id, "task", @dataset, scope)
      doc
    end

    defp drain_projector! do
      for job <- all_enqueued(worker: ProjectorWorker) do
        perform_job(ProjectorWorker, job.args)
      end

      :ok
    end

    test "lists a published citing task with its expectation state",
         %{conn: conn, scope: scope} do
      register_task_schemas!(scope)
      paper_id = uniq("rv-root")
      task_id = uniq("rv-task")
      mk_post!(paper_id, scope)

      publish_task_citing!(paper_id, task_id, scope, %{
        "acceptance_criteria" => [
          %{"criterion" => "claim under test", "met" => true, "evidence" => "PR #1"},
          %{"criterion" => "still open", "met" => false}
        ]
      })

      drain_projector!()

      resp = conn |> authed() |> get("/v1/graph/#{paper_id}/tasks")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert body["root"] == paper_id
      assert body["count"] == 1
      assert body["truncated"] == false

      assert [task] = body["tasks"]
      assert task["doc_id"] == task_id
      assert task["lifecycle_status"] == "open"
      assert "design_doc" in task["via"]
      assert task["criteria_progress"] == %{"met" => 1, "total" => 2}
      assert task["satisfied"] == false

      assert [
               %{"criterion" => "claim under test", "met" => true, "evidence" => "PR #1"},
               %{"criterion" => "still open", "met" => false, "evidence" => nil}
             ] = task["criteria"]
    end

    test "criteria_progress is OMITTED for a criteria-less task (never 0/0)",
         %{conn: conn, scope: scope} do
      register_task_schemas!(scope)
      paper_id = uniq("rv-nocrit-root")
      task_id = uniq("rv-nocrit-task")
      mk_post!(paper_id, scope)
      publish_task_citing!(paper_id, task_id, scope, %{})
      drain_projector!()

      resp = conn |> authed() |> get("/v1/graph/#{paper_id}/tasks")
      assert resp.status == 200

      assert [task] = Jason.decode!(resp.resp_body)["tasks"]
      assert task["doc_id"] == task_id
      refute Map.has_key?(task, "criteria_progress")
      assert task["satisfied"] == false
      assert task["criteria"] == []
    end

    test "a root nothing cites returns an empty list", %{conn: conn, scope: scope} do
      doc_id = uniq("rv-lonely")
      mk_post!(doc_id, scope)

      resp = conn |> authed() |> get("/v1/graph/#{doc_id}/tasks")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["tasks"] == []
      assert body["count"] == 0
      assert body["truncated"] == false
    end

    test "404s for an unknown root id", %{conn: conn} do
      resp =
        conn
        |> authed()
        |> get("/v1/graph/no-such-doc-#{System.unique_integer([:positive])}/tasks")

      assert resp.status == 404
    end

    test "401 without a token", %{conn: conn} do
      resp = get(conn, "/v1/graph/anything/tasks")
      assert resp.status == 401
    end
  end
end
