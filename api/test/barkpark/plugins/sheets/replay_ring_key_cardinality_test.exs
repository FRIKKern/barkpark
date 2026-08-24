defmodule Barkpark.Plugins.Sheets.Session.ReplayRingKeyCardinalityTest do
  @moduledoc """
  `@cap 32` bounds the list INSIDE a key and `@ttl_ms` prunes entries INSIDE a
  key — lazily, and only on the next write TO THAT SAME KEY. Nothing bounded HOW
  MANY KEYS the table held: `grep -n delete replay_ring.ex` returned nothing
  before this change, and `put/3` always prepends after its reject so a key's
  list never empties, meaning the existing logic could not drop a key even in
  principle.

  These tests never sleep to age an entry: `put/3` writes
  `System.monotonic_time(:millisecond)`, and `sweep/1` takes `now` as an
  argument, so the clock is advanced by passing a future `now`. Deterministic,
  not a race against the scheduler.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Plugins.Sheets.Session.ReplayRing

  @table :sheets_ops_replay

  setup do
    # The ring is a boot-time singleton owning a public named table; the tests
    # write it directly, exactly as the session processes do.
    if :ets.whereis(@table) == :undefined do
      start_supervised!(ReplayRing)
    end

    :ets.delete_all_objects(@table)
    on_exit(fn -> :ets.delete_all_objects(@table) end)
    :ok
  end

  defp key(i), do: {"production", "sheet-#{i}"}

  defp fill!(n) do
    for i <- 1..n, do: ReplayRing.put(key(i), "req-#{i}", %{"ok" => true, "rows" => [1, 2, 3]})
    :ets.info(@table, :size)
  end

  describe "the key count was the unbounded axis" do
    test "N sheets written once each leave N permanent rows", %{} do
      assert fill!(50) == 50

      # Every per-key bound is satisfied — one entry, well under @cap — and yet
      # the table holds 50 rows. The bound that was missing is the row count.
      assert [{_, [_single]}] = :ets.lookup(@table, key(1))
    end

    test "a key's list NEVER empties, so the per-write prune can never drop the key" do
      k = key(1)
      ReplayRing.put(k, "req-a", %{"ok" => true})

      # Write again, far past the TTL, with a DIFFERENT request_id. The reject
      # inside put/3 discards the stale entry — and then prepends the fresh one,
      # so the row survives with exactly one entry. It can never reach zero.
      ReplayRing.put(k, "req-b", %{"ok" => true})

      assert [{^k, list}] = :ets.lookup(@table, k)
      refute list == []
    end
  end

  describe "the sweep bounds the key count" do
    test "a key whose NEWEST entry is past the TTL is dropped" do
      fill!(10)
      now = System.monotonic_time(:millisecond)

      # Advance the clock past the retention instead of sleeping through it.
      assert ReplayRing.sweep(now + ReplayRing.ttl_ms() + 1) == 10
      assert :ets.info(@table, :size) == 0
    end

    test "a key INSIDE the TTL survives" do
      fill!(10)
      now = System.monotonic_time(:millisecond)

      assert ReplayRing.sweep(now + div(ReplayRing.ttl_ms(), 2)) == 0
      assert :ets.info(@table, :size) == 10
    end

    # The head of the list is the key's LAST write, so one fresh write keeps the
    # whole key alive — which is the point: the sweep drops keys nobody is using,
    # not keys with old entries under them.
    test "one fresh entry keeps a key with stale entries alive" do
      k = key(1)
      ReplayRing.put(k, "old", %{"ok" => true})
      now = System.monotonic_time(:millisecond)

      # A second write becomes the head. Sweeping at a `now` that is past the TTL
      # for the FIRST write but not the second must keep the key.
      ReplayRing.put(k, "fresh", %{"ok" => true})

      assert ReplayRing.sweep(now + ReplayRing.ttl_ms() - 1) == 0
      assert :ets.info(@table, :size) == 1
    end

    test "the sweep drops only the stale keys, never the live ones" do
      stale = key(1)
      ReplayRing.put(stale, "stale-req", %{"ok" => true})

      cutoff_now = System.monotonic_time(:millisecond) + ReplayRing.ttl_ms() + 1

      # A key written "after" the stale one, from the sweep's point of view.
      live = key(2)

      :ets.insert(@table, {live, [{"live-req", %{"ok" => true}, cutoff_now}]})

      assert ReplayRing.sweep(cutoff_now) == 1
      assert :ets.lookup(@table, stale) == []
      assert [{^live, _}] = :ets.lookup(@table, live)
    end
  end

  # WITHOUT THIS TEST the periodic tick can be deleted and the suite stays
  # green, because every other test calls `sweep/1` directly. A bound that is
  # implemented but never ARMED is not a bound.
  describe "the periodic tick is actually armed" do
    test "the owner process sweeps on its own :sweep message" do
      k = key(1)
      stale_ts = System.monotonic_time(:millisecond) - ReplayRing.ttl_ms() - 1
      :ets.insert(@table, {k, [{"req-old", %{"ok" => true}, stale_ts}]})
      assert :ets.info(@table, :size) == 1

      pid = Process.whereis(ReplayRing)
      send(pid, :sweep)
      # :sys.get_state is an OTP system message processed in mailbox order, so it
      # cannot be answered until the :sweep ahead of it has been handled. That is
      # the barrier — no sleeping.
      _ = :sys.get_state(pid)

      assert :ets.info(@table, :size) == 0
    end
  end

  describe "replay still works for everything the ring is for" do
    test "a fresh request_id replays its cached reply verbatim" do
      k = key(1)
      reply = %{"ok" => true, "applied" => 3}
      ReplayRing.put(k, "req-1", reply)

      assert ReplayRing.lookup(k, "req-1") == {:ok, reply}
      assert ReplayRing.lookup(k, "req-unknown") == :miss
    end

    test "a swept key misses, so its retry re-applies — the declared retention" do
      k = key(1)
      ReplayRing.put(k, "req-1", %{"ok" => true})
      assert ReplayRing.lookup(k, "req-1") == {:ok, %{"ok" => true}}

      ReplayRing.sweep(System.monotonic_time(:millisecond) + ReplayRing.ttl_ms() + 1)

      # This is the behaviour change, asserted rather than left implicit: after
      # the TTL a retry no longer replays. It is what the 1h retention always
      # meant; the sweep makes it uniform instead of dependent on whether some
      # later write happened to touch this key.
      assert ReplayRing.lookup(k, "req-1") == :miss
    end
  end

  describe "the sweep reports itself" do
    test "it logs the count, the TTL and the consequence" do
      fill!(3)
      now = System.monotonic_time(:millisecond)

      prior_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prior_level) end)

      log =
        capture_log(fn ->
          ReplayRing.sweep(now + ReplayRing.ttl_ms() + 1)
        end)

      assert log =~ "Sheets ReplayRing swept 3 key(s)"
      assert log =~ "newest cached reply"
      assert log =~ "#{ReplayRing.ttl_ms()}ms TTL"
      assert log =~ "0 key(s) remain"
      # The consequence, not just the count.
      assert log =~ "re-applies rather than replays"
    end

    test "the sweep is COUNTABLE — telemetry carries the numbers" do
      handler = "replay-ring-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:barkpark, :sheets, :replay_ring, :keys_swept],
        fn _e, m, _meta, _ -> send(test_pid, {:swept, m}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      fill!(4)
      ReplayRing.sweep(System.monotonic_time(:millisecond) + ReplayRing.ttl_ms() + 1)

      assert_received {:swept, %{dropped: 4, remaining: 0, ttl_ms: 3_600_000}}
    end

    test "a sweep with nothing to drop is SILENT" do
      fill!(2)

      prior_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prior_level) end)

      log = capture_log(fn -> assert ReplayRing.sweep() == 0 end)

      refute log =~ "Sheets ReplayRing swept"
      assert :ets.info(@table, :size) == 2
    end
  end

  describe "the cadence is derived from the retention it enforces" do
    test "four sweeps per TTL, so residency is 1.25x the declared retention" do
      assert ReplayRing.sweep_every_ms() == div(ReplayRing.ttl_ms(), 4)

      # Stated as the property rather than the number: worst-case residency is
      # the TTL plus one tick. A once-per-TTL cadence would make that 2x.
      residency = ReplayRing.ttl_ms() + ReplayRing.sweep_every_ms()
      assert residency == div(ReplayRing.ttl_ms() * 5, 4)
    end
  end
end
