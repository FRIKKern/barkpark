defmodule Barkpark.TasksReadyTest do
  @moduledoc """
  W7a step 3 — `Tasks.ready/1` + `Tasks.claim/2` skeleton.

  Six surfaces under test (per the brief's VERIFY gate):

    1. **Basic ready** — a task with no blockers, lifecycle_status=open,
       in the right phase is returned.
    2. **Blocker holds** — task A blocks task B; while A is `open` B is
       NOT ready. Once A flips to `done` B becomes ready. Exercises the
       W7-02 edge integration end-to-end.
    3. **Phase scope** — a task in phase X is NOT returned for phase Y
       queries (and vice versa).
    4. **Lifecycle filter** — `done` / `cancelled` / `in_progress` tasks
       are not in the ready set; only `open` and `blocked` are.
    5. **Tenancy** — a task in workspace A is NOT in workspace B's
       ready-queue. Per W2 the read fails CLOSED on a nil workspace.
    6. **Concurrency** — N parallel `claim/2` calls against the SAME
       ready row pick disjoint rows; the proof for `FOR UPDATE SKIP
       LOCKED` on the document substrate (Gate-A foundation).

  Mirrors `tasks_edges_test.exs` conventions: per-test sandbox, scope
  helpers from `TenancyFixtures`, schema registration in setup.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    register_schemas!(scope)

    %{scope: scope, workspace: ws, project: project}
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

  # Helper: flip a task's lifecycle_status by raw update (no validator path —
  # we're testing the read query against representative DB rows, not the
  # full mutation API which lands in W7-04).
  defp set_lifecycle!(doc, new_status) do
    # cch-w3-task-birth-attribution: a done row satisfies a dependent only if it
    # ALSO carries close provenance, because `lifecycle_status` alone is
    # forgeable by a fresh create. A fixture that flips to "done" is simulating
    # a CLOSE, so it writes what a close writes.
    new_content =
      doc.content
      |> Map.put("lifecycle_status", new_status)
      |> then(fn c ->
        if new_status == "done" and c["close_reason"] in [nil, ""],
          do: Map.put(c, "close_reason", "fixture: closed through the verb"),
          else: c
      end)

    doc
    |> Ecto.Changeset.change(content: new_content)
    |> Repo.update!()
  end

  # Helper: filter to just our test's tasks (the seeded sandbox can be
  # busy in shared-mode siblings).
  defp ids_of(docs), do: Enum.map(docs, & &1.id)

  # ─── (1) Basic ready ──────────────────────────────────────────────────────

  describe "ready/1 — basic" do
    test "returns an open task with no blockers in the right phase",
         %{scope: scope} do
      phase_id = "phase-build-#{System.unique_integer([:positive])}"

      task =
        mk_task!("rdy-basic-#{System.unique_integer([:positive])}", scope, %{
          "parent_id" => phase_id
        })

      results = Tasks.ready(scope ++ [phase_id: phase_id, dataset: @dataset])

      assert task.id in ids_of(results)
    end

    test "phase-agnostic call returns the task without :phase_id filter",
         %{scope: scope} do
      task = mk_task!("rdy-noscope-#{System.unique_integer([:positive])}", scope)

      results = Tasks.ready(scope ++ [dataset: @dataset])

      assert task.id in ids_of(results)
    end

    test "ordering: priority ASC (NULLS LAST), then inserted_at ASC",
         %{scope: scope} do
      phase_id = "phase-ord-#{System.unique_integer([:positive])}"

      no_prio =
        mk_task!("ord-noprio-#{System.unique_integer([:positive])}", scope, %{
          "parent_id" => phase_id
        })

      p2 =
        mk_task!("ord-p2-#{System.unique_integer([:positive])}", scope, %{
          "parent_id" => phase_id,
          "priority" => 2
        })

      p0 =
        mk_task!("ord-p0-#{System.unique_integer([:positive])}", scope, %{
          "parent_id" => phase_id,
          "priority" => 0
        })

      ordered =
        scope
        |> Keyword.merge(phase_id: phase_id, dataset: @dataset)
        |> Tasks.ready()
        |> ids_of()

      assert Enum.find_index(ordered, &(&1 == p0.id)) <
               Enum.find_index(ordered, &(&1 == p2.id))

      assert Enum.find_index(ordered, &(&1 == p2.id)) <
               Enum.find_index(ordered, &(&1 == no_prio.id)),
             "NULLS LAST means no_prio sorts after p2"
    end
  end

  # ─── (2) Blocker holds (W7-02 edge integration) ───────────────────────────

  describe "ready/1 — blocker semantics" do
    test "B is NOT ready while A blocks it; flipping A to done makes B ready",
         %{scope: scope} do
      phase_id = "phase-blk-#{System.unique_integer([:positive])}"

      a =
        mk_task!("blk-a-#{System.unique_integer([:positive])}", scope, %{"parent_id" => phase_id})

      b =
        mk_task!("blk-b-#{System.unique_integer([:positive])}", scope, %{"parent_id" => phase_id})

      # b blocks on a (FK is documents.id per W7-02 — NOT doc_id).
      {:ok, _} = Tasks.add_dep(b.id, a.id, :blocks)

      ready_before =
        scope
        |> Keyword.merge(phase_id: phase_id, dataset: @dataset)
        |> Tasks.ready()
        |> ids_of()

      assert a.id in ready_before,
             "A has no blockers; A should be ready"

      refute b.id in ready_before,
             "B is blocked on A (open) — B must NOT be ready yet"

      # Resolve the blocker.
      _ = set_lifecycle!(a, "done")

      ready_after =
        scope
        |> Keyword.merge(phase_id: phase_id, dataset: @dataset)
        |> Tasks.ready()
        |> ids_of()

      refute a.id in ready_after,
             "A is done — not in ready set anymore"

      assert b.id in ready_after,
             "A is done — B's only blocker is resolved; B must be ready"
    end

    test "discovered-from edges do NOT block readiness — only :blocks does",
         %{scope: scope} do
      phase_id = "phase-df-#{System.unique_integer([:positive])}"

      ancestor =
        mk_task!("df-anc-#{System.unique_integer([:positive])}", scope, %{"parent_id" => phase_id})

      child =
        mk_task!("df-child-#{System.unique_integer([:positive])}", scope, %{
          "parent_id" => phase_id
        })

      {:ok, _} = Tasks.add_dep(child.id, ancestor.id, :"discovered-from")

      results =
        scope
        |> Keyword.merge(phase_id: phase_id, dataset: @dataset)
        |> Tasks.ready()
        |> ids_of()

      assert child.id in results,
             "discovered-from is lineage, not blocking — child must be ready"
    end

    test "a blocker in non-done lifecycle (in_progress, blocked, cancelled, open) still holds",
         %{scope: scope} do
      phase_id = "phase-life-#{System.unique_integer([:positive])}"

      for blocker_status <- ~w(open in_progress blocked cancelled) do
        a =
          mk_task!("life-a-#{blocker_status}-#{System.unique_integer([:positive])}", scope, %{
            "parent_id" => phase_id
          })

        b =
          mk_task!("life-b-#{blocker_status}-#{System.unique_integer([:positive])}", scope, %{
            "parent_id" => phase_id
          })

        # Need a valid open blocker first (the create validator enforces
        # lifecycle_status); then flip via raw update.
        if blocker_status != "open" do
          _ = set_lifecycle!(a, blocker_status)
        end

        {:ok, _} = Tasks.add_dep(b.id, a.id, :blocks)

        ready =
          scope
          |> Keyword.merge(phase_id: phase_id, dataset: @dataset)
          |> Tasks.ready()
          |> ids_of()

        refute b.id in ready,
               "blocker in lifecycle=#{blocker_status} must keep B unready (only 'done' resolves)"
      end
    end
  end

  # ─── (3) Phase scope ──────────────────────────────────────────────────────

  describe "ready/1 — phase scope" do
    test "a task in phase X is NOT returned for phase Y queries", %{scope: scope} do
      phase_x = "phase-x-#{System.unique_integer([:positive])}"
      phase_y = "phase-y-#{System.unique_integer([:positive])}"

      task_x =
        mk_task!("phs-x-#{System.unique_integer([:positive])}", scope, %{"parent_id" => phase_x})

      task_y =
        mk_task!("phs-y-#{System.unique_integer([:positive])}", scope, %{"parent_id" => phase_y})

      ready_x =
        scope |> Keyword.merge(phase_id: phase_x, dataset: @dataset) |> Tasks.ready() |> ids_of()

      ready_y =
        scope |> Keyword.merge(phase_id: phase_y, dataset: @dataset) |> Tasks.ready() |> ids_of()

      assert task_x.id in ready_x
      refute task_y.id in ready_x
      assert task_y.id in ready_y
      refute task_x.id in ready_y
    end

    test "a task with no parent_id is NOT returned when :phase_id is set",
         %{scope: scope} do
      phase_id = "phase-strict-#{System.unique_integer([:positive])}"
      orphan = mk_task!("orph-#{System.unique_integer([:positive])}", scope)

      in_phase =
        mk_task!("in-phs-#{System.unique_integer([:positive])}", scope, %{"parent_id" => phase_id})

      ready =
        scope |> Keyword.merge(phase_id: phase_id, dataset: @dataset) |> Tasks.ready() |> ids_of()

      assert in_phase.id in ready
      refute orphan.id in ready
    end
  end

  # ─── (4) Lifecycle filter ─────────────────────────────────────────────────

  describe "ready/1 — lifecycle filter" do
    test "open and blocked are ready; done / cancelled / in_progress are not",
         %{scope: scope} do
      phase_id = "phase-lf-#{System.unique_integer([:positive])}"

      tasks_by_status =
        for status <- ~w(open in_progress blocked done cancelled), into: %{} do
          t =
            mk_task!("lf-#{status}-#{System.unique_integer([:positive])}", scope, %{
              "parent_id" => phase_id
            })

          # All tasks created as "open"; flip the non-open ones via raw update.
          t = if status == "open", do: t, else: set_lifecycle!(t, status)
          {status, t}
        end

      ready =
        scope |> Keyword.merge(phase_id: phase_id, dataset: @dataset) |> Tasks.ready() |> ids_of()

      assert tasks_by_status["open"].id in ready
      assert tasks_by_status["blocked"].id in ready
      refute tasks_by_status["in_progress"].id in ready
      refute tasks_by_status["done"].id in ready
      refute tasks_by_status["cancelled"].id in ready
    end

    test "non-task documents are NEVER in the ready set", %{scope: scope} do
      # A goal doc in the same phase (its content.kind = 'goal' not 'task').
      {:ok, goal_doc} =
        Content.create_document(
          "goal",
          %{
            "doc_id" => "goal-not-ready-#{System.unique_integer([:positive])}",
            "title" => "g",
            "content" => %{"kind" => "goal", "goal_slug" => "g"}
          },
          @dataset,
          scope
        )

      ready = Tasks.ready(scope ++ [dataset: @dataset]) |> ids_of()

      refute goal_doc.id in ready,
             "type='goal' rows must never appear in the ready-queue"
    end
  end

  # ─── (5) Tenancy ─────────────────────────────────────────────────────────

  describe "ready/1 — tenancy" do
    test "a task in workspace A is NOT in workspace B's ready-queue" do
      ws_a = TenancyFixtures.create_workspace!()
      proj_a = TenancyFixtures.create_project!(ws_a)
      ws_b = TenancyFixtures.create_workspace!()
      proj_b = TenancyFixtures.create_project!(ws_b)

      scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
      scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

      register_schemas!(scope_a)
      register_schemas!(scope_b)

      task_a = mk_task!("ten-a-#{System.unique_integer([:positive])}", scope_a)

      ready_a = Tasks.ready(scope_a ++ [dataset: @dataset]) |> ids_of()
      ready_b = Tasks.ready(scope_b ++ [dataset: @dataset]) |> ids_of()

      assert task_a.id in ready_a, "A must see its own task"
      refute task_a.id in ready_b, "B must NEVER see A's task"
    end

    test "nil workspace_id fails CLOSED — returns []", %{scope: _scope} do
      # Per Barkpark.Content.Scope: a nil workspace_id forces zero rows.
      assert Tasks.ready(dataset: @dataset) == []
      assert Tasks.ready(workspace_id: nil, dataset: @dataset) == []
    end
  end

  # ─── (6) Concurrency proof — FOR UPDATE SKIP LOCKED ───────────────────────

  describe "claim/2 — concurrency (Gate-A proof)" do
    test "two concurrent claims on a single ready row: exactly one wins, the other gets nil",
         %{scope: scope} do
      # The DataCase sandbox needs to be shared across the parallel Tasks so
      # they see the same row. Switch to shared mode for this test.
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = "phase-conc-#{System.unique_integer([:positive])}"

      task =
        mk_task!("conc-single-#{System.unique_integer([:positive])}", scope, %{
          "parent_id" => phase_id
        })

      claim_opts = scope ++ [phase_id: phase_id, dataset: @dataset]

      results =
        1..2
        |> Task.async_stream(
          fn i ->
            {:ok, doc_or_nil} = Tasks.claim("worker-#{i}", claim_opts)
            doc_or_nil
          end,
          max_concurrency: 2,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, v} -> v end)

      winners = Enum.reject(results, &is_nil/1)
      losers = Enum.filter(results, &is_nil/1)

      assert length(winners) == 1,
             "exactly ONE worker should have claimed the only ready row, got winners=#{inspect(Enum.map(winners, & &1.id))}"

      assert length(losers) == 1,
             "the other worker should have seen an empty queue, got losers=#{inspect(losers)}"

      [winner] = winners
      assert winner.id == task.id
      assert winner.content["lifecycle_status"] == "in_progress"
      assert winner.content["assignee"] =~ ~r/^worker-/
    end

    test "N parallel claims against N ready rows: every row goes to exactly one worker (robust over 20 iterations)",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      # Run 20 iterations × {5 workers, 5 rows} = 100 claim attempts.
      # If SKIP LOCKED is broken (or our transaction shape leaks), at least
      # one iteration will show a duplicate claim or a row left behind.
      Enum.each(1..20, fn iter ->
        phase_id = "phase-burst-#{iter}-#{System.unique_integer([:positive])}"

        task_ids =
          for i <- 1..5 do
            mk_task!("burst-#{iter}-#{i}-#{System.unique_integer([:positive])}", scope, %{
              "parent_id" => phase_id
            }).id
          end
          |> Enum.sort()

        claim_opts = scope ++ [phase_id: phase_id, dataset: @dataset]

        results =
          1..5
          |> Task.async_stream(
            fn w ->
              {:ok, doc_or_nil} = Tasks.claim("worker-#{w}", claim_opts)
              doc_or_nil
            end,
            max_concurrency: 5,
            ordered: false,
            timeout: 5_000
          )
          |> Enum.map(fn {:ok, v} -> v end)
          |> Enum.reject(&is_nil/1)

        claimed_ids = results |> Enum.map(& &1.id) |> Enum.sort()

        assert length(claimed_ids) == 5,
               "iter #{iter}: expected 5 distinct claims, got #{length(claimed_ids)} — SKIP LOCKED may have lost a row"

        assert claimed_ids == task_ids,
               "iter #{iter}: claimed set #{inspect(claimed_ids)} != created set #{inspect(task_ids)}"

        assert Enum.uniq(claimed_ids) == claimed_ids,
               "iter #{iter}: a row was claimed TWICE — SKIP LOCKED contract violated"

        # And confirm all 5 are now in_progress and the ready set for this
        # phase is empty (the queue drained).
        leftover =
          scope
          |> Keyword.merge(phase_id: phase_id, dataset: @dataset)
          |> Tasks.ready()
          |> ids_of()

        assert leftover == [],
               "iter #{iter}: ready set should be empty after 5/5 claims; got #{inspect(leftover)}"

        for %Document{} = doc <- results do
          assert doc.content["lifecycle_status"] == "in_progress"
        end
      end)
    end

    test "claim on an empty queue returns {:ok, nil}", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      # A phase with no tasks at all.
      phase_id = "phase-empty-#{System.unique_integer([:positive])}"

      assert {:ok, nil} =
               Tasks.claim("worker-empty", scope ++ [phase_id: phase_id, dataset: @dataset])
    end
  end
end
