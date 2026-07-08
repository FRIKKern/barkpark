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
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.Queue

  @dataset "production"
  @dataset_alt "staging"

  setup do
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
      Map.merge(
        %{"kind" => "task", "lifecycle_status" => "open"},
        content_extra
      )

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
  end
end
