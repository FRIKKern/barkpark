defmodule BarkparkWeb.GraphCorpusSlotTtlTest do
  @moduledoc """
  The `/v1/graph` admission cap must not free a slot from a STILL-RUNNING
  derivation (acpc-w3-graph-ttl-reap-dead-only).

  THE DEFECT, as it stood on origin/main, in `sweep_graph_corpus_slots/0`:

      for {ref, pid, deadline} <- :ets.tab2list(@graph_corpus_slots),
          deadline <= now or not Process.alive?(pid) do

  The `or` is the whole defect: liveness is a FACT about the holder, while the
  deadline is a wall-time GUESS about whether the derivation has finished. Every
  acquire sweeps first, so an ARRIVING request reaped the rows of live holders
  whose derivation had outlived @graph_corpus_slot_ttl_ms (60s) and was then
  admitted over the cap — fail-OPEN in exactly the saturation regime the cap
  exists for, and self-amplifying, because each extra admission lengthens every
  derivation and so crosses the TTL more often. The 2026-07-28 storm this cap
  was built after logged "Sent 500 in 32003ms" on UNRELATED requests once
  `graph_corpus/2` had exhausted the pool.

  THE FIX: reap on `not Process.alive?(pid)` ALONE.

  WHAT THIS SUITE PROVES, in one run and in both directions:

    * the REAL code refuses (`:busy`) when two LIVE owners hold past-deadline
      rows — the headline assertion, which FAILS on the unfixed body;
    * a LEGACY TWIN carrying the ORIGINAL predicate over its OWN table
      OVER-ADMITS on that same state, so the harness is demonstrably able to see
      the race rather than merely able to agree with the fix;
    * the twin still refuses when the deadlines are in the future, which pins
      the over-admission on the deadline arm alone and not on a broken twin;
    * the alive? arm is still load-bearing: a DEAD owner's row is still reaped;
    * a not-yet-expired live holder is refused (the ordinary cap, unchanged).

  Deterministic by construction: rows are seeded directly into the slot table
  (`[:named_table, :public, :set]`, rows `{ref, owner_pid, deadline_ms}`), so
  there is no DB, no sleep, no barrier and no clock injection — and therefore no
  new public surface on the fenced controller.
  """
  use ExUnit.Case, async: false

  alias BarkparkWeb.TasksController

  @table :barkpark_graph_corpus_slots
  @twin_table :barkpark_graph_corpus_slot_legacy_twin
  @cap 2

  setup do
    previous = Application.fetch_env(:barkpark, :graph_corpus_max_concurrency)
    Application.put_env(:barkpark, :graph_corpus_max_concurrency, @cap)

    # This module is `async: false`, so it never runs alongside the other slot
    # tests; clearing gives every assertion a known table size.
    :ets.delete_all_objects(@table)

    owners = start_owner_registry()

    on_exit(fn ->
      stop_owners(owners)
      :ets.delete_all_objects(@table)

      case previous do
        {:ok, v} -> Application.put_env(:barkpark, :graph_corpus_max_concurrency, v)
        :error -> Application.delete_env(:barkpark, :graph_corpus_max_concurrency)
      end
    end)

    {:ok, owners: owners}
  end

  describe "sweep_graph_corpus_slots/0 reaps DEAD owners only" do
    test "a past-deadline row whose owner is STILL ALIVE keeps its slot (the cap holds)", %{
      owners: owners
    } do
      seed_slots(@cap, owners, deadline_offset_ms: -1)

      assert TasksController.__acquire_graph_corpus_slot_for_test__() == :busy,
             "the sweep freed a slot from a live, still-deriving owner: the cap fails OPEN"

      assert :ets.info(@table, :size) == @cap,
             "the live holders' rows were reaped"
    end

    test "the LEGACY predicate over its own table OVER-ADMITS on that same state", %{
      owners: owners
    } do
      twin = new_twin_table()
      seed_twin_slots(twin, @cap, owners, deadline_offset_ms: -1)

      acquired = legacy_acquire(twin)

      assert match?({:ok, _}, acquired),
             "the twin did not reproduce the defect, so this suite could not have seen it (#{inspect(acquired)})"

      assert :ets.info(twin, :size) == 1,
             "the legacy sweep should have deleted both live holders' rows"
    end

    test "the twin REFUSES when the deadlines have not passed (the over-admission is the deadline arm, not a broken twin)",
         %{owners: owners} do
      twin = new_twin_table()
      seed_twin_slots(twin, @cap, owners, deadline_offset_ms: 60_000)

      assert legacy_acquire(twin) == :busy
      assert :ets.info(twin, :size) == @cap
    end

    test "a DEAD owner's row is still reaped (the alive? arm stays load-bearing)" do
      dead = Enum.map(1..@cap, fn _ -> dead_pid() end)
      seed_slots(@cap, dead, deadline_offset_ms: 60_000)

      acquired = TasksController.__acquire_graph_corpus_slot_for_test__()

      assert match?({:ok, _}, acquired),
             "a dead owner's slot leaked: the cap now fails CLOSED forever (#{inspect(acquired)})"

      {:ok, ref} = acquired

      assert :ets.info(@table, :size) == 1
      TasksController.__release_graph_corpus_slot_for_test__(ref)
    end

    test "a live holder whose deadline has NOT passed is refused (the ordinary cap, unchanged)",
         %{owners: owners} do
      seed_slots(@cap, owners, deadline_offset_ms: 60_000)

      assert TasksController.__acquire_graph_corpus_slot_for_test__() == :busy
      assert :ets.info(@table, :size) == @cap
    end
  end

  # ── the legacy twin: the ORIGINAL body, verbatim, over its own table ───────

  defp legacy_acquire(table) do
    now = System.monotonic_time(:millisecond)

    for {ref, pid, deadline} <- :ets.tab2list(table),
        deadline <= now or not Process.alive?(pid) do
      :ets.delete(table, ref)
    end

    ref = make_ref()
    :ets.insert(table, {ref, self(), now + 60_000})

    if :ets.info(table, :size) > @cap do
      :ets.delete(table, ref)
      :busy
    else
      {:ok, ref}
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp new_twin_table do
    name = :"#{@twin_table}_#{System.unique_integer([:positive])}"
    :ets.new(name, [:named_table, :public, :set])
    on_exit(fn -> if :ets.whereis(name) != :undefined, do: :ets.delete(name) end)
    name
  end

  defp seed_slots(count, owners, deadline_offset_ms: offset) do
    seed_into(@table, count, owners, offset)
  end

  defp seed_twin_slots(table, count, owners, deadline_offset_ms: offset) do
    seed_into(table, count, owners, offset)
  end

  defp seed_into(table, count, owners, offset) do
    now = System.monotonic_time(:millisecond)

    owners
    |> Enum.take(count)
    |> Enum.each(fn pid -> :ets.insert(table, {make_ref(), pid, now + offset}) end)
  end

  # Parked processes that stay ALIVE for the whole test: they stand in for
  # request processes still deriving a corpus.
  defp start_owner_registry do
    Enum.map(1..@cap, fn _ ->
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)
    end)
  end

  defp stop_owners(owners), do: Enum.each(owners, &send(&1, :stop))

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> pid
    after
      1_000 -> flunk("owner process did not exit")
    end
  end
end
