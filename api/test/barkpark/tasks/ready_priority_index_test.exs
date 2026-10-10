defmodule Barkpark.Tasks.ReadyPriorityIndexTest do
  @moduledoc """
  task-80da62a024b935f9 — the ready queue is served by the partial, guarded
  `documents_task_ready_priority_idx`. Pinned here:

    * the ORDER is unchanged for integer/absent priorities (set equality
      against the order the old `(priority)::int` key gave);
    * a non-integer priority sorts last instead of erroring;
    * the planner walks the index in ORDER BY order (Index Scan, no Sort)
      with the parameters known; a GENERIC plan cannot, which is why every
      ready executor runs the query with `prepare: :unnamed`;
    * the index's predicate and expression are the query's, so a drift in
      either fails here instead of silently turning the index off.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.{Queue, Validation}

  @index "documents_task_ready_priority_idx"

  defp seed!(ws, proj, rows) do
    {:ok, ds} = Barkpark.Tenancy.get_or_create_dataset(proj.id, "production")
    now = DateTime.utc_now()

    entries =
      for {{doc_id, priority, age}, i} <- Enum.with_index(rows) do
        content =
          %{"lifecycle_status" => "open", "kind" => "task"}
          |> then(fn c ->
            if priority == :absent, do: c, else: Map.put(c, "priority", priority)
          end)

        %{
          id: Ecto.UUID.generate(),
          doc_id: doc_id,
          type: "task",
          dataset: "production",
          title: doc_id,
          status: "published",
          rev: "r#{i}",
          workspace_id: ws.id,
          project_id: proj.id,
          dataset_id: ds.id,
          content: content,
          inserted_at: DateTime.add(now, -age, :second),
          updated_at: now
        }
      end

    Repo.insert_all(Document, entries)
    entries
  end

  defp ready_ids(ws, proj),
    do: Queue.ready(workspace_id: ws.id, project_id: proj.id, limit: 100) |> Enum.map(& &1.doc_id)

  test "integer and absent priorities keep today's order (set equality and sequence)" do
    ws = create_workspace!()
    proj = create_project!(ws)

    rows =
      for i <- 1..30 do
        priority = if rem(i, 7) == 0, do: :absent, else: rem(i * 3, 5)
        {"order-#{i}", priority, i * 10}
      end

    entries = seed!(ws, proj, rows)

    # The order the pre-change key gave: (priority)::int ASC NULLS LAST,
    # inserted_at ASC, id ASC.
    expected =
      entries
      |> Enum.sort_by(
        fn e -> {Map.get(e.content, "priority") || 1_000_000, e.inserted_at, e.id} end,
        fn {pa, ia, da}, {pb, ib, db} ->
          cond do
            pa != pb -> pa < pb
            ia != ib -> DateTime.compare(ia, ib) == :lt
            true -> da <= db
          end
        end
      )
      |> Enum.map(& &1.doc_id)

    got = ready_ids(ws, proj)
    assert MapSet.new(got) == MapSet.new(expected)
    assert got == expected
  end

  test "a non-integer priority sorts last instead of failing the read" do
    ws = create_workspace!()
    proj = create_project!(ws)
    seed!(ws, proj, [{"good-a", 1, 30}, {"bad", "high", 20}, {"good-b", 2, 10}])

    assert ready_ids(ws, proj) == ["good-a", "good-b", "bad"]
  end

  defp explain_ready(ws, proj, generic?) do
    q = Queue.ready_query(workspace_id: ws.id, project_id: proj.id, limit: 1)
    {sql, params} = Repo.to_sql(:all, q)

    Repo.transaction(fn ->
      # A tiny test table makes a seq scan + sort cheapest; switching both off
      # asks only whether the index CAN serve the walk, which is what a drift
      # between the query and the index would break.
      Repo.query!("SET LOCAL enable_seqscan = off")
      Repo.query!("SET LOCAL enable_sort = off")

      %{rows: rows} =
        if generic? do
          # A REAL generic plan: plan_cache_mode only governs named prepared
          # statements, so PREPARE one and EXPLAIN its EXECUTE. Parameters are
          # unknown at plan time here, exactly as for a reused Postgrex
          # statement.
          Repo.query!("SET LOCAL plan_cache_mode = force_generic_plan")
          Repo.query!("PREPARE ready_probe AS " <> sql)

          Repo.query!(
            "EXPLAIN EXECUTE ready_probe(" <> Enum.map_join(params, ", ", &literal/1) <> ")"
          )
        else
          Repo.query!("EXPLAIN " <> sql, params)
        end

      Enum.map_join(rows, "\n", &hd/1)
    end)
    |> elem(1)
  end

  defp literal(nil), do: "NULL"
  defp literal(b) when is_boolean(b), do: to_string(b)
  defp literal(n) when is_integer(n), do: Integer.to_string(n)
  defp literal(<<_::128>> = uuid), do: "'" <> Ecto.UUID.load!(uuid) <> "'"
  defp literal(s) when is_binary(s), do: "'" <> String.replace(s, "'", "''") <> "'"

  defp literal(list) when is_list(list),
    do: "ARRAY[" <> Enum.map_join(list, ", ", &literal/1) <> "]"

  test "with its parameters known (how every executor runs it), the planner walks the index: Index Scan, no Sort" do
    ws = create_workspace!()
    proj = create_project!(ws)
    seed!(ws, proj, for(i <- 1..20, do: {"plan-#{i}", rem(i, 5), i}))
    Repo.query!("ANALYZE documents")

    plan = explain_ready(ws, proj, false)
    assert plan =~ "Index Scan using #{@index}", plan
    refute plan =~ ~r/^\s*(->\s+)?Sort\b/m, "still sorts:\n#{plan}"
  end

  # WHY every executor passes `prepare: :unnamed`: a GENERIC plan (a reused
  # named statement, parameters unknown) cannot prove the partial predicate
  # from the bound status list, so it cannot use the index at all. This pins
  # that fact, so the executor option is not dropped as an optimisation.
  test "a generic plan cannot use the partial index, so the ready executors run unnamed" do
    ws = create_workspace!()
    proj = create_project!(ws)
    seed!(ws, proj, for(i <- 1..20, do: {"gen-#{i}", rem(i, 5), i}))
    Repo.query!("ANALYZE documents")

    refute explain_ready(ws, proj, true) =~ "Index Scan using #{@index}"
    assert Queue.ready_repo_opts()[:prepare] == :unnamed
  end

  test "the index predicate is the claimable set and its expression is the query's" do
    %{rows: [[indexdef]]} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [@index])

    # The predicate lists exactly the claimable statuses the query binds.
    [_, listed] = Regex.run(~r/ANY \(ARRAY\[(.*?)\]\)/, indexdef)
    in_index = Regex.scan(~r/'([a-z_]+)'::text/, listed) |> Enum.map(&List.last/1) |> Enum.sort()
    assert in_index == Enum.sort(Validation.claimable_statuses())
    assert indexdef =~ "'^-{0,1}[0-9]+$'"
    assert Queue.ready_priority_sql() =~ "'^-{0,1}[0-9]+$'"
  end
end
