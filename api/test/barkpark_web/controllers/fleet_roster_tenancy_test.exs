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
  operator tier (task-c7e2b87f1bbca815). That claim is not left to prose —
  `describe "the global: true opt-in"` guards it TWO ways: a source-level
  tripwire that sweeps every module under `api/lib` and fails the moment a
  second caller appears (following `flat_alias_route_census_test`'s
  read-the-source precedent), and a behavioural pin that a `?global=true`
  query param on the route changes nothing.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.Fleet

  @dataset "production"

  # A DIRECT `Fleet.roster(…, global: true)` call. Anchored on the `(` so the
  # prose references to `Fleet.roster/2`'s `global: true` in comments and
  # moduledocs (tasks_controller.ex carries one, deliberately) are not calls.
  @global_opt_in_call ~r/Fleet\.roster\s*\(\s*[^)]*\bglobal:/

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

  describe "the global: true opt-in — the ruling's one escape hatch, fenced" do
    # A source-level tripwire, not a behavioural one: the point is that a
    # SECOND caller must never be written, and the cheapest moment to catch
    # that is when someone writes it. `flat_alias_route_census_test`'s
    # `scope_markers_in/1` is the precedent for reading a module's own source
    # inside a test, and `__info__(:compile)[:source]` is how it locates one —
    # cwd-independent, so this holds under `mix test` from anywhere.
    test "the global arm is reachable from no HTTP route — the :ops Studio tile is its only caller" do
      sources = Path.wildcard(Path.join(lib_root(), "**/*.ex"))

      refute sources == [],
             "the api/lib source sweep found NOTHING, so every assertion below would pass on " <>
               "an empty list and guard nothing. Fix the sweep — do NOT delete the assertion."

      roster_callers =
        Enum.filter(sources, fn path -> String.contains?(File.read!(path), "Fleet.roster(") end)

      tile = source_of(Barkpark.Plugins.Tasks.Web.FleetLive)
      controller = source_of(BarkparkWeb.TasksController)

      # Positive control on the SWEEP itself: it can see the two call sites that
      # genuinely exist. Without this, "exactly one opt-in caller" would also be
      # true of a sweep that had gone blind.
      assert tile in roster_callers,
             "the sweep did not see the Studio tile's own Fleet.roster call — it is looking at " <>
               "the wrong tree, and the tripwire below is worthless"

      assert controller in roster_callers,
             "the sweep did not see TasksController.fleet_roster/2's Fleet.roster call"

      opt_in_callers =
        Enum.filter(roster_callers, fn path ->
          Regex.match?(@global_opt_in_call, File.read!(path))
        end)

      assert opt_in_callers == [tile],
             """
             `Fleet.roster/2`'s `global: true` is the ONE explicit cross-tenant opt-in the
             2026-09-01 ruling on task-4e2986e8609670d7 left standing, and the :ops-gated
             Studio tile (Barkpark.Plugins.Tasks.Web.FleetLive) is its only sanctioned caller.

             The ruling reserves the global view for an OPERATOR tier — NOT any `admin` bit,
             and certainly not an HTTP route. A new caller here is a new cross-tenant read.
             If the operator tier has landed (task-c7e2b87f1bbca815), the global roster belongs
             BEHIND it, and this assertion should be rewritten to name that gate — not widened.

             callers holding the opt-in:
             #{Enum.join(opt_in_callers, "\n")}
             """

      # The HTTP surface pinned POSITIVELY: every `Fleet.roster(` call under
      # barkpark_web/ threads the request's own scope. A rule that only listed
      # forbidden shapes would miss `opts = [global: true]` one line up; this
      # one fails for anything that is not the sanctioned call.
      web_root = Path.join(lib_root(), "barkpark_web")

      web_calls =
        for path <- roster_callers,
            String.starts_with?(path, web_root),
            line <- String.split(File.read!(path), "\n"),
            String.contains?(line, "Fleet.roster("),
            do: {Path.relative_to(path, lib_root()), String.trim(line)}

      refute web_calls == [],
             "no Fleet.roster call site found under barkpark_web/ — the route was renamed or " <>
               "moved, and this assertion has gone vacuous"

      for {path, line} <- web_calls do
        assert String.contains?(line, "scope_opts(conn)"),
               "#{path} calls Fleet.roster without threading scope_opts(conn):\n    #{line}"
      end
    end

    test "a ?global=true query param cannot reach the opt-in — A still sees only A", ctx do
      beat!(ctx.token_a, ctx.worker_a)
      beat!(ctx.token_b, ctx.worker_b)

      # The opt-in lives in a keyword list the controller builds from
      # `scope_opts(conn)`; params never touch it. Three shapes a caller might
      # try, including one that names workspace B outright.
      for query <- ["?global=true", "?global=1&scope=global", "?workspace_id=" <> ctx.ws_b.id] do
        workers =
          ctx.token_a
          |> roster_at!("/v1/fleet/roster" <> query)
          |> Map.fetch!("documents")
          |> Enum.map(& &1["worker"])

        assert ctx.worker_a in workers,
               "#{query} lost A its OWN roster — the refutation below would be vacuous"

        refute ctx.worker_b in workers,
               "#{query} widened workspace A's roster to workspace B's worker"
      end
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

  defp roster_at!(token, path) do
    conn = token |> authed() |> get(path)
    assert conn.status == 200, "GET #{path} answered #{conn.status}: #{conn.resp_body}"
    json_response(conn, 200)
  end

  # A compiled module's own source path — the census's `scope_markers_in/1`
  # idiom, which is cwd-independent.
  defp source_of(module), do: module.__info__(:compile)[:source] |> to_string()

  # `…/api/lib`, walked up from a module whose path inside lib/ is known.
  defp lib_root do
    root =
      Barkpark.Tasks.Fleet
      |> source_of()
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()

    assert Path.basename(root) == "lib",
           "expected Barkpark.Tasks.Fleet at lib/barkpark/tasks/fleet.ex; the source sweep " <>
             "cannot locate api/lib from #{root}"

    root
  end

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
