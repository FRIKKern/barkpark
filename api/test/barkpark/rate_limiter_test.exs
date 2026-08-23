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
    stale = now - 600_000
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
    :ets.insert(:barkpark_rate_limiter, {{:token, "old-but-few"}, 5.0, now - 600_000})

    # Under @max_entries → no prune, even though the entry is stale (the prune is
    # gated on table size so the hot path stays cheap).
    assert RateLimiter.check({:token, "fresh"}, capacity: 5, refill_per_sec: 1.0) == :ok
    assert [{_, _, _}] = :ets.lookup(:barkpark_rate_limiter, {:token, "old-but-few"})
  end
end
