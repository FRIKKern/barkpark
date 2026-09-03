defmodule BarkparkWeb.TasksControllerTenantIsolationTest do
  @moduledoc """
  barkpark-w9dg scar class (the FIXED public-paper cross-workspace leak).

  `Barkpark.Tasks.close/3` (and its sibling by-PK task mutations) fetch the task
  row by PK — `Repo.get(Document, task_id)` — with NO tenant clause. Tenant
  safety therefore lives at the CALL SITE: the HTTP controller runs the scoped
  pre-flight `find_task_by_doc_id/2` FIRST, which resolves the doc_id only
  WITHIN the request's workspace/project. A workspace-B request for a
  workspace-A task resolves to `:not_found` → 404, and `Tasks.close/3` is never
  reached with the foreign id, so A's task is never mutated.

  This test drives that seam end-to-end through the real controller pipeline:
  a workspace-B-scoped request cannot close a workspace-A task, and the task is
  left untouched — while the SAME request under workspace A's scope succeeds
  (the positive control that proves the 404 is tenant isolation, not a broken
  close). The static `scripts/tenant-scope-check.sh` gate is what keeps a NEW
  caller from handing a raw doc_id straight to the unscoped by-PK fetch; this
  proves the current scoped path refuses the crossing.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @token "barkpark-tenant-iso-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "tenant-iso", "test", ["read", "write", "admin"])

    # Workspace A = the seeded Default scope (schemas registered so create/claim
    # resolve). Workspace B is a distinct tenant with no relationship to A.
    {ws_a, proj_a} = TenancyFixtures.ensure_default_scope!()
    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    register_task_schemas!(scope_a)

    ws_b = TenancyFixtures.create_workspace!()
    proj_b = TenancyFixtures.create_project!(ws_b)

    %{scope_a: scope_a, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
  end

  defp register_task_schemas!(scope) do
    for schema_def <- Barkpark.Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  # Pin the conn's tenant scope. AssignDefaultScope only assigns when unset, so a
  # pre-assigned workspace/project survives the pipeline unchanged — this is how a
  # request lands in workspace B instead of the seeded Default.
  defp scoped(conn, ws, proj) do
    conn
    |> Plug.Conn.assign(:current_workspace, ws)
    |> Plug.Conn.assign(:current_project, proj)
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "a workspace-B request cannot close a workspace-A task (scoped resolver refuses; task unmutated)",
       %{scope_a: scope_a, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b, conn: conn} do
    phase = uniq("phase")

    # Create + claim a task IN WORKSPACE A (context calls, scoped to A) so it has
    # a live claim epoch a close could otherwise act on.
    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => uniq("iso"),
          "title" => "A's task",
          # PDS-D291: one MET criterion keeps the in-scope `done` close out of
          # the close-artifact gate (a criteria-less `done` close whose reason
          # names no PR+sha is refused). This test measures tenancy.
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "parent_id" => phase,
            "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
          }
        },
        @dataset,
        scope_a
      )

    {:ok, claimed} = Barkpark.Tasks.claim_by_id(task.doc_id, "worker-a", scope_a)
    epoch = get_in(claimed.content, ["claim", "epoch"])
    assert is_integer(epoch)

    close_body = Jason.encode!(%{worker_id: "worker-a", observed_epoch: epoch})

    # ── The crossing: workspace B tries to close A's task by its doc_id. ──
    resp_b =
      conn
      |> scoped(ws_b, proj_b)
      |> authed()
      |> post("/v1/tasks/#{task.doc_id}/close", close_body)

    # Scoped pre-flight resolves nothing in B → 404; Tasks.close never runs.
    assert resp_b.status == 404

    # And the task in A is UNMUTATED — still in_progress, not closed by B.
    {:ok, after_b} = Content.get_document(task.doc_id, "task", @dataset, scope_a)
    assert get_in(after_b.content, ["lifecycle_status"]) == "in_progress"

    # ── Positive control: the SAME close under workspace A's scope succeeds. ──
    # Proves the 404 above is tenant isolation, not a structurally broken close.
    resp_a =
      conn
      |> scoped(ws_a, proj_a)
      |> authed()
      |> post("/v1/tasks/#{task.doc_id}/close", close_body)

    assert resp_a.status == 200
    assert Jason.decode!(resp_a.resp_body)["doc"]["lifecycle_status"] == "done"
  end
end
