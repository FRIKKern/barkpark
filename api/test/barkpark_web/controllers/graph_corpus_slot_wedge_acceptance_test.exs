defmodule BarkparkWeb.GraphCorpusSlotWedgeAcceptanceTest do
  @moduledoc """
  The residue of `acpc-w3-graph-ttl-reap-dead-only`, closed by ACCEPTING it:
  after dead-only reaping, an alive-but-wedged `/v1/graph` holder keeps its slot
  until it finishes, and after `cap` such holders the route is 503 for as long
  as they live (`acpc-bl-graph-slot-wedged-live-holder`).

  No kill-bound is built. What this suite pins is the two things that decision
  rests on, each in a way that can FAIL:

    * the DB half of a wedge is SELF-LIMITING — the controller's lexical
      `try/after` releases the slot on a raise, which is what an Ecto query
      timeout is, so no sweep and no TTL is involved in reclaiming it;
    * the accepted remedy is OBSERVABILITY — a refused acquire emits
      `[:barkpark, :graph_corpus, :slot, :refused]` carrying the held-slot count
      and the OLDEST holder's age, which is what tells a saturated cap (ages in
      seconds) apart from a wedged one (ages that only grow).

  Both are deterministic: slots are seeded straight into the table
  (`{ref, owner_pid, deadline_ms}`), so there is no DB, no sleep and no clock
  injection. Deleting the `:telemetry.execute` from
  `emit_graph_corpus_refused/0` reds the second test; deleting the `after`
  clause from `graph_corpus/2` is what the first test is a proxy for.
  """
  use ExUnit.Case, async: false

  alias BarkparkWeb.TasksController

  @table :barkpark_graph_corpus_slots
  @event [:barkpark, :graph_corpus, :slot, :refused]
  @ttl_ms 60_000
  @cap 1

  setup do
    previous = Application.fetch_env(:barkpark, :graph_corpus_max_concurrency)
    Application.put_env(:barkpark, :graph_corpus_max_concurrency, @cap)
    :ets.delete_all_objects(@table)

    on_exit(fn ->
      :ets.delete_all_objects(@table)

      case previous do
        {:ok, v} -> Application.put_env(:barkpark, :graph_corpus_max_concurrency, v)
        :error -> Application.delete_env(:barkpark, :graph_corpus_max_concurrency)
      end
    end)

    :ok
  end

  test "`after` releases the slot when the derivation RAISES (the DB half needs no sweep)" do
    assert {:ok, slot} = TasksController.__acquire_graph_corpus_slot_for_test__()
    assert :ets.info(@table, :size) == 1

    # The exact shape `graph_corpus/2` wraps the derivation in. A 15s
    # DBConnection timeout arrives here as a raise.
    assert_raise RuntimeError, "wedged on the database", fn ->
      try do
        raise "wedged on the database"
      after
        TasksController.__release_graph_corpus_slot_for_test__(slot)
      end
    end

    assert :ets.info(@table, :size) == 0,
           "`after` did not run on a raise: a DB-bound wedge would hold its slot forever"
  end

  test "a refused acquire emits the slot count and the OLDEST holder's age" do
    handler = "graph-corpus-slot-refused-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      @event,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # One LIVE holder (this process), acquired 30s ago: deadline is stamped as
    # acquire-time + @ttl_ms, so a 30s-old holder's deadline is now + 30s.
    now = System.monotonic_time(:millisecond)
    :ets.insert(@table, {make_ref(), self(), now - 30_000 + @ttl_ms})

    assert TasksController.__acquire_graph_corpus_slot_for_test__() == :busy

    assert_receive {:telemetry, @event, measurements, metadata}, 1_000

    assert measurements.slots == @cap,
           "the refused acquire reported #{measurements.slots} held slots, not #{@cap}"

    assert measurements.oldest_holder_age_ms >= 30_000,
           "the oldest holder read as #{measurements.oldest_holder_age_ms}ms old, not >= 30000ms: " <>
             "a wedged holder would be indistinguishable from a busy one"

    assert metadata.cap == @cap
  end
end
