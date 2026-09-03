defmodule BarkparkWeb.TasksControllerRelabelTenancyTest do
  @moduledoc """
  Executable cross-tenant pin for the flat `POST /v1/tasks/:doc_id/labels`
  relabel path (arpss-relabel-byid-cross-tenant-pin).

  `Barkpark.Tasks.relabel_by_id/4` (tasks/mutations.ex) fetches the task row by
  PK — a RAW GLOBAL `Repo.get(Document, task_id)` with NO scope argument. Tenant
  safety therefore lives entirely at the CALL SITE: the controller's `relabel/2`
  gates the mutation behind `find_task_by_doc_id/2` → `fetch_task_exact/3`, which
  filters the lookup by `workspace_id` AND `project_id` (fail-closed — a nil scope
  narrows, never widens). The unscoped by-PK get only ever re-fetches an
  already-authorized row. The flat route is `auth: :token_root`, so a plain token
  with no scope pin pools into the singleton Default workspace via
  `AssignDefaultScope`.

  This test drives that seam end-to-end through the real controller pipeline:

    * A task lives in a DISTINCT non-Default workspace A.
    * A plain (Default-pooled) token request to relabel A's task by its doc_id
      resolves nothing in Default → 404 `task not found`, and A's labels are
      left UNMUTATED — `relabel_by_id` is never reached with the foreign id.
    * The SAME relabel under workspace A's own scope succeeds (200, label
      applied) — the positive control that proves the 404 is scope-specific,
      not a structurally broken route.

  MUTATION PROOF (proves this pin is not vacuous-green). Deleting the two scope
  clauses in `fetch_task_exact/3` —

      query = base                          # (maybe_filter_workspace/_project removed)

  — makes A's task matchable from the Default-pooled request. The negative
  assertion then REDS: the plain request returns 200 and relabels the foreign
  task (`assert resp_plain.status == 404` fails with `left: 200`, and A's labels
  gain `file-claim:/a/intruder`). Restoring the clauses returns the suite to
  green. Verified locally on origin/main before commit.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @token "barkpark-relabel-tenancy-token"
  @dataset "production"

  @owned_label "file-claim:/a/owned"
  @intruder_label "file-claim:/a/intruder"

  setup do
    {:ok, _} = Auth.create_token(@token, "relabel-tenancy", "test", ["read", "write", "admin"])

    # Ensure the singleton Default scope exists so a plain (unpinned) token
    # request pools into it via AssignDefaultScope — that is the scope the flat
    # `:token_root` labels route runs under.
    _ = TenancyFixtures.ensure_default_scope!()

    # Workspace A = a DISTINCT non-Default tenant. The task lives here; a
    # Default-pooled request must never reach it. Schemas are registered in A's
    # scope so the create/relabel resolve within A.
    ws_a = TenancyFixtures.create_workspace!()
    proj_a = TenancyFixtures.create_project!(ws_a)
    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    register_task_schemas!(scope_a)

    %{scope_a: scope_a, ws_a: ws_a, proj_a: proj_a}
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
  # pre-assigned workspace/project survives the pipeline unchanged — this is how
  # the positive control lands in workspace A instead of the seeded Default.
  defp scoped(conn, ws, proj) do
    conn
    |> Plug.Conn.assign(:current_workspace, ws)
    |> Plug.Conn.assign(:current_project, proj)
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp labels_in_scope(doc_id, scope) do
    {:ok, doc} = Content.get_document(doc_id, "task", @dataset, scope)
    get_in(doc.content, ["labels"]) || []
  end

  test "a plain (Default-pooled) request cannot relabel a workspace-A task by id (scoped resolver refuses; labels unmutated)",
       %{scope_a: scope_a, ws_a: ws_a, proj_a: proj_a, conn: conn} do
    phase = uniq("phase")

    # Create a task IN WORKSPACE A (scoped to A) carrying one owned label.
    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => uniq("rl"),
          "title" => "A's task",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "parent_id" => phase,
            "labels" => [@owned_label]
          }
        },
        @dataset,
        scope_a
      )

    body = Jason.encode!(%{add: [@intruder_label], remove: []})

    # ── The crossing: a plain token (no scope pin → pooled to Default) tries to
    #    relabel A's task by its doc_id. ──
    resp_plain =
      conn
      |> authed()
      |> post("/v1/tasks/#{task.doc_id}/labels", body)

    # Scoped pre-flight resolves nothing in Default → 404; relabel_by_id never runs.
    assert resp_plain.status == 404
    assert Jason.decode!(resp_plain.resp_body)["message"] == "task not found"

    # And the task in A is UNMUTATED — still only its owned label, no intruder.
    assert labels_in_scope(task.doc_id, scope_a) == [@owned_label]

    # ── Positive control: the SAME relabel under workspace A's scope succeeds. ──
    # Proves the 404 above is tenant isolation, not a structurally broken route.
    resp_a =
      conn
      |> scoped(ws_a, proj_a)
      |> authed()
      |> post("/v1/tasks/#{task.doc_id}/labels", body)

    assert resp_a.status == 200
    applied = Jason.decode!(resp_a.resp_body)["doc"]["labels"]
    assert @owned_label in applied
    assert @intruder_label in applied

    # The persisted row now carries both labels — the in-scope write landed.
    assert Enum.sort(labels_in_scope(task.doc_id, scope_a)) ==
             Enum.sort([@owned_label, @intruder_label])
  end
end
