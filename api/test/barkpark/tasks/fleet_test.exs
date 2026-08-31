defmodule Barkpark.Tasks.FleetTest do
  @moduledoc """
  Unit tests for `Barkpark.Tasks.Fleet` — Personal Dev Fleet presence
  (Wave A: listener type + zero-row beat + fail-closed roster).

  Covers:
    1. `schema_definitions/1` returns BOTH `task` and `listener`; the type
       name is EXACTLY "listener" (never "task" — the structural exclusion
       from the GitHub outbox / task-events / prime `type == "task"` filters).
    2. First beat REGISTERS: a `type:"listener"` doc appears, `ttl_s`
       defaults 120, `status` defaults idle, `last_seen` is server-stamped;
       its mutation_events rows carry `type == "listener"`.
    3. ZERO-ROW PROOF: a second beat advances `last_seen` while `revisions`,
       `mutation_events` AND `audit_events` row counts stay EXACTLY
       unchanged (PDF-D17), and provided fields (status) still merge.
    4. Fail-closed staleness: `last_seen` older than the row's OWN `ttl_s`
       reads "offline"; fresh reads the stored status; nil last_seen reads
       "offline"; per-row ttl_s is honored (same age, different budgets).
    5. Roster is per-dataset (a listener in another dataset never leaks in).
    6. Read-time task join: claim.worker first, assignee fallback.
    7. Beat input honesty: missing worker / invalid status / invalid ttl.
    8. Manifest wiring: /v1/fleet routes + fleet.roster/fleet.beat CLI verbs
       + the plugin.json `fleet` noun (zero Go — manifest-driven dispatch).
  """

  use Barkpark.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Audit
  alias Barkpark.Content.{Document, MutationEvent, Revision}
  alias Barkpark.Tasks.Fleet

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp listener_rows(worker) do
    logical = "listener-" <> worker

    from(d in Document,
      where: d.type == "listener" and d.doc_id in ^[logical, "drafts." <> logical]
    )
    |> Repo.all()
  end

  defp counts do
    %{
      revisions: Repo.aggregate(Revision, :count),
      mutation_events: Repo.aggregate(MutationEvent, :count),
      audit_events: Repo.aggregate(Audit.Event, :count)
    }
  end

  defp roster_row(dataset, worker, opts \\ []) do
    dataset
    |> Fleet.roster(opts)
    |> Enum.find(&(&1["worker"] == worker))
  end

  # Direct listener fixture for roster staleness cases — bypasses the beat so
  # each case pins its own last_seen/ttl_s exactly.
  defp mk_listener!(worker, content_extra, scope) do
    content =
      Map.merge(
        %{"worker" => worker, "status" => "idle", "ttl_s" => Fleet.default_ttl_s()},
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "listener",
        %{"doc_id" => "listener-" <> worker, "title" => worker, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp iso_ago(now, seconds), do: now |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()

  # ── 1. listener is its own type ──────────────────────────────────────────

  test "schema_definitions returns task AND listener, type exactly listener" do
    names = @dataset |> Tasks.schema_definitions() |> Enum.map(& &1.name)
    assert names == ["task", "listener"]

    listener = Tasks.listener_schema(@dataset)
    assert listener.name == "listener"
    refute listener.name == "task"

    field_names = Enum.map(listener.fields, & &1["name"])
    assert field_names == ~w(worker agent scope status capacity last_seen ttl_s)
  end

  test "listener writes stamp mutation_events with type listener, never task", %{scope: scope} do
    worker = uniq("ml")
    assert {:ok, %{registered: true}} = Fleet.beat(%{"worker" => worker}, @dataset, scope)

    events =
      from(m in MutationEvent, where: like(m.doc_id, ^"%listener-#{worker}%"))
      |> Repo.all()

    assert events != []
    assert Enum.all?(events, &(&1.type == "listener"))
    refute Enum.any?(events, &(&1.type == "task"))
  end

  # ── 2. registration ──────────────────────────────────────────────────────

  test "first beat registers: type listener, ttl_s defaults 120, status idle, server-stamped last_seen",
       %{scope: scope} do
    worker = uniq("reg")

    assert {:ok, %{registered: true, doc: receipt}} =
             Fleet.beat(%{"worker" => worker}, @dataset, scope)

    assert receipt["worker"] == worker
    assert receipt["ttl_s"] == 120

    assert [%Document{type: "listener", content: content}] = listener_rows(worker)
    assert content["worker"] == worker
    assert content["ttl_s"] == 120
    assert content["status"] == "idle"
    assert {:ok, _, _} = DateTime.from_iso8601(content["last_seen"])
  end

  test "beat merges provided fields on registration", %{scope: scope} do
    worker = uniq("regf")

    params = %{
      "worker" => worker,
      "status" => "working",
      "agent" => "claude-code",
      "scope" => "barkpark",
      "capacity" => "1 task",
      "ttl" => 60
    }

    assert {:ok, %{registered: true}} = Fleet.beat(params, @dataset, scope)

    assert [%Document{content: content}] = listener_rows(worker)
    assert content["status"] == "working"
    assert content["agent"] == "claude-code"
    assert content["scope"] == "barkpark"
    assert content["capacity"] == "1 task"
    assert content["ttl_s"] == 60
  end

  # ── 2b. structured capacity contract (pdf-wb-capacity-contract) ──────────
  # The silent-drop trap sealed: capacity is validated on the write path, so
  # routing (heavy->big / light->lean, PDF-D6/D7) reads structured truth off
  # the beat instead of a free-form hint the router cannot parse.

  test "beat accepts a native capacity map, validates it, and stores the map", %{scope: scope} do
    worker = uniq("capmap")

    cap = %{
      "size_class" => "heavy",
      "slots_total" => 2,
      "slots_free" => 1,
      "budget" => 5.0
    }

    assert {:ok, %{registered: true}} =
             Fleet.beat(%{"worker" => worker, "capacity" => cap}, @dataset, scope)

    assert [%Document{content: content}] = listener_rows(worker)
    # PROTECTIVE: pre-fix main dropped a non-binary capacity silently (the
    # is_binary-only clause never matched a map) — the row would carry no
    # capacity. This asserts the validated MAP round-trips intact.
    assert content["capacity"] == cap
  end

  test "beat decodes a JSON-object capacity string into the validated map", %{scope: scope} do
    worker = uniq("capjson")
    json = ~s({"size_class":"light","slots_total":4,"slots_free":4})

    assert {:ok, %{registered: true}} =
             Fleet.beat(%{"worker" => worker, "capacity" => json}, @dataset, scope)

    assert [%Document{content: content}] = listener_rows(worker)
    # The CLI ships --capacity as a query-string string (type:"string", zero
    # Go); a JSON object string must decode + store as a map — pre-fix it
    # landed as the raw string, which the router cannot route on.
    assert content["capacity"] == %{
             "size_class" => "light",
             "slots_total" => 4,
             "slots_free" => 4
           }
  end

  test "beat refuses an off-vocab size_class (the observed 'big') and stores nothing", %{
    scope: scope
  } do
    worker = uniq("capbad")

    assert {:error, :invalid_capacity} =
             Fleet.beat(
               %{"worker" => worker, "capacity" => %{"size_class" => "big"}},
               @dataset,
               scope
             )

    # Refused, never stored: no listener row was minted.
    assert listener_rows(worker) == []
  end

  test "beat refuses negative slots and inverted slots_free > slots_total", %{scope: scope} do
    assert {:error, :invalid_capacity} =
             Fleet.beat(
               %{
                 "worker" => uniq("neg"),
                 "capacity" => %{"size_class" => "standard", "slots_free" => -1}
               },
               @dataset,
               scope
             )

    assert {:error, :invalid_capacity} =
             Fleet.beat(
               %{
                 "worker" => uniq("inv"),
                 "capacity" => %{
                   "size_class" => "standard",
                   "slots_total" => 1,
                   "slots_free" => 3
                 }
               },
               @dataset,
               scope
             )
  end

  test "beat refuses a JSON-object capacity string that fails validation", %{scope: scope} do
    worker = uniq("capjsonbad")

    assert {:error, :invalid_capacity} =
             Fleet.beat(
               %{"worker" => worker, "capacity" => ~s({"size_class":"xxl"})},
               @dataset,
               scope
             )

    assert listener_rows(worker) == []
  end

  test "beat still stores a legacy free-form capacity string verbatim", %{scope: scope} do
    worker = uniq("caplegacy")

    assert {:ok, %{registered: true}} =
             Fleet.beat(%{"worker" => worker, "capacity" => "1 task"}, @dataset, scope)

    assert [%Document{content: content}] = listener_rows(worker)
    assert content["capacity"] == "1 task"
  end

  # ── 3. the zero-row beat (PDF-D17) ───────────────────────────────────────

  test "second beat advances last_seen with ZERO new revisions/mutation_events/audit_events rows",
       %{scope: scope} do
    worker = uniq("zr")
    assert {:ok, %{registered: true}} = Fleet.beat(%{"worker" => worker}, @dataset, scope)

    [%Document{content: %{"last_seen" => first_seen}}] = listener_rows(worker)
    before = counts()

    # Make the clock's advance visible even at coarse timer resolution.
    Process.sleep(2)

    assert {:ok, %{registered: false}} =
             Fleet.beat(%{"worker" => worker, "status" => "working"}, @dataset, scope)

    assert counts() == before

    assert [%Document{content: content}] = listener_rows(worker)
    {:ok, first_dt, _} = DateTime.from_iso8601(first_seen)
    {:ok, second_dt, _} = DateTime.from_iso8601(content["last_seen"])
    assert DateTime.compare(second_dt, first_dt) == :gt
    # Provided fields still merge in the same zero-row write.
    assert content["status"] == "working"
  end

  # ── 4. fail-closed staleness ─────────────────────────────────────────────

  test "roster fail-closes staleness against each row's OWN ttl_s", %{scope: scope} do
    now = DateTime.utc_now()

    stale = uniq("stale")
    fresh = uniq("fresh")
    never = uniq("never")
    patient = uniq("patient")

    # 300s old vs a 120s budget → offline.
    mk_listener!(stale, %{"last_seen" => iso_ago(now, 300), "status" => "working"}, scope)
    # 10s old vs 120s → the STORED status, verbatim.
    mk_listener!(fresh, %{"last_seen" => iso_ago(now, 10), "status" => "working"}, scope)
    # nil last_seen → offline, fail closed.
    mk_listener!(never, %{"last_seen" => nil}, scope)
    # SAME 300s age as `stale`, but its OWN ttl_s (3600) keeps it online.
    mk_listener!(
      patient,
      %{"last_seen" => iso_ago(now, 300), "ttl_s" => 3600, "status" => "blocked"},
      scope
    )

    assert roster_row(@dataset, stale, now: now)["status"] == "offline"
    assert roster_row(@dataset, fresh, now: now)["status"] == "working"
    assert roster_row(@dataset, never, now: now)["status"] == "offline"
    assert roster_row(@dataset, patient, now: now)["status"] == "blocked"
  end

  test "a provisioner-written provisioning row renders verbatim while fresh (PDF-D23)",
       %{scope: scope} do
    # Wave C writes `provisioning` directly (never via the beat) — the roster
    # must pass it through as stored vocab, and still fail-close on staleness.
    now = DateTime.utc_now()
    worker = uniq("prov")

    mk_listener!(worker, %{"last_seen" => iso_ago(now, 5), "status" => "provisioning"}, scope)

    assert roster_row(@dataset, worker, now: now)["status"] == "provisioning"

    late = DateTime.add(now, 121, :second)
    assert roster_row(@dataset, worker, now: late)["status"] == "offline"
  end

  test "kill-a-listener: a live beat reads online, then reads OFFLINE once its ttl elapses",
       %{scope: scope} do
    worker = uniq("kill")
    assert {:ok, _} = Fleet.beat(%{"worker" => worker, "ttl" => 120}, @dataset, scope)

    now = DateTime.utc_now()
    assert roster_row(@dataset, worker, now: now)["status"] == "idle"

    # The listener dies (no more beats). Advance the injected clock past TTL.
    after_ttl = DateTime.add(now, 121, :second)
    assert roster_row(@dataset, worker, now: after_ttl)["status"] == "offline"
  end

  # ── 5. per-dataset scoping ───────────────────────────────────────────────

  test "roster excludes other datasets", %{scope: scope} do
    worker = uniq("ds")

    {:ok, _} =
      Content.create_document(
        "listener",
        %{
          "doc_id" => "listener-" <> worker,
          "title" => worker,
          "content" => %{
            "worker" => worker,
            "last_seen" => DateTime.to_iso8601(DateTime.utc_now())
          }
        },
        "staging",
        scope
      )

    assert roster_row("staging", worker) != nil
    assert roster_row(@dataset, worker) == nil
  end

  # ── 5b. WORKSPACE scoping — the three-arm fence (task-b9f15f2a947f99d1) ───
  #
  # The roster is a TENANT read. PDF-D19's requirement is "an unresolved
  # workspace must never blank the board" — which the `:shared_only` sentinel
  # satisfies WITHOUT handing every tenant every other tenant's rows. Three
  # arms, each proven on its own below:
  #
  #   binary workspace_id -> that workspace's listeners AND task join, only
  #   :shared_only        -> the SHARED layer (workspace_id IS NULL), never []
  #   nil                 -> today's global read, unchanged (internal callers)
  #
  # Every assertion pins POSITIVE content as well as the absence: a bare
  # "B's rows are gone" passes on a correct fence, on an empty result from a
  # broken fixture, and on an error. The positives tell those three apart.

  defp mk_listener_in!(worker, scope) do
    {:ok, doc} =
      Content.create_document(
        "listener",
        %{
          "doc_id" => "listener-" <> worker,
          "title" => worker,
          "content" => %{
            "worker" => worker,
            "status" => "working",
            "ttl_s" => Fleet.default_ttl_s(),
            "last_seen" => DateTime.to_iso8601(DateTime.utc_now())
          }
        },
        @dataset,
        scope
      )

    doc
  end

  # A row on the SHARED layer (workspace_id IS NULL). It cannot be made by
  # passing `[]`: `WriteScope.resolve_write_scope/1` falls back to the seeded
  # Default workspace for an empty scope, so the scope is nulled directly —
  # the same shape a write from a fresh, unseeded DB produces (which is
  # exactly the nil-workspace case PDF-D19 is about).
  defp mk_shared_listener!(worker) do
    doc = mk_listener_in!(worker, [])

    {1, _} =
      from(d in Document, where: d.id == ^doc.id)
      |> Repo.update_all(set: [workspace_id: nil, project_id: nil, dataset_id: nil])

    doc
  end

  defp mk_in_progress_task!(worker, scope) do
    task_id = uniq("ws-task")

    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => task_id,
          "title" => task_id,
          "content" => %{"kind" => "task", "lifecycle_status" => "open"}
        },
        @dataset,
        scope
      )

    {:ok, _} = Tasks.claim_by_id(task.doc_id, worker, scope)
    Content.published_id(task.doc_id)
  end

  # Two real tenants, each with a listener AND that listener's in-progress
  # task — the two things `roster/2` reads (listener rows + the task join).
  defp two_tenant_fleet do
    ws_a = TenancyFixtures.create_workspace!()
    proj_a = TenancyFixtures.create_project!(ws_a)
    ws_b = TenancyFixtures.create_workspace!()
    proj_b = TenancyFixtures.create_project!(ws_b)

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    worker_a = uniq("wsa")
    worker_b = uniq("wsb")

    _ = mk_listener_in!(worker_a, scope_a)
    _ = mk_listener_in!(worker_b, scope_b)

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      worker_a: worker_a,
      worker_b: worker_b,
      task_a: mk_in_progress_task!(worker_a, scope_a),
      task_b: mk_in_progress_task!(worker_b, scope_b)
    }
  end

  test "roster fences BOTH the listener rows and the task join to the caller's workspace" do
    f = two_tenant_fleet()
    now = DateTime.utc_now()

    rows_a = Fleet.roster(@dataset, workspace_id: f.ws_a.id, now: now)
    workers_a = Enum.map(rows_a, & &1["worker"])

    # POSITIVE first — without these the absences below would also pass on an
    # empty roster (the very fail-closed-to-empty bug PDF-D19 warns about).
    assert f.worker_a in workers_a
    row_a = Enum.find(rows_a, &(&1["worker"] == f.worker_a))
    assert row_a["status"] == "working"
    assert row_a["task"] == f.task_a

    # THE LEAK, most-severe claim first: B's in-progress task id must not
    # surface through the join...
    refute f.task_b in Enum.map(rows_a, & &1["task"])
    # ...nor may B's listener row itself appear in A's roster.
    refute f.worker_b in workers_a

    # The mirror, so this is a real fence and not "A simply sorted first".
    rows_b = Fleet.roster(@dataset, workspace_id: f.ws_b.id, now: now)
    workers_b = Enum.map(rows_b, & &1["worker"])

    assert f.worker_b in workers_b
    assert Enum.find(rows_b, &(&1["worker"] == f.worker_b))["task"] == f.task_b
    refute f.worker_a in workers_b
    refute f.task_a in Enum.map(rows_b, & &1["task"])
  end

  test "the task join is fenced too: a worker name shared by two tenants joins its OWN task" do
    # This is the assertion that makes the SECOND fence load-bearing. Fencing
    # `load_listeners/2` alone is not enough and the test above cannot show it:
    # there, each worker name lives in one workspace, so the unfenced join map
    # is never consulted for a foreign key. Worker strings are NOT
    # workspace-unique, though — so when the same name exists in both tenants,
    # an unfenced `current_tasks_by_worker/2` hands A's row whichever task
    # sorted first (most-recently-updated wins), i.e. B's.
    ws_a = TenancyFixtures.create_workspace!()
    proj_a = TenancyFixtures.create_project!(ws_a)
    ws_b = TenancyFixtures.create_workspace!()
    proj_b = TenancyFixtures.create_project!(ws_b)

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    worker = uniq("dup")

    _ = mk_listener_in!(worker, scope_a)
    task_a = mk_in_progress_task!(worker, scope_a)
    # Created LAST, so it wins the most-recently-updated tie-break in the join.
    task_b = mk_in_progress_task!(worker, scope_b)

    row =
      @dataset
      |> Fleet.roster(workspace_id: ws_a.id, now: DateTime.utc_now())
      |> Enum.find(&(&1["worker"] == worker))

    # Positive: the row exists and carries A's OWN task — not nil, not B's.
    assert row
    assert row["task"] == task_a
    refute row["task"] == task_b
  end

  test "CONTROL: an unresolved workspace reads the SHARED set — never empty (PDF-D19)" do
    f = two_tenant_fleet()
    now = DateTime.utc_now()

    shared_worker = uniq("shared")
    _ = mk_shared_listener!(shared_worker)

    rows = Fleet.roster(@dataset, workspace_id: :shared_only, now: now)
    workers = Enum.map(rows, & &1["worker"])

    # PDF-D19's ACTUAL requirement: a nil/unresolved workspace must not blank
    # the board. It does not — the sentinel reads the shared layer.
    refute rows == []
    assert shared_worker in workers
    assert Enum.find(rows, &(&1["worker"] == shared_worker))["status"] == "working"

    # ...and it is still not a cross-tenant read.
    refute f.worker_a in workers
    refute f.worker_b in workers
  end

  test "a nil workspace keeps the GLOBAL read — internal callers unchanged (PDF-D19)" do
    f = two_tenant_fleet()

    workers = @dataset |> Fleet.roster(now: DateTime.utc_now()) |> Enum.map(& &1["worker"])

    # The nil arm is the deliberate, named global read: every internal caller
    # (`Fleet.roster(dataset)`, mix tasks, the existing suite) is untouched.
    assert f.worker_a in workers
    assert f.worker_b in workers
  end

  # ── 6. current-task join ─────────────────────────────────────────────────

  test "roster joins the worker's in_progress task via claim.worker, assignee fallback",
       %{scope: scope} do
    worker = uniq("join")
    task_id = uniq("join-task")

    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => task_id,
          "title" => task_id,
          "content" => %{"kind" => "task", "lifecycle_status" => "open"}
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(task.doc_id, worker, scope)

    assert {:ok, _} = Fleet.beat(%{"worker" => worker}, @dataset, scope)

    now = DateTime.utc_now()
    assert roster_row(@dataset, worker, now: now)["task"] == Content.published_id(task.doc_id)

    # Assignee fallback: strip claim.worker (direct write — engines keep both;
    # the fallback covers rows where only assignee survives).
    fresh = Repo.get!(Document, claimed.id)
    content = Map.update!(fresh.content, "claim", &Map.delete(&1, "worker"))

    {1, _} =
      from(d in Document, where: d.id == ^claimed.id)
      |> Repo.update_all(set: [content: content])

    assert roster_row(@dataset, worker, now: now)["task"] == Content.published_id(task.doc_id)
  end

  # ── 7. beat input honesty ────────────────────────────────────────────────

  test "beat refuses a missing worker, an unknown status, a bad ttl", %{scope: scope} do
    assert {:error, :missing_worker} = Fleet.beat(%{}, @dataset, scope)
    assert {:error, :missing_worker} = Fleet.beat(%{"worker" => "  "}, @dataset, scope)

    assert {:error, :invalid_status} =
             Fleet.beat(%{"worker" => uniq("w"), "status" => "sleeping"}, @dataset, scope)

    # PDF-D23: provisioning is provisioner-written (Wave C) — never
    # beat-declarable. offline is derived-only — never storable.
    assert {:error, :invalid_status} =
             Fleet.beat(%{"worker" => uniq("w"), "status" => "provisioning"}, @dataset, scope)

    assert {:error, :invalid_status} =
             Fleet.beat(%{"worker" => uniq("w"), "status" => "offline"}, @dataset, scope)

    assert {:error, :invalid_ttl} =
             Fleet.beat(%{"worker" => uniq("w"), "ttl" => "soon"}, @dataset, scope)

    assert {:error, :invalid_ttl} =
             Fleet.beat(%{"worker" => uniq("w"), "ttl" => -5}, @dataset, scope)
  end

  # ── 8. manifest wiring (zero Go — PDF-D21) ───────────────────────────────

  test "plugin mounts /v1/fleet routes and mints fleet.roster + fleet.beat verbs" do
    routes = Barkpark.Plugins.Tasks.register_routes([])

    assert {:post, "/fleet/beat", BarkparkWeb.TasksController, :fleet_beat, auth: :token_root} in routes

    assert {:get, "/fleet/roster", BarkparkWeb.TasksController, :fleet_roster, auth: :token_root} in routes

    commands = Barkpark.Plugins.Tasks.cli_commands()

    roster = Enum.find(commands, &(&1.id == "fleet.roster"))
    assert roster.noun == "fleet"
    assert roster.http == %{method: "GET", path_template: "/v1/fleet/roster"}
    assert roster.writes == false
    assert roster.default_output == "table"

    beat = Enum.find(commands, &(&1.id == "fleet.beat"))
    assert beat.noun == "fleet"
    assert beat.http == %{method: "POST", path_template: "/v1/fleet/beat"}
    assert beat.writes == true
    assert Enum.map(beat.args, & &1.name) == ["worker"]

    manifest =
      :barkpark
      |> :code.priv_dir()
      |> Path.join("plugins/tasks/plugin.json")
      |> File.read!()
      |> Jason.decode!()

    assert manifest["nouns"] == ["task", "fleet"]
  end
end

defmodule BarkparkWeb.FleetControllerTest do
  @moduledoc """
  HTTP contract tests for `/v1/fleet/*` — the beat write path over the wire
  and the roster's `{"ok": true, "documents": [...]}` envelope (PDF-D21: the
  `documents` key is what every installed bp binary renders as a real table).
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Audit
  alias Barkpark.Content.{MutationEvent, Revision}

  @token "barkpark-test-fleet-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-fleet", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    :ok
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp counts do
    %{
      revisions: Repo.aggregate(Revision, :count),
      mutation_events: Repo.aggregate(MutationEvent, :count),
      audit_events: Repo.aggregate(Audit.Event, :count)
    }
  end

  test "POST /v1/fleet/beat registers, then zero-row-beats over the wire", %{conn: conn} do
    worker = uniq("http")

    first =
      conn
      |> authed()
      |> post("/v1/fleet/beat", %{"worker" => worker, "agent" => "claude-code"})
      |> json_response(200)

    assert %{"ok" => true, "registered" => true, "doc" => %{"worker" => ^worker}} = first
    first_seen = first["doc"]["last_seen"]

    before = counts()
    Process.sleep(2)

    second =
      build_conn()
      |> authed()
      |> post("/v1/fleet/beat", %{"worker" => worker, "status" => "working"})
      |> json_response(200)

    assert %{"ok" => true, "registered" => false} = second
    assert counts() == before

    {:ok, first_dt, _} = DateTime.from_iso8601(first_seen)
    {:ok, second_dt, _} = DateTime.from_iso8601(second["doc"]["last_seen"])
    assert DateTime.compare(second_dt, first_dt) == :gt
    assert second["doc"]["status"] == "working"
  end

  test "GET /v1/fleet/roster rides the documents envelope", %{conn: conn} do
    worker = uniq("env")

    _ =
      conn
      |> authed()
      |> post("/v1/fleet/beat", %{"worker" => worker, "scope" => "barkpark"})
      |> json_response(200)

    body =
      build_conn()
      |> authed()
      |> get("/v1/fleet/roster")
      |> json_response(200)

    # The envelope contract (PDF-D21): ok + documents, no bespoke key.
    assert %{"ok" => true, "documents" => documents} = body
    refute Map.has_key?(body, "roster")

    row = Enum.find(documents, &(&1["worker"] == worker))
    assert row["scope"] == "barkpark"
    assert row["status"] == "idle"
    assert row["ttl_s"] == 120
    assert Map.has_key?(row, "task")
  end

  test "GET /v1/capabilities carries fleet.roster (table) and fleet.beat (writes)", %{conn: conn} do
    body =
      conn
      |> authed()
      |> get("/v1/capabilities")
      |> json_response(200)

    commands = body["commands"] || []

    roster = Enum.find(commands, &(&1["id"] == "fleet.roster"))
    assert roster["noun"] == "fleet"
    assert roster["http"]["method"] == "GET"
    assert roster["http"]["path_template"] == "/v1/fleet/roster"
    assert roster["writes"] == false
    assert roster["default_output"] == "table"
    assert roster["source"] == "plugin:tasks"

    beat = Enum.find(commands, &(&1["id"] == "fleet.beat"))
    assert beat["noun"] == "fleet"
    assert beat["http"]["method"] == "POST"
    assert beat["http"]["path_template"] == "/v1/fleet/beat"
    assert beat["writes"] == true
    assert beat["source"] == "plugin:tasks"
  end

  test "POST /v1/fleet/beat without a worker is a 400", %{conn: conn} do
    body =
      conn
      |> authed()
      |> post("/v1/fleet/beat", %{})
      |> json_response(400)

    assert %{"ok" => false, "reason" => "bad_request"} = body
  end

  test "POST /v1/fleet/beat with off-vocab structured capacity is a 422", %{conn: conn} do
    body =
      conn
      |> authed()
      |> post("/v1/fleet/beat", %{
        "worker" => uniq("http-cap"),
        "capacity" => %{"size_class" => "big"}
      })
      |> json_response(422)

    assert %{"ok" => false, "reason" => "invalid_capacity"} = body
  end

  test "fleet endpoints refuse an anonymous caller", %{conn: conn} do
    assert conn |> get("/v1/fleet/roster") |> response(401)
    assert build_conn() |> post("/v1/fleet/beat", %{"worker" => "x"}) |> response(401)
  end
end
