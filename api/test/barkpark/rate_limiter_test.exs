defmodule Barkpark.RateLimiterTest do
  use ExUnit.Case, async: false
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
end
