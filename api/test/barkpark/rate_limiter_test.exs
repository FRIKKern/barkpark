defmodule Barkpark.RateLimiterTest do
  use ExUnit.Case, async: false

  import Barkpark.RateLimiterSandbox

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state no sandbox owns
  # and nothing used to reset, so a bucket one test spent stayed spent for the
  # rest of the run. Start from an unspent table.
  setup :reset_rate_limiter!
  alias Barkpark.RateLimiter

  setup do
    :ets.delete_all_objects(:barkpark_rate_limiter)
    :ok
  end

  test "first request for a new key is allowed and creates a bucket" do
    assert RateLimiter.check({:token, "new-key"}, capacity: 5, refill_per_sec: 1.0) == :ok
  end

  test "capacity requests are allowed in a burst, N+1 is rate-limited" do
    key = {:token, "burst-test"}

    for _ <- 1..5 do
      assert RateLimiter.check(key, capacity: 5, refill_per_sec: 1.0) == :ok
    end

    assert RateLimiter.check(key, capacity: 5, refill_per_sec: 1.0) == :rate_limited
  end

  test "different keys have independent buckets" do
    assert RateLimiter.check({:token, "a"}, capacity: 1, refill_per_sec: 0.0) == :ok
    assert RateLimiter.check({:token, "a"}, capacity: 1, refill_per_sec: 0.0) == :rate_limited
    assert RateLimiter.check({:token, "b"}, capacity: 1, refill_per_sec: 0.0) == :ok
  end

  test "bucket refills over time" do
    key = {:token, "refill-test"}
    assert RateLimiter.check(key, capacity: 2, refill_per_sec: 100.0) == :ok
    assert RateLimiter.check(key, capacity: 2, refill_per_sec: 100.0) == :ok
    assert RateLimiter.check(key, capacity: 2, refill_per_sec: 100.0) == :rate_limited

    :timer.sleep(30)

    assert RateLimiter.check(key, capacity: 2, refill_per_sec: 100.0) == :ok
  end

  test "method-class scoped string keys are independent" do
    read_key = "token:abc:read:production"
    write_key = "token:abc:write:production"

    assert RateLimiter.check(read_key, capacity: 1, refill_per_sec: 0.0) == :ok
    assert RateLimiter.check(read_key, capacity: 1, refill_per_sec: 0.0) == :rate_limited
    assert RateLimiter.check(write_key, capacity: 1, refill_per_sec: 0.0) == :ok
  end

  test "dataset-scoped string keys are independent" do
    prod = "token:abc:read:production"
    staging = "token:abc:read:staging"

    assert RateLimiter.check(prod, capacity: 1, refill_per_sec: 0.0) == :ok
    assert RateLimiter.check(prod, capacity: 1, refill_per_sec: 0.0) == :rate_limited
    assert RateLimiter.check(staging, capacity: 1, refill_per_sec: 0.0) == :ok
  end

  test "IP-fallback keys are independent from token keys" do
    token_key = "token:abc:read:global"
    ip_key = "ip:127.0.0.1:read:global"

    assert RateLimiter.check(token_key, capacity: 1, refill_per_sec: 0.0) == :ok
    assert RateLimiter.check(token_key, capacity: 1, refill_per_sec: 0.0) == :rate_limited
    assert RateLimiter.check(ip_key, capacity: 1, refill_per_sec: 0.0) == :ok
  end

  test "prunes fully-refilled (stale) buckets once the table exceeds the bound" do
    now = System.monotonic_time(:millisecond)
    # Tracks @stale_after_ms (1h): a 10-minute-old bucket is no longer stale.
    stale = now - 4_000_000
    fresh = now

    # Fill past @max_entries (10_000) with stale buckets + one fresh bucket.
    for i <- 1..10_001 do
      :ets.insert(:barkpark_rate_limiter, {{:token, "stale-#{i}"}, 5.0, stale})
    end

    :ets.insert(:barkpark_rate_limiter, {{:token, "keep-me"}, 5.0, fresh})
    assert :ets.info(:barkpark_rate_limiter, :size) > 10_000

    # A request for a NEW key hits the insert path → triggers the prune.
    assert RateLimiter.check({:token, "trigger"}, capacity: 5, refill_per_sec: 1.0) == :ok

    # Stale buckets gone; the fresh one and the new key survive; table bounded.
    assert :ets.lookup(:barkpark_rate_limiter, {:token, "stale-1"}) == []
    assert :ets.lookup(:barkpark_rate_limiter, {:token, "stale-10001"}) == []
    assert [{_, _, ^fresh}] = :ets.lookup(:barkpark_rate_limiter, {:token, "keep-me"})
    assert [{_, _, _}] = :ets.lookup(:barkpark_rate_limiter, {:token, "trigger"})
    assert :ets.info(:barkpark_rate_limiter, :size) < 10_000
  end

  test "does not prune while under the bound (a stale bucket survives)" do
    now = System.monotonic_time(:millisecond)
    # Tracks @stale_after_ms (1h): a 10-minute-old bucket is no longer stale.
    :ets.insert(:barkpark_rate_limiter, {{:token, "old-but-few"}, 5.0, now - 4_000_000})

    # Under @max_entries → no prune, even though the entry is stale (the prune is
    # gated on table size so the hot path stays cheap).
    assert RateLimiter.check({:token, "fresh"}, capacity: 5, refill_per_sec: 1.0) == :ok
    assert [{_, _, _}] = :ets.lookup(:barkpark_rate_limiter, {:token, "old-but-few"})
  end

  # ── @max_entries is a CEILING, not just a prune trigger ────────────────────
  #
  # The stale sweep's only predicate is "idle >= @stale_after_ms". Under a flood
  # of FRESH keys nothing matches it, so before this guard existed the sweep ran,
  # freed zero, and the table grew without any upper bound. These tests drive
  # exactly that condition: every planted row is stamped `now`, so no row is ever
  # sweep-eligible.
  describe "table ceiling under a fresh-key flood" do
    @max_entries 10_000

    defp flood_fresh_keys!(n) do
      now = System.monotonic_time(:millisecond)

      rows =
        for i <- 1..n do
          # Spread the stamps over a 1-second band, all of them FAR younger than
          # @stale_after_ms (1h), so the sweep can never match one — while still
          # giving the least-recently-used eviction a real ordering to work with.
          {{:token, "flood-#{i}"}, 5.0, now - rem(i, 1000)}
        end

      :ets.insert(:barkpark_rate_limiter, rows)
      :ets.info(:barkpark_rate_limiter, :size)
    end

    # CRITERION 1 — the growth is real, and it is the SWEEP that fails, not the
    # trigger. Proven by running the sweep's own match spec against the flooded
    # table and showing it selects nothing.
    test "the stale sweep frees ZERO rows when every key is fresh" do
      planted = flood_fresh_keys!(@max_entries + 500)
      assert planted == @max_entries + 500

      now = System.monotonic_time(:millisecond)
      cutoff = now - 3_600_000

      # The exact match spec maybe_prune/1 runs, used here as a COUNT rather than
      # a delete: how many rows would the stale sweep have been able to free?
      sweepable =
        :ets.select_count(
          :barkpark_rate_limiter,
          [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}]
        )

      assert sweepable == 0,
             "every planted row is fresh, so the stale sweep has nothing to free — " <>
               "which is precisely why @max_entries needed a ceiling and not just a trigger"
    end

    # CRITERION 2 — the ceiling actually holds. One cold-key insert past the
    # bound is enough to bring the table back under it.
    test "one cold-key insert brings a flooded table back under @max_entries" do
      planted = flood_fresh_keys!(@max_entries + 500)
      assert planted > @max_entries

      assert RateLimiter.check({:token, "ceiling-trigger"}, capacity: 5, refill_per_sec: 1.0) ==
               :ok

      size = :ets.info(:barkpark_rate_limiter, :size)

      assert size <= @max_entries,
             "expected the table back under #{@max_entries}, got #{size}"

      # And it lands under the headroom target, so the O(n log n) trim is
      # amortised rather than re-run on the very next insert.
      assert size <= @max_entries - div(@max_entries, 10) + 1
    end

    # The eviction is LEAST-RECENTLY-USED, not arbitrary: the most recently
    # touched bucket survives a trim. A bucket that survives keeps its debits, so
    # this is also what stops the trim from being a global rate-limit reset.
    test "the most recently used bucket survives the trim" do
      flood_fresh_keys!(@max_entries + 500)
      now = System.monotonic_time(:millisecond)
      :ets.insert(:barkpark_rate_limiter, {{:token, "hottest"}, 1.0, now + 5_000})

      RateLimiter.check({:token, "ceiling-trigger-lru"}, capacity: 5, refill_per_sec: 1.0)

      assert [{_, _, _}] = :ets.lookup(:barkpark_rate_limiter, {:token, "hottest"})
    end

    # CRITERION 3 — evicting a bucket that is NOT stale resets it to full, so the
    # limiter admits requests it should have denied. That can never be silent.
    test "the ceiling eviction WARNS, naming what it freed and the consequence" do
      flood_fresh_keys!(@max_entries + 500)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          RateLimiter.check({:token, "ceiling-trigger-log"}, capacity: 5, refill_per_sec: 1.0)
        end)

      assert log =~ "RateLimiter CEILING EVICTION"
      assert log =~ "the stale sweep left"
      assert log =~ "least-recently-used bucket(s) were evicted"
      # The consequence, not just the counts.
      assert log =~ "reset to full"
      assert log =~ "an allowance they did not earn"
      assert log =~ "do not raise @max_entries"
    end

    test "the ceiling eviction is COUNTABLE — telemetry carries the numbers" do
      handler = "rl-ceiling-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:barkpark, :rate_limiter, :ceiling_evicted],
        fn _e, measurements, _meta, _ -> send(test_pid, {:ceiling, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      flood_fresh_keys!(@max_entries + 500)
      RateLimiter.check({:token, "ceiling-trigger-tel"}, capacity: 5, refill_per_sec: 1.0)

      assert_received {:ceiling, m}
      assert m.limit == @max_entries
      assert m.size_before > @max_entries
      assert m.remaining <= @max_entries
      assert m.evicted > 0
    end

    # The ceiling must not cry wolf. A table under the bound is untouched and
    # silent — including a table holding stale rows, which the existing
    # size-gated prune deliberately leaves alone.
    test "a table under the bound is silent and loses nothing" do
      flood_fresh_keys!(100)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert RateLimiter.check({:token, "under-bound"}, capacity: 5, refill_per_sec: 1.0) ==
                   :ok
        end)

      refute log =~ "CEILING EVICTION"
      assert :ets.info(:barkpark_rate_limiter, :size) == 101
    end

    # NO LIMITER REGRESSION: a bucket that survives the trim is still debited and
    # still 429s at exhaustion — the ceiling did not turn the limiter off.
    test "a surviving bucket is still debited and still rate-limits" do
      flood_fresh_keys!(@max_entries + 500)
      key = {:token, "still-limited"}
      now = System.monotonic_time(:millisecond)
      # Newest row in the table, so it survives the least-recently-used trim.
      :ets.insert(:barkpark_rate_limiter, {key, 1.0, now + 10_000})

      RateLimiter.check({:token, "ceiling-trigger-debit"}, capacity: 5, refill_per_sec: 1.0)

      assert RateLimiter.check(key, capacity: 1, refill_per_sec: 0.0) == :ok
      assert RateLimiter.check(key, capacity: 1, refill_per_sec: 0.0) == :rate_limited
    end
  end
end
