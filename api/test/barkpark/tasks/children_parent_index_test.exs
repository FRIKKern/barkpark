defmodule Barkpark.Tasks.ChildrenParentIndexTest do
  @moduledoc """
  The plan pin for `documents_task_parent_id_idx`
  (migration 20260902001000, task-e2f5ecca0be9a6d1 criterion 1).

  ## What is pinned and why

  Every "who are `<id>`'s children?" read spells its match prefix-agnostically:

      regexp_replace(content->>'parent_id', '^drafts\\.', '') =
        regexp_replace($1, '^drafts\\.', '')

  That left-hand side is a FUNCTION of a jsonb field, so only an EXPRESSION
  index whose stored expression is textually identical can serve it. Until the
  migration there was none — `TasksController.child_tasks/2` (the ONLY producer
  of `bp task get`'s `child_count`, so every single `bp task get`),
  `Params.batch_child_counts/2`, `Tasks.Rail.rail_children/2`,
  `Tasks.Queue.maybe_filter_phase/2` and the two `Tasks.Query` list filters all
  ran `Seq Scan on documents`. Measured on guerrilla 2026-09-01: seq_scan
  3,969,442, seq_tup_read 21.5 billion, on a ~10.7k-row table.

  The failure mode this file exists to catch is silent: nothing breaks, no test
  reds, the queries keep returning the right rows — they just go back to
  reading the whole corpus. Two ways to reintroduce it, both caught here:
  dropping/renaming the index, and "tidying" the fragment in ANY of the six
  call sites so it no longer matches the index expression character-for-
  character (e.g. `ltrim`, a different regex, or `NULLIF`).

  ## Why `enable_seqscan = off`

  The suite's corpus is a few hundred rows in a handful of heap pages, where a
  sequential scan is genuinely the cheaper plan — the planner would refuse the
  index for a REASON, and the test would red on corpus size rather than on the
  index. Turning off the seq-scan preference asks the question this test is
  actually about: CAN the predicate be answered by an index at all? Before the
  migration the answer is no even with seqscan disabled (a disabled node is
  penalised, not forbidden — the plan falls back to `Seq Scan on documents`),
  which is exactly the red-without proved by `drops the index` below. On the
  production-shaped fixture (11k documents / 8.9k tasks) the planner picks the
  index with NO settings override at all: 68.3 ms / 29,942 buffers ->
  0.5 ms / 105 buffers.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Content.Document
  alias Barkpark.{Repo, TenancyFixtures}
  alias BarkparkWeb.TasksController.Params

  @index_name "documents_task_parent_id_idx"
  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    parent = "cpi-epic-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # 40 children of `parent` (a tenth of them carrying the `drafts.`-prefixed
    # spelling of the SAME parent, the twin shape the predicate exists for)
    # against 360 children of other parents — enough for the index to be the
    # discriminating structure and not a coin flip.
    rows =
      Enum.map(1..400, fn i ->
        parent_id =
          cond do
            rem(i, 10) == 0 -> "drafts." <> parent
            rem(i, 10) == 5 -> parent
            true -> "cpi-other-#{rem(i, 37)}"
          end

        %{
          id: Ecto.UUID.generate(),
          doc_id: "cpi-child-#{i}-#{System.unique_integer([:positive])}",
          type: "task",
          dataset: @dataset,
          title: "cpi-child-#{i}",
          status: "draft",
          content: %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "parent_id" => parent_id
          },
          workspace_id: ws.id,
          project_id: project.id,
          inserted_at: now,
          updated_at: now,
          rev: "cpi-#{i}"
        }
      end)

    {400, nil} = Repo.insert_all(Document, rows)

    # Fresh stats — without them the planner costs the 400 just-inserted rows
    # off stale estimates and its choice varies per runner.
    Repo.query!("ANALYZE documents")

    %{scope: scope, parent: parent}
  end

  # The EXACT query `TasksController.child_tasks/2` builds — same helpers, in
  # the same order, so a change to `maybe_filter_parent_id/2`'s fragment shows
  # up here rather than only in production.
  defp children_query(parent, scope) do
    from(d in Document,
      where: d.type == "task",
      order_by: [asc: d.inserted_at]
    )
    |> Barkpark.Tasks.Query.collapse_twins()
    |> Params.maybe_filter_workspace(Keyword.get(scope, :workspace_id))
    |> Params.maybe_filter_project(Keyword.get(scope, :project_id))
    |> Params.maybe_filter_parent_id(parent)
  end

  defp explain_nodes(query) do
    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)

    explain = Repo.query!("EXPLAIN (FORMAT JSON) " <> sql, params)

    explain.rows |> hd() |> hd() |> hd() |> plan_nodes()
  end

  defp plan_nodes(value) when is_list(value), do: Enum.flat_map(value, &plan_nodes/1)

  defp plan_nodes(value) when is_map(value),
    do: [value | value |> Map.values() |> Enum.flat_map(&plan_nodes/1)]

  defp plan_nodes(_value), do: []

  defp index_names(nodes), do: nodes |> Enum.map(& &1["Index Name"]) |> Enum.reject(&is_nil/1)

  # The `Index Cond`s of the plan — what the planner could answer INSIDE an
  # index rather than by rechecking the heap. The parent predicate appearing
  # here is the whole property: an index whose name is in the plan for some
  # OTHER column is not serving this lookup.
  defp index_conds(nodes), do: nodes |> Enum.map(& &1["Index Cond"]) |> Enum.reject(&is_nil/1)

  describe "documents_task_parent_id_idx" do
    test "the migration built it, valid, with the expression the queries emit" do
      %{rows: [[indexdef, valid]]} =
        Repo.query!(
          """
          SELECT pg_get_indexdef(i.indexrelid), i.indisvalid
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid
           WHERE c.relname::text = $1
          """,
          [@index_name]
        )

      # `indisvalid = false` is the CONCURRENTLY-timed-out corpse the migration
      # sweeps: present, matched by IF NOT EXISTS, and useless for reads. An
      # index that exists but is invalid must not read as a pass.
      assert valid, "#{@index_name} exists but is INVALID — a timed-out CONCURRENTLY build"

      assert indexdef =~ "regexp_replace((content ->> 'parent_id'::text), '^drafts\\.'::text"
      assert indexdef =~ "workspace_id"
      assert indexdef =~ "WHERE ((type)::text = 'task'::text)"
    end

    test "the children lookup rides it instead of scanning documents",
         %{scope: scope, parent: parent} do
      query = children_query(parent, scope)

      # Correctness first: the plan pin is worthless if the query stopped
      # answering the question. 80 children — 40 written with the bare parent
      # id and 40 with its `drafts.`-prefixed twin spelling, which is the whole
      # reason the predicate normalises instead of comparing raw.
      assert length(Repo.all(query)) == 80

      Repo.query!("SET LOCAL enable_seqscan = off")
      nodes = explain_nodes(query)

      # Instrument self-test: an empty node list cannot masquerade as a pass.
      assert Enum.any?(nodes, &(&1["Relation Name"] == "documents")),
             "the plan never touched `documents` — the fixture, not the index, is broken"

      node_types = nodes |> Enum.map(& &1["Node Type"]) |> Enum.reject(&is_nil/1)

      assert @index_name in index_names(nodes),
             "the children lookup is not using #{@index_name} " <>
               "(indexes in plan: #{inspect(index_names(nodes))}, " <>
               "node types: #{inspect(node_types)})"

      # …and it is serving THIS predicate, not riding in for some other column.
      assert Enum.any?(index_conds(nodes), &String.contains?(&1, "parent_id")),
             "no index condition mentions parent_id — the predicate is still a heap " <>
               "filter (index conds: #{inspect(index_conds(nodes))})"
    end

    test "batch_child_counts' ANY() form rides it too", %{scope: scope, parent: parent} do
      keys = [parent | Enum.map(0..9, &"cpi-other-#{&1}")]

      query =
        from(d in Document,
          where: d.type == "task",
          where:
            fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content) in ^keys,
          group_by: fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content),
          select:
            {fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content),
             count(d.id)}
        )
        |> Params.maybe_filter_workspace(Keyword.get(scope, :workspace_id))

      Repo.query!("SET LOCAL enable_seqscan = off")
      nodes = explain_nodes(query)

      assert @index_name in index_names(nodes),
             "batch_child_counts' `= ANY($1)` form is not using #{@index_name} " <>
               "(indexes in plan: #{inspect(index_names(nodes))})"
    end

    # RED-WITHOUT, in-suite. Dropping the index inside this test's sandbox
    # transaction (rolled back with it) proves the assertions above are load-
    # bearing: the SAME query under the SAME settings stops being able to
    # answer the parent predicate through ANY index. Without this, a plan
    # assertion that happened to pass for some other reason would look
    # identical to a real one.
    #
    # NOTE it does NOT become a `Seq Scan`: with `enable_seqscan = off` the
    # planner falls back to a bitmap scan over `documents_workspace_*` and
    # RECHECKS the regexp on the heap — every task row in the workspace read
    # and discarded, which is the same whole-corpus read the seq scan was,
    # wearing an index's name. That is exactly why the pin above asserts the
    # `Index Cond`, not merely the presence of some index in the plan.
    test "red-without: drop the index and no index can answer the parent predicate",
         %{scope: scope, parent: parent} do
      query = children_query(parent, scope)

      Repo.query!("DROP INDEX #{@index_name}")
      Repo.query!("SET LOCAL enable_seqscan = off")

      nodes = explain_nodes(query)

      # Instrument self-test: the fixture still reaches `documents`, so an
      # empty plan cannot masquerade as a pass here either.
      assert Enum.any?(nodes, &(&1["Relation Name"] == "documents")),
             "the plan never touched `documents` — the fixture, not the index, is broken"

      refute @index_name in index_names(nodes),
             "the index was dropped inside this transaction yet the plan still names it"

      refute Enum.any?(index_conds(nodes), &String.contains?(&1, "parent_id")),
             "without #{@index_name} nothing should be able to probe on parent_id, yet an " <>
               "index condition still mentions it (#{inspect(index_conds(nodes))}) — a " <>
               "SECOND index now serves this predicate and the pin above is no longer " <>
               "proving that this migration is what serves it."
    end
  end
end
