defmodule BarkparkWeb.FleetRosterTenancyTest do
  @moduledoc """
  `GET /v1/fleet/roster` is WORKSPACE-SCOPED — the regression test for
  task-4e2986e8609670d7.

  ## The ruling this pins (criterion 0), verbatim

  > orchestrator, delegated; owner informed 2026-09-01 — RULED A: scope the
  > roster read with scope_opts(conn); the global view is for the OPERATOR
  > tier only, NOT any `admin` bit.

  ## The leak

  `TasksController.fleet_beat/2` passed `scope_opts(conn)` into `Fleet.beat/3`,
  so a heartbeat was stamped with the caller's `workspace_id`.
  `fleet_roster/2` passed the DATASET only, and neither `Fleet.load_listeners/1`
  nor `Fleet.current_tasks_by_worker/1` carried a workspace clause — so the
  WRITE was tenant-scoped and the READ was not. A bearer holding `read` on the
  instance got every workspace's listener rows (worker, agent, scope, capacity,
  last_seen) plus the published doc_id of each worker's in-progress task. On a
  default deployment every workspace shares the `"production"` dataset, so the
  dataset filter was never a tenancy filter.

  ## What this file proves

  Two REAL workspaces, two tokens bound to them, two beats over the wire —
  the two-workspace half of criterion 1 that could not be run against the live
  instance (guerrilla has exactly ONE workspace, so a cross-tenant probe there
  is unreachable by construction, not by luck).

    * A's roster holds A's worker and NOT B's (and the mirror for B);
    * B's in-progress task id appears NOWHERE in A's response body — the task
      join leaked too, and is scoped by the same clause;
    * a token bound to NO workspace falls to the seeded Default
      (`AssignDefaultScope`, since `DeriveWorkspaceFromToken` has nothing to
      derive) and sees neither A's nor B's listener — 200, not a leak;
    * at the unit seam, `Fleet.roster/2` with `workspace_id: nil` FAILS CLOSED
      to `[]` while the same read with `global: true` returns BOTH listeners —
      which is what keeps the assertions above from passing vacuously on a
      roster that was empty for some unrelated reason.

  `global: true` is the one explicit cross-tenant opt-in and no HTTP request
  can set it; the `:ops`-gated Studio tile is its only caller, pending the
  operator tier (task-c7e2b87f1bbca815).
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.Fleet

  @dataset "production"

  setup do
    n = System.unique_integer([:positive])

    ws_a = TenancyFixtures.create_workspace!("fleet-tenancy-a-#{n}")
    ws_b = TenancyFixtures.create_workspace!("fleet-tenancy-b-#{n}")
    project_a = TenancyFixtures.create_project!(ws_a, "fleet-tenancy-a-p-#{n}")
    project_b = TenancyFixtures.create_project!(ws_b, "fleet-tenancy-b-p-#{n}")

    scope_a = [workspace_id: ws_a.id, project_id: project_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: project_b.id]

    # The seeded Default must exist: it is where a workspace-less token lands
    # (AssignDefaultScope), and this file asserts what such a caller can see.
    {default_ws, default_project} = TenancyFixtures.ensure_default_scope!()

    for scope <- [scope_a, scope_b, [workspace_id: default_ws.id, project_id: default_project.id]] do
      register_task_schemas!(scope)
    end

    # Unique raw token values + labels: the test database is SHARED across
    # agents, and a fixed literal would 409 against a peer's row.
    token_a = "fleet-roster-a-#{n}"
    token_b = "fleet-roster-b-#{n}"
    token_nows = "fleet-roster-nows-#{n}"

    {:ok, _} =
      Auth.create_token(token_a, "fleet-roster-a-#{n}", @dataset, ~w(read write), ws_a.id)

    {:ok, _} =
      Auth.create_token(token_b, "fleet-roster-b-#{n}", @dataset, ~w(read write), ws_b.id)

    {:ok, _} = Auth.create_token(token_nows, "fleet-roster-nows-#{n}", @dataset, ~w(read write))

    worker_a = "fleet-tenancy-worker-a-#{n}"
    worker_b = "fleet-tenancy-worker-b-#{n}"

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      scope_a: scope_a,
      scope_b: scope_b,
      token_a: token_a,
      token_b: token_b,
      token_nows: token_nows,
      worker_a: worker_a,
      worker_b: worker_b,
      n: n
    }
  end

  describe "GET /v1/fleet/roster — the cross-tenant half of criterion 1" do
    test "a token bound to A never sees B's listener, and B's never sees A's", ctx do
      beat!(ctx.token_a, ctx.worker_a)
      beat!(ctx.token_b, ctx.worker_b)

      workers_a = roster_workers!(ctx.token_a)
      workers_b = roster_workers!(ctx.token_b)

      # NON-VACUITY FIRST: if A's own worker were missing, "B is absent" would
      # be true of an empty list and prove nothing.
      assert ctx.worker_a in workers_a,
             "A's own listener is missing from A's roster — the read fail-closed too far " <>
               "and every isolation assertion below would be vacuous"

      refute ctx.worker_b in workers_a,
             "workspace B's worker #{ctx.worker_b} leaked into workspace A's roster"

      assert ctx.worker_b in workers_b
      refute ctx.worker_a in workers_b
    end

    test "the task join is scoped too — B's in-progress task id never reaches A", ctx do
      beat!(ctx.token_a, ctx.worker_a)
      beat!(ctx.token_b, ctx.worker_b)

      task_b = in_progress_task!(ctx.scope_b, ctx.worker_b, ctx.n)
      task_b_id = Content.published_id(task_b.doc_id)

      body_a = roster!(ctx.token_a)
      body_b = roster!(ctx.token_b)

      row_b = Enum.find(body_b["documents"], &(&1["worker"] == ctx.worker_b))

      # Non-vacuity: the join must WORK inside B, or "absent from A" is free.
      assert row_b["task"] == task_b_id,
             "the read-time task join did not fire inside B, so its absence from A proves nothing"

      row_a = Enum.find(body_a["documents"], &(&1["worker"] == ctx.worker_a))
      assert row_a, "A's own listener is missing — the assertion below would be vacuous"

      refute task_b_id in Enum.map(body_a["documents"], & &1["task"])

      refute String.contains?(Jason.encode!(body_a), task_b_id),
             "workspace B's in-progress task id #{task_b_id} appears somewhere in A's roster body"
    end

    test "a token bound to NO workspace lands on Default and sees neither A nor B", ctx do
      beat!(ctx.token_a, ctx.worker_a)
      beat!(ctx.token_b, ctx.worker_b)

      body = roster!(ctx.token_nows)
      workers = Enum.map(body["documents"], & &1["worker"])

      refute ctx.worker_a in workers
      refute ctx.worker_b in workers
    end
  end

  describe "Fleet.roster/2 at the unit seam" do
    test "nil workspace_id fails CLOSED to [] while global: true still sees both", ctx do
      beat!(ctx.token_a, ctx.worker_a)
      beat!(ctx.token_b, ctx.worker_b)

      global = Enum.map(Fleet.roster(@dataset, global: true), & &1["worker"])

      # The rows EXIST — this is the measurement the fail-closed assertion
      # below is compared against, so `[] == []` can never masquerade as proof.
      assert ctx.worker_a in global
      assert ctx.worker_b in global

      assert Enum.filter(Fleet.roster(@dataset, workspace_id: nil), fn row ->
               row["worker"] in [ctx.worker_a, ctx.worker_b]
             end) == []

      assert Enum.filter(Fleet.roster(@dataset, []), fn row ->
               row["worker"] in [ctx.worker_a, ctx.worker_b]
             end) == []

      scoped_a = Enum.map(Fleet.roster(@dataset, workspace_id: ctx.ws_a.id), & &1["worker"])
      assert ctx.worker_a in scoped_a
      refute ctx.worker_b in scoped_a
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp authed(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  defp beat!(token, worker) do
    body =
      token
      |> authed()
      |> post("/v1/fleet/beat", Jason.encode!(%{worker: worker, agent: "claude-code"}))
      |> json_response(200)

    assert %{"ok" => true, "registered" => true} = body
    body
  end

  defp roster!(token) do
    conn = token |> authed() |> get("/v1/fleet/roster")
    assert conn.status == 200, "roster answered #{conn.status}: #{conn.resp_body}"
    json_response(conn, 200)
  end

  defp roster_workers!(token), do: Enum.map(roster!(token)["documents"], & &1["worker"])

  defp in_progress_task!(scope, worker, n) do
    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "fleet-tenancy-task-#{n}-#{System.unique_integer([:positive])}",
          "title" => "fleet tenancy probe task",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "in_progress",
            "assignee" => worker,
            "claim" => %{"worker" => worker, "epoch" => 1}
          }
        },
        @dataset,
        scope
      )

    task
  end

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
end
