defmodule Barkpark.ConcurrencyCase do
  @moduledoc """
  A test case for the handful of invariants that only a REAL two-connection
  race can measure, filed as task-b4ccea2693ce9d5e.

  ## Why this exists at all

  `Barkpark.DataCase` runs every test inside the Ecto SQL sandbox, and the
  sandbox cannot express a concurrent writer in either ownership mode:

    * `{:shared, pid}` serialises every process onto ONE checked-out
      connection, so a "concurrent" second writer QUEUES behind the first
      instead of racing it. A concurrency test written this way passes with
      the serialization deleted — a vacuous green, which is worse than no
      test; and
    * `:manual` gives each process its own transaction, so a row inserted by
      setup is invisible to the second writer. The race cannot even be set up.

  So the outcome-level proof for the `bp task stamp` read-modify-write
  (66 concurrent stamps accepted, 66 landed, 0 lost) lived only in a hand-run
  that nothing re-runs. This case template is the deliberate, scoped opt-out
  that lets that run live in the suite.

  ## The isolation mechanism, in full

  1. **`async: false` is enforced, not requested.** `setup/1` raises if the
     using module is async. ExUnit runs every async module first and then the
     sync ones one at a time, so flipping the global sandbox mode here can
     never be observed by a sibling test.
  2. **`Sandbox.mode(Repo, :auto)` for the duration of the test**, restored to
     `:manual` in `on_exit/1`. In `:auto` the sandbox pool behaves like an
     ordinary pool: no ownership, no wrapping transaction, and — the whole
     point — every process gets its OWN connection. Which also means **every
     write COMMITS**.
  3. **Every fixture lives under a per-test dataset string** handed to the
     test as `%{dataset: dataset}`, of the form `cxtest-<pid>-<n>`. `documents`,
     `revisions`, `mutation_events` and `schema_definitions` all carry a
     `dataset` column, so "everything this test created" is a PREDICATE
     (`dataset = $1`), not a list someone has to remember to append to. An
     enumeration is a snapshot; a predicate is a rule.
  4. **`on_exit/1` purges that predicate and then RE-READS it**, raising if a
     single row survives. The purge runs BEFORE the mode is restored to
     `:manual`, because after that a query from this process would need a
     sandbox checkout it does not own. Teardown is verified, not assumed —
     an uncleaned committed row reds a sibling branch on a box where every
     agent shares one `barkpark_test<partition>` database.

  A test that crashes mid-way still runs `on_exit/1`, so a failure cannot leak
  rows either.

  ## What the harness gives you

  `run_concurrently/3` runs N writers and PROVES they overlapped, rather than
  asserting it. Each writer holds ONE connection for its whole body
  (`Repo.checkout/2`), records that connection's `pg_backend_pid()`, and starts
  only after every sibling has signalled ready. The returned runs carry the
  backend pid and a monotonic `[started_at, finished_at]` window, and
  `overlap_report/1` turns those into two independent controls:

    * `distinct_backends == n` — a harness that silently serialised its writers
      onto one pooled connection (which is exactly what the sandbox does) would
      report 1; and
    * `overlapping_pairs == total_pairs` — every writer pair intersected in
      wall-clock time.

  Either one failing means the harness measured nothing, and the test is
  required to assert both BEFORE it asserts anything about the system under
  test. A concurrency test that cannot fail is theatre.
  """

  use ExUnit.CaseTemplate

  alias Barkpark.Repo

  using do
    quote do
      alias Barkpark.Repo

      import Ecto.Query
      import Barkpark.ConcurrencyCase
    end
  end

  setup tags do
    if tags[:async] do
      raise """
      #{inspect(tags[:module])} uses Barkpark.ConcurrencyCase with `async: true`.

      This case flips the GLOBAL Ecto sandbox mode to :auto and commits its
      writes. Running it alongside async siblings would take their sandbox
      away mid-test. Use `async: false`.
      """
    end

    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    dataset = unique_dataset()

    on_exit(fn ->
      try do
        remaining = purge_dataset!(dataset)

        if remaining != %{} do
          raise """
          Barkpark.ConcurrencyCase teardown left rows behind for dataset
          #{inspect(dataset)}: #{inspect(remaining)}.

          These rows are COMMITTED and shared with every other agent on this
          box. Fix the purge before this test ships.
          """
        end
      after
        Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
      end
    end)

    {:ok, dataset: dataset}
  end

  @doc """
  A dataset string unique to this test process, used as the teardown predicate.
  """
  def unique_dataset do
    pid = self() |> :erlang.pid_to_list() |> to_string() |> String.replace(~r/[^0-9]/, "")
    "cxtest-#{pid}-#{System.unique_integer([:positive])}"
  end

  @purge_tables [
    {"documents", "dataset"},
    {"revisions", "dataset"},
    {"mutation_events", "dataset"},
    {"schema_definitions", "dataset"}
  ]

  @doc """
  Delete every row this test's dataset owns, then RE-READ each table and return
  the counts that survived. An empty map means the teardown is proven, not
  assumed.

  ## Two constraints shape the body, and both are load-bearing

  **`documents` goes first.** `documents.current_revision_id` /
  `released_revision_id` point AT `revisions`, so the revisions cannot go
  first. The reverse FK (`revisions.document_id`) is `ON DELETE SET NULL`, NOT
  cascade — a deleted document leaves its revision ORPHANED and still carrying
  this dataset string. That is a designed behaviour (the migration is literally
  named `preserve_revision_history_on_document_delete`), and it means "delete
  the documents" does not clean up after itself.

  **`revisions` is append-only at the database.** The `revisions_immutable`
  trigger raises `revision history is append-only` for every DELETE at
  `pg_trigger_depth() = 1`. The suite's own precedent for a test that must get
  past it is `ALTER TABLE revisions DISABLE TRIGGER revisions_immutable`
  (`test/barkpark/cycle_fleet_test.exs`), and the whole purge therefore runs in
  ONE transaction: Postgres DDL is transactional and `ALTER TABLE` takes an
  `ACCESS EXCLUSIVE` lock, so no other session can even read the table while
  the guard is off, and a crash anywhere in the block rolls the guard back ON
  rather than leaving the production invariant disabled in a shared test
  database.
  """
  def purge_dataset!(dataset) do
    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!("ALTER TABLE revisions DISABLE TRIGGER revisions_immutable")

        try do
          for {table, col} <- @purge_tables do
            Repo.query!("DELETE FROM #{table} WHERE #{col} = $1", [dataset])
          end
        after
          Repo.query!("ALTER TABLE revisions ENABLE TRIGGER revisions_immutable")
        end
      end)

    count_dataset_rows(dataset)
  end

  @doc """
  Count the rows each table still holds for `dataset`. Tables with zero rows
  are omitted, so `%{}` is the clean verdict.
  """
  def count_dataset_rows(dataset) do
    for {table, col} <- @purge_tables,
        %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table} WHERE #{col} = $1", [dataset]),
        n > 0,
        into: %{},
        do: {table, n}
  end

  @doc """
  Run `fun.(index)` in `n` processes that genuinely overlap.

  Each worker holds ONE connection for its whole body, records that
  connection's backend pid, waits at a barrier until every sibling is ready,
  and then runs. Returns a list of run maps ordered by index:

      %{index: 0, backend_pid: 41234, started_at: .., finished_at: .., result: ..}

  Times are monotonic microseconds, so they are comparable across processes on
  one node and immune to wall-clock adjustment.
  """
  def run_concurrently(n, fun, opts \\ []) when is_integer(n) and n > 1 do
    timeout = Keyword.get(opts, :timeout, 60_000)
    parent = self()

    workers =
      for index <- 0..(n - 1) do
        Task.async(fn ->
          Repo.checkout(fn ->
            %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()", [])
            send(parent, {:barrier_ready, index})

            receive do
              :barrier_go -> :ok
            after
              timeout -> exit({:barrier_timeout, index})
            end

            started_at = System.monotonic_time(:microsecond)
            result = fun.(index)
            finished_at = System.monotonic_time(:microsecond)

            %{
              index: index,
              backend_pid: backend_pid,
              started_at: started_at,
              finished_at: finished_at,
              result: result
            }
          end)
        end)
      end

    for _ <- 1..n do
      receive do
        {:barrier_ready, _index} -> :ok
      after
        timeout ->
          Enum.each(workers, &Task.shutdown(&1, :brutal_kill))
          raise "run_concurrently/3: only some workers reached the barrier within #{timeout}ms"
      end
    end

    Enum.each(workers, &send(&1.pid, :barrier_go))

    workers
    |> Task.await_many(timeout)
    |> Enum.sort_by(& &1.index)
  end

  @doc """
  Turn `run_concurrently/3`'s runs into the two non-vacuity controls.

      %{
        n: 6,
        distinct_backends: 6,
        total_pairs: 15,
        overlapping_pairs: 15,
        non_overlapping: [],
        span_us: 412_337
      }

  `distinct_backends < n` means the writers shared a connection — the sandbox
  failure mode this whole case exists to escape. `overlapping_pairs <
  total_pairs` means some pair ran strictly one after the other.
  """
  def overlap_report(runs) do
    pairs = for a <- runs, b <- runs, a.index < b.index, do: {a, b}

    non_overlapping =
      for {a, b} <- pairs,
          not (a.started_at <= b.finished_at and b.started_at <= a.finished_at),
          do: {a.index, b.index}

    %{
      n: length(runs),
      distinct_backends: runs |> Enum.map(& &1.backend_pid) |> Enum.uniq() |> length(),
      total_pairs: length(pairs),
      overlapping_pairs: length(pairs) - length(non_overlapping),
      non_overlapping: non_overlapping,
      span_us:
        Enum.max_by(runs, & &1.finished_at).finished_at -
          Enum.min_by(runs, & &1.started_at).started_at
    }
  end

  @doc """
  Assert both non-vacuity controls, with the report in the failure message.
  Call this BEFORE asserting anything about the system under test: if the
  writers did not overlap, whatever the test then observes is unrelated to
  concurrency.
  """
  defmacro assert_genuinely_concurrent!(runs) do
    quote bind_quoted: [runs: runs] do
      report = Barkpark.ConcurrencyCase.overlap_report(runs)

      assert report.distinct_backends == report.n,
             """
             the "concurrent" writers did not use separate database connections.

             #{inspect(report, pretty: true)}

             distinct_backends < n means they were serialised onto a shared
             connection — the Ecto sandbox failure mode Barkpark.ConcurrencyCase
             exists to escape. Every assertion below this line would be vacuous.
             """

      assert report.overlapping_pairs == report.total_pairs,
             """
             some writer pairs did not overlap in wall-clock time.

             #{inspect(report, pretty: true)}

             Non-overlapping pairs ran strictly one after the other, so they
             never raced. Every assertion below this line would be vacuous.
             """

      report
    end
  end
end
