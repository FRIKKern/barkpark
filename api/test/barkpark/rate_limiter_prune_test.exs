defmodule Barkpark.RateLimiterPruneTest do
  @moduledoc """
  The guard `rate_limiter_test.exs` structurally cannot be.

  That file seeds every stale bucket at `5.0` tokens — already AT capacity. For a
  FULL bucket, delete-and-recreate really is behaviour-identical, exactly as the
  prune's old comment claimed, so the suite exercised the one case where the
  prune is correct and the reset was invisible. The buckets that matter are the
  DEPLETED ones, and every assertion below is a SURVIVAL assertion: it says a
  still-spent bucket is STILL THERE and STILL SPENT after a prune. None of them
  asserts the defect, so none of them would red against a future fix.
  """
  use ExUnit.Case, async: false

  import Barkpark.RateLimiterSandbox

  setup :reset_rate_limiter!

  alias Barkpark.RateLimiter

  # Both hourly call sites (Plugs.AuthWriteRateLimit, Plugs.TicketRateLimit)
  # spell an hourly budget of N as capacity: N, refill_per_sec: N / 3600.
  # 5/hour is the shipped POST /v1/auth/register budget.
  @hourly_capacity 5
  @hourly_refill 5 / 3600

  # bulldocs_form_controller: capacity 20, refill 1/60 — 1200s to refill from
  # empty. A third shape: it can never be both stale and fully depleted, but a
  # bucket emptied 400s ago has earned ~6 of 20 and a prune re-grants all 20.
  @form_capacity 20
  @form_refill 1 / 60

  # Past the OLD 300_000 cutoff, inside the current one. A bucket idle this long
  # is what the defect deleted.
  @idle_past_old_cutoff_ms 400_000

  # Past the CURRENT cutoff, so filler is genuinely prunable.
  @idle_past_current_cutoff_ms 4_000_000

  defp fill_past_bound!(last_ms) do
    for i <- 1..10_001 do
      :ets.insert(:barkpark_rate_limiter, {{:token, "filler-#{i}"}, 5.0, last_ms})
    end

    assert :ets.info(:barkpark_rate_limiter, :size) > 10_000
  end

  # The prune runs on the new-key insert path only.
  defp trigger_prune! do
    assert RateLimiter.check({:token, "prune-trigger-#{System.unique_integer([:positive])}"},
             capacity: 5,
             refill_per_sec: 1.0
           ) == :ok
  end

  test "a DEPLETED hourly bucket idle past the old cutoff survives the prune and stays denied" do
    now = System.monotonic_time(:millisecond)
    victim = {:auth_write, "register", "203.0.113.7"}
    seeded_at = now - @idle_past_old_cutoff_ms

    # Spent to zero and idle 400s. On an hourly refill it has legitimately
    # earned 5 * 400/3600 = 0.56 tokens — still under one, so still denied.
    :ets.insert(:barkpark_rate_limiter, {victim, 0.0, seeded_at})

    assert RateLimiter.check(victim, capacity: @hourly_capacity, refill_per_sec: @hourly_refill) ==
             :rate_limited

    fill_past_bound!(now - @idle_past_current_cutoff_ms)
    trigger_prune!()

    # Split, not one match-with-message: `assert pat = expr, "msg"` raises a bare
    # MatchError and throws the message away.
    survivors = :ets.lookup(:barkpark_rate_limiter, victim)

    assert survivors != [],
           "the DEPLETED hourly bucket was pruned as stale — the next request from " <>
             "this IP re-creates it FULL, handing it another whole hourly budget"

    assert [{^victim, _tokens, ^seeded_at}] = survivors

    assert RateLimiter.check(victim, capacity: @hourly_capacity, refill_per_sec: @hourly_refill) ==
             :rate_limited
  end

  test "a partly-refilled bulldocs_form-shaped bucket survives and yields only what it earned" do
    now = System.monotonic_time(:millisecond)
    victim = {:bulldocs_form, "198.51.100.4"}
    seeded_at = now - @idle_past_old_cutoff_ms

    :ets.insert(:barkpark_rate_limiter, {victim, 0.0, seeded_at})

    fill_past_bound!(now - @idle_past_current_cutoff_ms)
    trigger_prune!()

    survivors = :ets.lookup(:barkpark_rate_limiter, victim)

    assert survivors != [],
           "the partly-refilled bulldocs_form bucket was pruned as stale — the next " <>
             "request re-creates it at the full 20-token capacity"

    assert [{^victim, _tokens, ^seeded_at}] = survivors

    # 400s at 1/60 per sec = 6.67 earned tokens, not the full 20.
    for n <- 1..6 do
      assert RateLimiter.check(victim, capacity: @form_capacity, refill_per_sec: @form_refill) ==
               :ok,
             "admit #{n} of the 6 tokens this bucket legitimately earned was refused"
    end

    assert RateLimiter.check(victim, capacity: @form_capacity, refill_per_sec: @form_refill) ==
             :rate_limited,
           "a 7th admit means the bucket was re-granted its full 20-token capacity"
  end

  test "the :rate_limited branch performs no ETS write, so a denied client keeps ageing" do
    now = System.monotonic_time(:millisecond)
    key = {:auth_write, "register", "203.0.113.9"}
    :ets.insert(:barkpark_rate_limiter, {key, 0.0, now})

    [{^key, _, before_ms}] = :ets.lookup(:barkpark_rate_limiter, key)

    assert RateLimiter.check(key, capacity: 1, refill_per_sec: 0.0) == :rate_limited
    assert RateLimiter.check(key, capacity: 1, refill_per_sec: 0.0) == :rate_limited

    [{^key, _, after_ms}] = :ets.lookup(:barkpark_rate_limiter, key)

    assert after_ms == before_ms,
           "a denial refreshed last_ms — the compounding half of the prune-reset is gone, " <>
             "and the @stale_after_ms census comment must be corrected"
  end

  test "the prune's PURPOSE is preserved: a genuinely stale 60s-window bucket is still dropped" do
    now = System.monotonic_time(:millisecond)
    stale = {:token, "stale-60s-window"}

    # Plugs.RateLimit shape: capacity N, refill N/60 — fully refilled after 60s,
    # so at 4_000_000ms idle this bucket is a true no-op to delete.
    :ets.insert(:barkpark_rate_limiter, {stale, 60.0, now - @idle_past_current_cutoff_ms})

    fill_past_bound!(now - @idle_past_current_cutoff_ms)
    trigger_prune!()

    assert :ets.lookup(:barkpark_rate_limiter, stale) == [],
           "the prune stopped collecting genuinely stale buckets — the table is unbounded again"

    assert :ets.info(:barkpark_rate_limiter, :size) < 10_000
  end
end
