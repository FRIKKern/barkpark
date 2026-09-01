defmodule Barkpark.Tasks.QueueTest do
  @moduledoc """
  Focused tests for `Barkpark.Tasks.Queue` — the module that owns
  `ready_query/1` and `ready/1`.

  The integration tests in `tasks_ready_test.exs` cover blocker semantics,
  phase scoping, lifecycle filtering, tenancy, and concurrency via the
  `Tasks` facade.  This file fills the remaining gaps:

    1. `ready_query/1` returns an `%Ecto.Query{}` struct (it is used by
       `Claim.claim/2` as a composable base — never call Repo inside).
    2. Dataset isolation — `maybe_filter_dataset` ensures a task in
       "production" is NOT returned when querying "staging".
    3. `limit` option — the default cap applies and can be overridden
       down to 1 (only the highest-priority task comes back).
    4. `ready/1` with no workspace_id fails CLOSED (zero rows from
       `Scope.scope_to_workspace/3`), including when called with []).

  ## Axis-2 ruling: a cancelled blocker strands its dependents — BY DESIGN

  `content.dependencies` (axis 2) is satisfied ONLY by a same-scope task with
  `lifecycle_status: "done"`; the anti-join fails CLOSED for any non-done id.
  A CANCELLED blocker therefore gates its dependents exactly like an open one.
  RULING (tlv-bl-axis2-cancelled-strand, charter D6): this fail-closed behavior
  is correct-by-design — there is NO query-time carve-out treating cancelled as
  satisfying, because that would change claim semantics repo-wide (`ready/1`,
  `Claim.claim/2`, and every readiness consumer share `ready_query/1`) and
  there is no reverse-lookup for `content.dependencies` today. The stranding is
  RECOVERABLE, not permanent: charter D7 makes `cancelled -> open` a legal
  transition, so a stranded dependent is un-stuck by reopening the blocker and
  driving it to done (or by re-pointing its `content.dependencies`). Automatic
  carve-out and kill-time warnings are an explicitly deferred future survey.
  Section (8) below holds the protective tests for both halves of this ruling.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Content.Document
  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.Queue

  @dataset "production"
  @dataset_alt "staging"

  setup do
    # E3 tag registry: the fixture weighted tags (fixture-tag-N) these tests
    # publish must resolve to PUBLISHED type:tag docs in the dataset scope.
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    register_schemas!(scope, @dataset)
    register_schemas!(scope, @dataset_alt)

    %{scope: scope}
  end

  defp register_schemas!(scope, dataset) do
    for schema_def <- Tasks.schema_definitions(dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
    end
  end

  defp mk_task!(doc_id, scope, dataset, content_extra \\ %{}) do
    content =
      %{"kind" => "task", "lifecycle_status" => "open"}
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
      |> Map.merge(content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        dataset,
        scope
      )

    doc
  end

  defp ids_of(docs), do: Enum.map(docs, & &1.id)

  defp plan_nodes(value) when is_list(value), do: Enum.flat_map(value, &plan_nodes/1)

  defp plan_nodes(value) when is_map(value) do
    [value | value |> Map.values() |> Enum.flat_map(&plan_nodes/1)]
  end

  defp plan_nodes(_value), do: []

  # Build a genuine draft/published TWIN pair for `base_id`, the shape a
  # published-task mutate leaves behind: a published row at the bare id +
  # a `drafts.<id>` shadow. `create_document` always writes `drafts.<id>`, so we
  # publish it to the bare id, then re-create the draft shadow. Returns
  # `{published_doc, draft_doc}`.
  defp mk_twin!(base_id, scope, dataset, content_extra) do
    _first = mk_task!(base_id, scope, dataset, content_extra)
    {:ok, published} = Content.publish_document(base_id, "task", dataset, scope)
    draft = mk_task!(base_id, scope, dataset, content_extra)
    {published, draft}
  end

  # ─── (1) ready_query/1 returns a composable Ecto.Query ───────────────────

  describe "ready_query/1" do
    test "returns an %Ecto.Query{} struct — does not hit the DB by itself", %{scope: scope} do
      result = Queue.ready_query(scope ++ [dataset: @dataset])
      assert %Ecto.Query{} = result
    end
  end

  # ─── (2) Dataset isolation ────────────────────────────────────────────────

  describe "ready/1 — dataset isolation" do
    test "task in 'production' is NOT returned when querying 'staging'",
         %{scope: scope} do
      prod_task =
        mk_task!("ds-prod-#{System.unique_integer([:positive])}", scope, @dataset)

      staging_results = Queue.ready(scope ++ [dataset: @dataset_alt]) |> ids_of()
      prod_results = Queue.ready(scope ++ [dataset: @dataset]) |> ids_of()

      assert prod_task.id in prod_results,
             "task created in 'production' must appear in the production ready set"

      refute prod_task.id in staging_results,
             "task created in 'production' must NOT appear in the staging ready set"
    end

    test "tasks in each dataset appear only in their own ready set", %{scope: scope} do
      prod_task =
        mk_task!("ds-iso-prod-#{System.unique_integer([:positive])}", scope, @dataset)

      staging_task =
        mk_task!("ds-iso-staging-#{System.unique_integer([:positive])}", scope, @dataset_alt)

      prod_ids = Queue.ready(scope ++ [dataset: @dataset]) |> ids_of()
      staging_ids = Queue.ready(scope ++ [dataset: @dataset_alt]) |> ids_of()

      assert prod_task.id in prod_ids
      refute prod_task.id in staging_ids

      assert staging_task.id in staging_ids
      refute staging_task.id in prod_ids
    end
  end

  # ─── (3) limit option ─────────────────────────────────────────────────────

  describe "ready/1 — limit option" do
    test "limit: 1 returns at most 1 task even when multiple are ready", %{scope: scope} do
      phase_id = "phase-lim-#{System.unique_integer([:positive])}"

      for i <- 1..3 do
        mk_task!("lim-#{i}-#{System.unique_integer([:positive])}", scope, @dataset, %{
          "parent_id" => phase_id
        })
      end

      results = Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id, limit: 1])
      assert length(results) == 1
    end
  end

  # ─── (4) ready/1 fails CLOSED without workspace scope ────────────────────

  describe "ready/1 — no workspace scope" do
    test "empty opts list returns []" do
      assert Queue.ready([]) == []
    end

    test "explicit nil workspace_id returns []", %{scope: _scope} do
      assert Queue.ready(workspace_id: nil, dataset: @dataset) == []
    end
  end

  describe "ready/1 — queue gate and campaign ordering" do
    test "five non-executable classes never enter ready or atomic next", %{scope: scope} do
      phase = "phase-gates-#{System.unique_integer([:positive])}"

      for {name, gate} <- [
            {"human", %{"version" => 1, "state" => "human_gated", "reason" => "approval"}},
            {"parked", %{"version" => 1, "state" => "parked", "reason" => "later"}},
            {"stalled",
             %{
               "version" => 1,
               "state" => "evidence_stalled",
               "reason" => "missing proof",
               "evidence" => "attempt log"
             }},
            {"malformed", %{"version" => 2, "state" => "executable"}},
            {"contradictory",
             %{
               "version" => 1,
               "state" => "executable",
               "reason" => "must not coexist"
             }}
          ] do
        doc =
          mk_task!("gate-#{name}-#{System.unique_integer([:positive])}", scope, @dataset, %{
            "parent_id" => phase
          })

        Repo.update_all(
          from(d in Document, where: d.id == ^doc.id),
          set: [content: Map.put(doc.content, "queue_gate", gate)]
        )
      end

      foreign =
        mk_task!("gate-foreign-#{System.unique_integer([:positive])}", scope, @dataset, %{
          "parent_id" => phase
        })

      Repo.update_all(
        from(d in Document, where: d.id == ^foreign.id),
        set: [content: Map.put(foreign.content, "claim", %{"worker" => "other-worker"})]
      )

      assert Queue.ready(scope ++ [dataset: @dataset, phase_id: phase]) == []

      assert {:ok, nil} =
               Tasks.claim("gate-worker", scope ++ [dataset: @dataset, phase_id: phase])
    end

    test "closure_nearest sorts six executable tasks by unmet count, age, then doc_id", %{
      scope: scope
    } do
      phase = "phase-closure-order-#{System.unique_integer([:positive])}"
      base = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      specs = [
        {"z-two", 2, 0},
        {"z-one-new", 1, 30},
        {"b-zero-tie", 0, 10},
        {"a-zero-tie", 0, 10},
        {"z-zero-old", 0, 0},
        {"z-one-old", 1, 20}
      ]

      Enum.each(specs, fn {id, unmet, seconds} ->
        criteria =
          Enum.map(1..max(unmet, 1), fn i ->
            %{"criterion" => "c#{i}", "met" => unmet == 0}
          end)

        doc =
          mk_task!(id <> "-" <> phase, scope, @dataset, %{
            "parent_id" => phase,
            "acceptance_criteria" => criteria
          })

        Repo.update_all(
          from(d in Document, where: d.id == ^doc.id),
          set: [inserted_at: DateTime.add(base, seconds, :second)]
        )
      end)

      ids =
        Queue.ready(scope ++ [dataset: @dataset, phase_id: phase, order: :closure_nearest])
        |> Enum.map(& &1.doc_id)

      assert ids ==
               Enum.map(
                 ["z-zero-old", "a-zero-tie", "b-zero-tie", "z-one-old", "z-one-new", "z-two"],
                 &("drafts." <> &1 <> "-" <> phase)
               )
    end

    test "unknown internal order values are rejected", %{scope: scope} do
      assert_raise ArgumentError, ~r/unsupported ready order/, fn ->
        Queue.ready(scope ++ [dataset: @dataset, order: :closure_neerest])
      end
    end
  end

  # ─── (5) draft/published twin collapse (published-wins) ──────────────────

  describe "ready/1 — draft/published twin collapse" do
    test "a twinned task yields exactly ONE ready row (the published/non-draft twin)",
         %{scope: scope} do
      phase_id = "phase-twin-#{System.unique_integer([:positive])}"
      base_id = "twin-#{System.unique_integer([:positive])}"

      {published, _draft} = mk_twin!(base_id, scope, @dataset, %{"parent_id" => phase_id})

      results = Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id])

      assert length(results) == 1, "a twin pair must collapse to a single ready row"
      assert hd(results).id == published.id
      assert hd(results).doc_id == base_id
      refute String.starts_with?(hd(results).doc_id, "drafts.")
    end

    test "queue-claim on a twinned task claims the canonical (published) row", %{scope: scope} do
      phase_id = "phase-twin-claim-#{System.unique_integer([:positive])}"
      base_id = "twinc-#{System.unique_integer([:positive])}"

      {published, _draft} = mk_twin!(base_id, scope, @dataset, %{"parent_id" => phase_id})

      assert {:ok, claimed} =
               Tasks.claim("twin-worker", scope ++ [dataset: @dataset, phase_id: phase_id])

      assert claimed.id == published.id
      assert claimed.doc_id == base_id

      # The twin is now gone from ready (claimed row left open/blocked AND the
      # draft was never claimable) — the logical task can't be claimed twice.
      assert Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id]) == []
    end

    test "a lone draft (no published twin) is NOT suppressed — it is the canonical row",
         %{scope: scope} do
      phase_id = "phase-lone-draft-#{System.unique_integer([:positive])}"
      base_id = "lone-#{System.unique_integer([:positive])}"

      draft = mk_task!("drafts." <> base_id, scope, @dataset, %{"parent_id" => phase_id})

      results = Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id])
      assert ids_of(results) == [draft.id]
    end

    # TRIPWIRE for the recurring "the ready queue emits phantom drafts" report.
    #
    # An UNPAIRED `drafts.<id>` row is NOT a phantom. It is how EVERY task is
    # born: `Content.create_document/4` forces `doc_id` through
    # `DraftId.draft_id/1`, so a task is a draft until something publishes it,
    # and `bp task create` / `bp doc create task` both default to leaving it
    # there. Excluding unpaired drafts from `ready_query/1` would therefore hide
    # the whole mutate-created population from `bp task ready` and `bp task
    # next` — see the same ruling stated at `Tasks.Query.collapse_twins/1` and
    # in `TasksController.list/2` ("why this is NOT a blanket `drafts.`
    # exclusion").
    #
    # The report that motivates the exclusion always rests on one claim: that a
    # claimed draft is "a row that can never be closed". This test is the
    # standing refutation — it drives the FULL round trip (born draft-only ->
    # ready -> claim -> close -> done) and proves the close lands. If someone
    # adds a `not like(doc_id, "drafts.%")` filter to the resolver, this reds at
    # the `ready` step; if a close path regresses for drafts, it reds at the
    # close step. Both halves are load-bearing.
    test "an UNPAIRED draft is real work: born draft-only -> ready -> claim -> close",
         %{scope: scope} do
      phase_id = "phase-draft-roundtrip-#{System.unique_integer([:positive])}"
      base_id = "roundtrip-#{System.unique_integer([:positive])}"

      task = mk_task!(base_id, scope, @dataset, %{"parent_id" => phase_id})

      # Non-vacuity on the FIXTURE: this must genuinely be an unpaired draft,
      # or every assertion below is about some other shape. Both halves matter —
      # the row IS `drafts.<id>`, and no published twin exists to stand in for
      # it (that twinned case is the test directly above).
      assert task.doc_id == "drafts." <> base_id,
             "create_document must birth the task as a draft for this test to mean anything"

      assert {:error, :not_found} =
               Content.get_document(base_id, "task", @dataset, scope),
             "an unpaired draft must have NO published twin"

      # (a) it is offered as ready — the behaviour a `drafts.` exclusion breaks.
      assert ids_of(Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id])) == [task.id]

      # (b) it is claimable off the queue — the same `ready_query/1` that
      # `bp task next` rides (Claim.claim/2 composes it directly).
      assert {:ok, claimed} =
               Tasks.claim("roundtrip-worker", scope ++ [dataset: @dataset, phase_id: phase_id])

      assert claimed.id == task.id
      assert claimed.doc_id == "drafts." <> base_id
      epoch = get_in(claimed.content, ["claim", "epoch"])
      assert epoch == 1

      # (c) and it CLOSES. This is the half that refutes "can never be closed".
      assert {:ok, closed} =
               Tasks.close(
                 claimed.id,
                 "roundtrip-worker",
                 scope ++ [dataset: @dataset, observed_epoch: epoch]
               )

      assert get_in(closed.content, ["lifecycle_status"]) == "done"
    end
  end

  # ─── (6) phase filter normalizes the drafts. prefix on either side ───────

  describe "ready/1 — phase filter is drafts.-prefix agnostic" do
    test "child parented at drafts.<phase> is found by a phase-scoped ready for the bare phase",
         %{scope: scope} do
      bare_phase = "phase-norm-#{System.unique_integer([:positive])}"

      child =
        mk_task!("pn-child-#{System.unique_integer([:positive])}", scope, @dataset, %{
          "parent_id" => "drafts." <> bare_phase
        })

      results = Queue.ready(scope ++ [dataset: @dataset, phase_id: bare_phase])
      assert child.id in ids_of(results)
    end

    test "child parented at the bare phase is found by a phase-scoped ready for drafts.<phase>",
         %{scope: scope} do
      bare_phase = "phase-norm2-#{System.unique_integer([:positive])}"

      child =
        mk_task!("pn2-child-#{System.unique_integer([:positive])}", scope, @dataset, %{
          "parent_id" => bare_phase
        })

      results = Queue.ready(scope ++ [dataset: @dataset, phase_id: "drafts." <> bare_phase])
      assert child.id in ids_of(results)
    end
  end

  describe "ready/1 — deterministic offset pages" do
    test "consecutive pages are disjoint and beyond-end is empty", %{scope: scope} do
      phase_id = "phase-offset-#{System.unique_integer([:positive])}"

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      ids = 1..4 |> Enum.map(fn _ -> Ecto.UUID.generate() end) |> Enum.sort(:desc)

      rows =
        Enum.with_index(ids, fn id, index ->
          %{
            id: id,
            doc_id: "offset-#{index}-#{System.unique_integer([:positive])}",
            type: "task",
            dataset: @dataset,
            title: "offset #{index}",
            status: "draft",
            content: %{
              "kind" => "task",
              "lifecycle_status" => "open",
              "parent_id" => phase_id,
              "priority" => 1
            },
            workspace_id: scope[:workspace_id],
            project_id: scope[:project_id],
            inserted_at: now,
            updated_at: now,
            rev: "offset-#{index}"
          }
        end)

      {4, nil} = Repo.insert_all(Document, rows)

      opts = scope ++ [dataset: @dataset, phase_id: phase_id, limit: 2]
      first = Queue.ready(opts ++ [offset: 0]) |> ids_of()
      second = Queue.ready(opts ++ [offset: 2]) |> ids_of()
      expected = Enum.sort(ids)

      assert first == Enum.take(expected, 2)
      assert second == Enum.drop(expected, 2)
      assert first ++ second == expected
      assert MapSet.disjoint?(MapSet.new(first), MapSet.new(second))
      assert Queue.ready(opts ++ [offset: 4]) == []
      assert Queue.ready(opts ++ [offset: 0]) |> ids_of() == first
    end
  end

  # ─── (7) content.dependencies gates readiness (fail-closed) ──────────────

  describe "ready/1 — content.dependencies gating" do
    test "all dependencies done => ready", %{scope: scope} do
      phase_id = "phase-dep-ok-#{System.unique_integer([:positive])}"
      dep_id = "dep-done-#{System.unique_integer([:positive])}"
      _dep = mk_task!(dep_id, scope, @dataset, %{"lifecycle_status" => "done"})

      main =
        mk_task!("main-dep-ok-#{System.unique_integer([:positive])}", scope, @dataset, %{
          "parent_id" => phase_id,
          "dependencies" => [dep_id]
        })

      assert main.id in ids_of(Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id]))
    end

    test "one open dependency => NOT ready and NOT claimable via queue-claim", %{scope: scope} do
      phase_id = "phase-dep-open-#{System.unique_integer([:positive])}"
      dep_id = "dep-open-#{System.unique_integer([:positive])}"
      # The dependency is deliberately parentless so the phase-scoped ready set
      # contains ONLY `main` — an empty result then proves `main` is excluded.
      _dep = mk_task!(dep_id, scope, @dataset, %{"lifecycle_status" => "open"})

      main =
        mk_task!("main-dep-open-#{System.unique_integer([:positive])}", scope, @dataset, %{
          "parent_id" => phase_id,
          "dependencies" => [dep_id]
        })

      refute main.id in ids_of(Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id]))
      # Nothing else is in this phase, so queue-claim finds nothing to claim.
      assert {:ok, nil} =
               Tasks.claim("dep-worker", scope ++ [dataset: @dataset, phase_id: phase_id])
    end

    test "a dangling dependency doc_id fails CLOSED (not ready)", %{scope: scope} do
      phase_id = "phase-dep-dangle-#{System.unique_integer([:positive])}"

      main =
        mk_task!("main-dep-dangle-#{System.unique_integer([:positive])}", scope, @dataset, %{
          "parent_id" => phase_id,
          "dependencies" => ["no-such-task-#{System.unique_integer([:positive])}"]
        })

      assert Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id]) == []
      refute main.id in ids_of(Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id]))
    end

    test "empty and absent dependencies are unaffected (ready)", %{scope: scope} do
      phase_id = "phase-dep-empty-#{System.unique_integer([:positive])}"

      empty =
        mk_task!("main-dep-empty-#{System.unique_integer([:positive])}", scope, @dataset, %{
          "parent_id" => phase_id,
          "dependencies" => []
        })

      absent =
        mk_task!("main-dep-absent-#{System.unique_integer([:positive])}", scope, @dataset, %{
          "parent_id" => phase_id
        })

      ready_ids = ids_of(Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id]))
      assert empty.id in ready_ids
      assert absent.id in ready_ids
    end

    test "legacy non-array dependencies are treated as no dependencies", %{scope: scope} do
      phase_id = "phase-dep-legacy-#{System.unique_integer([:positive])}"
      id = Ecto.UUID.generate()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {1, nil} =
        Repo.insert_all(Document, [
          %{
            id: id,
            doc_id: "main-dep-legacy-#{System.unique_integer([:positive])}",
            type: "task",
            dataset: @dataset,
            title: "legacy non-array dependencies",
            status: "draft",
            content: %{
              "kind" => "task",
              "lifecycle_status" => "open",
              "parent_id" => phase_id,
              "dependencies" => "legacy-dependency-id"
            },
            workspace_id: scope[:workspace_id],
            project_id: scope[:project_id],
            inserted_at: now,
            updated_at: now,
            rev: "legacy-non-array"
          }
        ])

      assert id in ids_of(Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id]))
    end

    test "dependency match tolerates a drafts. prefix on either side", %{scope: scope} do
      phase_id = "phase-dep-prefix-#{System.unique_integer([:positive])}"
      u = System.unique_integer([:positive])

      # dep stored bare + done, referenced WITH the drafts. prefix.
      bare_dep = "dep-bare-#{u}"
      _bare = mk_task!(bare_dep, scope, @dataset, %{"lifecycle_status" => "done"})

      # dep stored WITH drafts. + done, referenced bare.
      drafts_dep_base = "dep-drafted-#{u}"

      _drafted =
        mk_task!("drafts." <> drafts_dep_base, scope, @dataset, %{"lifecycle_status" => "done"})

      main =
        mk_task!("main-dep-prefix-#{u}", scope, @dataset, %{
          "parent_id" => phase_id,
          "dependencies" => ["drafts." <> bare_dep, drafts_dep_base]
        })

      assert main.id in ids_of(Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id]))
    end

    test "dataset-less ready keeps dependency satisfaction isolated by dataset", %{scope: scope} do
      phase_id = "phase-dep-dataset-#{System.unique_integer([:positive])}"
      dep_id = "dep-dataset-#{System.unique_integer([:positive])}"

      _done_elsewhere =
        mk_task!(dep_id, scope, @dataset_alt, %{"lifecycle_status" => "done"})

      _open_here = mk_task!(dep_id, scope, @dataset, %{"lifecycle_status" => "open"})

      main =
        mk_task!("main-dep-dataset-#{System.unique_integer([:positive])}", scope, @dataset, %{
          "parent_id" => phase_id,
          "dependencies" => [dep_id]
        })

      refute main.id in ids_of(Queue.ready(scope ++ [phase_id: phase_id]))
    end

    test "workspace-wide ready keeps dependency satisfaction isolated by project", %{
      scope: scope
    } do
      workspace_id = scope[:workspace_id]
      other_project = TenancyFixtures.create_project!(workspace_id)
      other_scope = [workspace_id: workspace_id, project_id: other_project.id]
      register_schemas!(other_scope, @dataset)

      phase_id = "phase-dep-project-#{System.unique_integer([:positive])}"
      dep_id = "dep-project-#{System.unique_integer([:positive])}"

      _done_elsewhere =
        mk_task!(dep_id, other_scope, @dataset, %{"lifecycle_status" => "done"})

      _open_here = mk_task!(dep_id, scope, @dataset, %{"lifecycle_status" => "open"})

      main =
        mk_task!("main-dep-project-#{System.unique_integer([:positive])}", scope, @dataset, %{
          "parent_id" => phase_id,
          "dependencies" => [dep_id]
        })

      refute main.id in ids_of(
               Queue.ready(
                 workspace_id: workspace_id,
                 dataset: @dataset,
                 phase_id: phase_id
               )
             )
    end

    test "dependency plan hashes a one-time done-task scan", %{scope: scope} do
      dataset = "queue-plan-#{System.unique_integer([:positive])}"
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      rows =
        Enum.flat_map(1..200, fn index ->
          dep_id = "plan-dep-#{index}"

          [
            %{
              id: Ecto.UUID.generate(),
              doc_id: dep_id,
              type: "task",
              dataset: dataset,
              title: dep_id,
              status: "draft",
              content: %{"kind" => "task", "lifecycle_status" => "done"},
              workspace_id: scope[:workspace_id],
              project_id: scope[:project_id],
              inserted_at: now,
              updated_at: now,
              rev: "done-#{index}"
            },
            %{
              id: Ecto.UUID.generate(),
              doc_id: "plan-main-#{index}",
              type: "task",
              dataset: dataset,
              title: "plan-main-#{index}",
              status: "draft",
              content: %{
                "kind" => "task",
                "lifecycle_status" => "open",
                "dependencies" => [dep_id]
              },
              workspace_id: scope[:workspace_id],
              project_id: scope[:project_id],
              inserted_at: now,
              updated_at: now,
              rev: "main-#{index}"
            }
          ]
        end)

      {400, nil} = Repo.insert_all(Document, rows)

      # Fresh stats: without ANALYZE the planner sees default estimates for the
      # 400 just-inserted rows and its join choice varies per runner (live flake:
      # the Hash pin below failed on runners that picked another strategy).
      Repo.query!("ANALYZE documents")

      query = Queue.ready_query(scope ++ [dataset: dataset, limit: 200])
      {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)

      explain = Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params)
      document = explain.rows |> hd() |> hd() |> hd()
      nodes = plan_nodes(document)

      done_cte = Enum.find(nodes, &(&1["Subplan Name"] == "CTE ready_done_tasks"))
      unsatisfied_cte = Enum.find(nodes, &(&1["Subplan Name"] == "CTE ready_unsatisfied_tasks"))

      assert done_cte
      assert unsatisfied_cte

      # The done-task CTE reads `documents` — assert it does so at most once (not
      # per-row), same plan-agnostic bound as the CTE-scan check below rather
      # than pinning `== 1` (a pruned/materialized plan reports 0 and flaked).
      done_doc_scans =
        Enum.filter(plan_nodes(done_cte), &(&1["Relation Name"] == "documents"))

      assert done_doc_scans != []

      assert Enum.all?(done_doc_scans, &(&1["Actual Loops"] <= 1)),
             "done-task documents scan looped per row (loops: #{inspect(Enum.map(done_doc_scans, & &1["Actual Loops"]))})"

      # The property under test is ONE-TIME COMPUTATION of the done-task set —
      # the subquery runs once, not once per candidate row. That is guaranteed
      # STRUCTURALLY by `with_cte(..., materialized: true)` (queue.ex) and shown
      # in the plan by the CTE subplan node itself running exactly once
      # (`done_cte`'s own Actual Loops == 1). Its underlying `documents` scan
      # running at most once (asserted above) is the same guarantee from the
      # inside.
      #
      # NOTE (the earlier flake's real cause): a `CTE Scan` node in the
      # consuming query is NOT the computation — it is a cheap READ of the
      # already-materialized buffer. A nested-loop join legitimately re-reads it
      # once per outer row (loops == row_count), which is correct and fast; a
      # prior assertion pinned that read count and failed on plan variance while
      # proving nothing (materialization already guarantees single computation).
      # So we assert the COMPUTATION-once property, not the join's read count.
      assert done_cte["Actual Loops"] == 1,
             "done-task CTE was not computed once (materialized) — Actual Loops: #{inspect(done_cte["Actual Loops"])}"
    end
  end

  # ─── (8) axis-2 cancelled-blocker stranding — fail-closed correct-by-design ─
  #
  # Protective tests for the tlv-bl-axis2-cancelled-strand ruling (see the
  # moduledoc): a cancelled dependency does NOT satisfy axis 2 (no carve-out),
  # and the D7 escape hatch (cancelled -> open -> done) un-strands dependents.

  # Flip a task's lifecycle_status by direct DB write. Deliberately bypasses
  # the Content.Writer seam (where D7 transition legality is enforced): this
  # file tests QUEUE readiness semantics, not transition legality, and the
  # `open -> done` leg below is only legal in the real system via the close
  # verb — an engine primitive that also writes the row directly.
  defp set_lifecycle!(doc, status) do
    doc = Repo.get!(Document, doc.id)

    doc
    |> Ecto.Changeset.change(content: Map.put(doc.content, "lifecycle_status", status))
    |> Repo.update!()
  end

  describe "ready/1 — axis-2 cancelled-blocker stranding (ruling: fail-closed)" do
    test "one cancelled dependency => NOT ready and NOT claimable via queue-claim",
         %{scope: scope} do
      phase_id = "phase-dep-cancelled-#{System.unique_integer([:positive])}"
      dep_id = "dep-cancelled-#{System.unique_integer([:positive])}"
      # Mirror of the "one open dependency" fixture with the blocker CANCELLED:
      # axis 2 satisfies only on done, so cancelled must gate exactly like open.
      # Mutation-provable — a query-time carve-out (cancelled admitted to the
      # done set, or the anti-join loosened) makes `main` ready and fails this.
      # The dependency is deliberately parentless so the phase-scoped ready set
      # contains ONLY `main` — an empty result then proves `main` is excluded.
      _dep = mk_task!(dep_id, scope, @dataset, %{"lifecycle_status" => "cancelled"})

      main =
        mk_task!("main-dep-cancelled-#{System.unique_integer([:positive])}", scope, @dataset, %{
          "parent_id" => phase_id,
          "dependencies" => [dep_id]
        })

      assert Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id]) == []
      refute main.id in ids_of(Queue.ready(scope ++ [dataset: @dataset, phase_id: phase_id]))
      # Nothing else is in this phase, so queue-claim finds nothing to claim.
      assert {:ok, nil} =
               Tasks.claim(
                 "dep-cancelled-worker",
                 scope ++ [dataset: @dataset, phase_id: phase_id]
               )
    end

    test "escape hatch: reopening a cancelled blocker (cancelled -> open -> done) un-strands the dependent",
         %{scope: scope} do
      phase_id = "phase-dep-reopen-#{System.unique_integer([:positive])}"
      dep_id = "dep-reopen-#{System.unique_integer([:positive])}"
      dep = mk_task!(dep_id, scope, @dataset, %{"lifecycle_status" => "cancelled"})

      main =
        mk_task!("main-dep-reopen-#{System.unique_integer([:positive])}", scope, @dataset, %{
          "parent_id" => phase_id,
          "dependencies" => [dep_id]
        })

      opts = scope ++ [dataset: @dataset, phase_id: phase_id]

      # Stranded while the blocker is cancelled.
      refute main.id in ids_of(Queue.ready(opts))

      # D7 makes cancelled -> open legal: reopened, the blocker gates like any
      # open dependency — still not ready (recoverable, not yet recovered).
      set_lifecycle!(dep, "open")
      refute main.id in ids_of(Queue.ready(opts))

      # Driven to done, the dependency satisfies axis 2 — dependent is ready.
      set_lifecycle!(dep, "done")
      assert main.id in ids_of(Queue.ready(opts))
    end
  end
end
