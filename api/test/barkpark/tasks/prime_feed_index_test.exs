defmodule Barkpark.Tasks.PrimeFeedIndexTest do
  @moduledoc """
  Index-USE pin for the task-activity feed behind `GET /v1/tasks/prime`
  (migration 20260902001100, `mutation_events_workspace_type_inserted_at_idx`).

  `Barkpark.Tasks.Prime.recent_events/2` reads

      WHERE type = 'task' AND mutation LIKE 'task.%' AND workspace_id = $1
      ORDER BY inserted_at DESC LIMIT $2

  and until that migration `mutation_events` had NO index able to order by
  `inserted_at`. On guerrilla (2,195 MB, 262,718 rows, ONE workspace) the
  planner answered every call — roughly one per second per TUI board — with a
  Parallel Seq Scan: 2 extra backends, 12,538 buffers, 70 ms, 87,588 rows
  discarded per worker to return twenty.

  ## What is pinned, and how it can fail

  The plan is explained over the SQL `Prime.prime/1` ACTUALLY emits, captured
  from `[:barkpark, :repo, :query]` telemetry — not over a hand-copied
  replica — so a later rewrite of `recent_events/2` into a shape the index
  cannot serve reds this test instead of quietly slipping past it.

  Two assertions carry the weight:

    * the plan names the index, and
    * the plan contains NO `Sort` node.

  The second is what makes the first non-vacuous. The pre-existing
  `mutation_events_workspace_id_index` can also satisfy `workspace_id = $1` —
  but only with a Sort on top, because it knows nothing about `inserted_at`.
  Only a `(workspace_id, type, inserted_at DESC)` key lets the LIMIT stop the
  scan after a handful of tuples.

  ## Scale gating and the red-without arm

  At this suite's ~3,000-row corpus a raw seq scan is genuinely the cheapest
  plan, so the DEFAULT plan would prove nothing about index eligibility.
  `SET LOCAL enable_seqscan = off` (transaction-scoped inside the sandbox, the
  same device `tag_registry_trgm_test.exs` uses) forces the planner to reveal
  which index it CAN use. That is a statement about reachability, which is
  exactly what the production-scale measurement in the migration's moduledoc
  supplies the magnitude for.

  The final test is the mutation proof: with the index DROPped inside the test
  transaction (and rolled back with it), the very same SQL falls back to
  `mutation_events_workspace_id_index` + a Sort. Delete the migration and the
  first test reds; break the index's column order and it reds too.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Tasks.Prime
  alias Barkpark.TenancyFixtures

  @index "mutation_events_workspace_type_inserted_at_idx"
  @repo_query_event [:barkpark, :repo, :query]
  @dataset "production"

  # Enough rows that the ordered index is a genuinely cheaper way to reach the
  # LIMIT than "scan the workspace index and sort" — the competitor this test
  # exists to rule out.
  @seed 3_000

  setup do
    ws = TenancyFixtures.create_workspace!()
    now = DateTime.utc_now()

    rows =
      for i <- 1..@seed do
        # Two thirds of the corpus is task.* on type "task" (what the feed
        # wants); the rest is noise the feed must discard, in the same ~1:3
        # ratio prod carries (57,637 task.% of 246,814 type='task' rows).
        {type, mutation} =
          case rem(i, 3) do
            0 -> {"task", "task.claimed"}
            1 -> {"task", "doc.updated"}
            2 -> {"paper", "doc.updated"}
          end

        %{
          dataset: @dataset,
          type: type,
          doc_id: "task-#{i}",
          mutation: mutation,
          rev: "rev-#{i}",
          document: %{},
          workspace_id: ws.id,
          inserted_at: DateTime.add(now, -i, :second)
        }
      end

    {@seed, _} = Repo.insert_all(MutationEvent, rows)

    # In-transaction ANALYZE is honored on the sandbox connection; without it
    # the planner costs this corpus off empty statistics.
    Repo.query!("ANALYZE mutation_events")

    %{ws: ws}
  end

  describe "the prime task feed" do
    test "rides #{@index} with the WHERE as an Index Cond and no Sort", %{ws: ws} do
      {sql, params} = feed_sql(ws)

      Repo.query!("SET LOCAL enable_seqscan = off")
      plan = explain(sql, params)

      assert plan =~ @index,
             "expected Prime's recent-events read to ride #{@index}, got:\n#{plan}"

      refute plan =~ "Sort",
             "expected ORDER BY inserted_at DESC to be satisfied by the index " <>
               "(no Sort node), got:\n#{plan}"

      assert plan =~ ~r/Index Cond: [^\n]*workspace_id/,
             "expected workspace_id to be an Index Cond, not a post-scan Filter, got:\n#{plan}"

      assert plan =~ ~r/Index Cond: [^\n]*type/,
             "expected type to be an Index Cond, not a post-scan Filter, got:\n#{plan}"
    end

    test "the captured SQL really is Prime's mutation_events read", %{ws: ws} do
      {sql, params} = feed_sql(ws)

      # Guards the oracle itself: if this ever stops being the newest-first,
      # workspace-scoped task feed, the plan assertion above is describing some
      # other query and must be revisited rather than trusted.
      assert sql =~ ~s(FROM "mutation_events")
      assert sql =~ "'task.%'"
      assert sql =~ ~r/ORDER BY [^\n]*inserted_at" DESC/
      assert length(params) == 2

      # And the read is live: the seeded task.* events come back newest-first.
      %{recent_events: events} = Prime.prime(workspace_id: ws.id, limit: 10)
      assert length(events) == 10
      assert Enum.all?(events, &String.starts_with?(&1.event, "task."))

      ats = Enum.map(events, & &1.at)
      assert ats == Enum.sort(ats, {:desc, DateTime})
    end

    test "red-without: drop the index and the same SQL falls back to a Sort", %{ws: ws} do
      {sql, params} = feed_sql(ws)

      # Transaction-scoped: the sandbox rolls this DROP back at test end.
      Repo.query!("DROP INDEX #{@index}")
      Repo.query!("SET LOCAL enable_seqscan = off")

      plan = explain(sql, params)

      refute plan =~ @index
      assert plan =~ "Sort", "without the index the feed must sort, got:\n#{plan}"

      assert plan =~ "mutation_events_workspace_id_index",
             "expected the workspace-only index to be the fallback, got:\n#{plan}"
    end
  end

  # The SQL and params `Prime.prime/1` itself emits for the mutation_events
  # feed, lifted off Ecto's query telemetry.
  defp feed_sql(ws) do
    captured =
      capture_sql(fn -> Prime.prime(workspace_id: ws.id, limit: 10) end)

    [{sql, params}] =
      Enum.filter(captured, fn {sql, _params} -> sql =~ ~s(FROM "mutation_events") end)

    {sql, params}
  end

  # Ecto emits query telemetry synchronously in the calling process, so
  # filtering on `self()` keeps a sibling suite's queries out of the bucket.
  defp capture_sql(fun) do
    test_pid = self()
    handler_id = {__MODULE__, test_pid}

    :ok =
      :telemetry.attach(
        handler_id,
        @repo_query_event,
        fn _event, _measurements, metadata, ^test_pid ->
          if self() == test_pid do
            send(test_pid, {:sql, metadata[:query], metadata[:params]})
          end

          :ok
        end,
        test_pid
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_sql([])
  end

  defp drain_sql(acc) do
    receive do
      {:sql, sql, params} -> drain_sql([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp explain(sql, params) do
    Repo.query!("EXPLAIN " <> sql, params).rows
    |> Enum.map_join("\n", &hd/1)
  end
end
