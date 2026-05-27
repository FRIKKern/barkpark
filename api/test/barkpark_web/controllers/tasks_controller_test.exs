defmodule BarkparkWeb.TasksControllerTest do
  @moduledoc """
  W7b step 1 (paperflow-rx0 / w7-07a) — contract tests for the bd-shim
  surface. One happy path per endpoint + one auth-fail + one error shape.

    * `ready` happy path (one open task surfaces)
    * `claim` happy path → flips lifecycle to `in_progress`
    * `claim` error path: `no_ready` when the queue is empty
    * `close` happy path → flips lifecycle to `done`
    * `close` error path: `fenced_off` when observed_epoch mismatches
    * `edges` happy path (one `blocks` dep visible from both sides)
    * `add_edge` happy path (POST creates a `blocks` edge)
    * auth: 401 with no token on `ready`

  Total: 8 tests. Mirrors the auth-fail + happy/error-shape pattern from
  `plugin_settings_controller_test.exs`.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}

  @token "barkpark-test-tasks-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-tasks", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{"kind" => "task", "lifecycle_status" => "open"},
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  describe "auth gating" do
    test "GET /v1/tasks/ready returns 401 without a token", %{conn: conn} do
      resp = get(conn, "/v1/tasks/ready")
      assert resp.status == 401
    end
  end

  describe "GET /v1/tasks/ready" do
    test "returns the open tasks in the active phase", %{conn: conn, scope: scope} do
      phase = uniq("phase-ready")
      _t1 = mk_task!(uniq("ready-a"), scope, %{"parent_id" => phase})
      _t2 = mk_task!(uniq("ready-b"), scope, %{"parent_id" => phase})

      resp = conn |> authed() |> get("/v1/tasks/ready?phase_id=#{phase}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert is_list(body["docs"])
      assert length(body["docs"]) == 2

      first = hd(body["docs"])
      assert first["kind"] == "task"
      assert first["lifecycle_status"] == "open"
      assert first["type"] == "task"
    end
  end

  describe "POST /v1/tasks/claim" do
    test "happy path: claims a ready task and flips lifecycle to in_progress",
         %{conn: conn, scope: scope} do
      phase = uniq("phase-claim")
      _task = mk_task!(uniq("claim-a"), scope, %{"parent_id" => phase})

      body = Jason.encode!(%{worker_id: "worker-1", phase_id: phase})
      resp = conn |> authed() |> post("/v1/tasks/claim", body)
      assert resp.status == 200

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      assert payload["doc"]["lifecycle_status"] == "in_progress"
      assert payload["doc"]["assignee"] == "worker-1"
      assert payload["doc"]["claim"]["worker"] == "worker-1"
      assert payload["doc"]["claim"]["epoch"] == 1
    end

    test "error path: returns ok=false reason=no_ready when no claimable rows",
         %{conn: conn} do
      phase = uniq("phase-empty")
      body = Jason.encode!(%{worker_id: "worker-1", phase_id: phase})

      resp = conn |> authed() |> post("/v1/tasks/claim", body)
      assert resp.status == 200

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == false
      assert payload["reason"] == "no_ready"
    end
  end

  describe "POST /v1/tasks/:doc_id/close" do
    test "happy path: closes a claimed task; lifecycle flips to done",
         %{conn: conn, scope: scope} do
      phase = uniq("phase-close")
      doc_id = uniq("close-a")
      _task = mk_task!(doc_id, scope, %{"parent_id" => phase})

      # Claim it first to get a valid epoch.
      claim_body = Jason.encode!(%{worker_id: "worker-1", phase_id: phase})
      claim_resp = conn |> authed() |> post("/v1/tasks/claim", claim_body)
      claim_payload = Jason.decode!(claim_resp.resp_body)
      claimed_doc_id = claim_payload["doc"]["doc_id"]
      epoch = claim_payload["doc"]["claim"]["epoch"]

      close_body = Jason.encode!(%{worker_id: "worker-1", observed_epoch: epoch})
      resp = conn |> authed() |> post("/v1/tasks/#{claimed_doc_id}/close", close_body)
      assert resp.status == 200

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      assert payload["doc"]["lifecycle_status"] == "done"
    end

    test "error path: returns ok=false reason=fenced_off on epoch mismatch",
         %{conn: conn, scope: scope} do
      phase = uniq("phase-fenced")
      doc_id = uniq("fenced-a")
      _task = mk_task!(doc_id, scope, %{"parent_id" => phase})

      claim_body = Jason.encode!(%{worker_id: "worker-1", phase_id: phase})
      claim_resp = conn |> authed() |> post("/v1/tasks/claim", claim_body)
      claimed_doc_id = Jason.decode!(claim_resp.resp_body)["doc"]["doc_id"]

      # Wrong epoch (real one is 1; we pass 999).
      close_body = Jason.encode!(%{worker_id: "worker-1", observed_epoch: 999})
      resp = conn |> authed() |> post("/v1/tasks/#{claimed_doc_id}/close", close_body)
      assert resp.status == 409

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == false
      assert payload["reason"] == "fenced_off"
    end
  end

  describe "GET /v1/tasks/:doc_id/edges" do
    test "returns dependencies + dependents from both sides of a blocks edge",
         %{conn: conn, scope: scope} do
      parent = mk_task!(uniq("edges-parent"), scope)
      child = mk_task!(uniq("edges-child"), scope)

      {:ok, _} = Tasks.add_dep(child.id, parent.id, :blocks)

      # Persisted doc_ids carry the "drafts." prefix — that's the bd-shape
      # id the shim consumes (matches render_doc(doc).doc_id).
      parent_doc_id = parent.doc_id
      child_doc_id = child.doc_id

      # Child's outbound: parent is a dependency (blocker)
      child_resp = conn |> authed() |> get("/v1/tasks/#{child_doc_id}/edges")
      assert child_resp.status == 200
      child_payload = Jason.decode!(child_resp.resp_body)
      assert child_payload["ok"] == true
      assert length(child_payload["dependencies"]) == 1
      assert hd(child_payload["dependencies"])["doc_id"] == parent_doc_id
      assert child_payload["dependents"] == []

      # Parent's inbound: child is a dependent
      parent_resp = conn |> authed() |> get("/v1/tasks/#{parent_doc_id}/edges")
      assert parent_resp.status == 200
      parent_payload = Jason.decode!(parent_resp.resp_body)
      assert parent_payload["dependencies"] == []
      assert length(parent_payload["dependents"]) == 1
      assert hd(parent_payload["dependents"])["doc_id"] == child_doc_id
    end
  end

  describe "POST /v1/tasks/edges" do
    test "happy path: creates a blocks edge between two existing tasks",
         %{conn: conn, scope: scope} do
      parent = mk_task!(uniq("addedge-parent"), scope)
      child = mk_task!(uniq("addedge-child"), scope)

      body =
        Jason.encode!(%{from_id: child.doc_id, to_id: parent.doc_id, kind: "blocks"})

      resp = conn |> authed() |> post("/v1/tasks/edges", body)
      assert resp.status == 200

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true
      assert payload["edge"]["kind"] == "blocks"
    end
  end
end
