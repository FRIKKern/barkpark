defmodule BarkparkCloud.Accounts.TwoFactorRateLimiterTest do
  @moduledoc """
  The 5/60s fixed-window limiter behind the 2FA login challenge. `check/2` takes
  an injected `now_ms` so the window-rollover behaviour is DETERMINISTIC (no
  wall-clock sleeps): each 60_000 ms bucket is an independent window.
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.Accounts.TwoFactorRateLimiter, as: RL

  setup do
    RL.reset()
    :ok
  end

  defp uid, do: "user-#{System.unique_integer([:positive])}"

  test "allows exactly 5 attempts, then rate-limits the 6th in the same window" do
    u = uid()
    now = 100 * 60_000

    for _ <- 1..5, do: assert(RL.check(u, now) == :ok)
    assert RL.check(u, now) == {:error, :rate_limited}
    # still limited later in the same window
    assert RL.check(u, now + 59_000) == {:error, :rate_limited}
  end

  test "the window rolls over: the next 60s window starts with a fresh budget" do
    u = uid()
    w0 = 100 * 60_000
    w1 = 101 * 60_000

    for _ <- 1..5, do: assert(RL.check(u, w0) == :ok)
    assert RL.check(u, w0) == {:error, :rate_limited}

    # A timestamp in the NEXT window is a clean slate — this fails if the sweep
    # or the window key math regresses (e.g. a global rather than per-window
    # counter).
    for _ <- 1..5, do: assert(RL.check(u, w1) == :ok)
    assert RL.check(u, w1) == {:error, :rate_limited}
  end

  test "counters are isolated per user" do
    a = uid()
    b = uid()
    now = 200 * 60_000

    for _ <- 1..6, do: RL.check(a, now)
    assert RL.check(a, now) == {:error, :rate_limited}
    # a different user in the same window is untouched
    assert RL.check(b, now) == :ok
  end

  test "reset/0 clears all counters (test-isolation contract)" do
    u = uid()
    now = 300 * 60_000

    for _ <- 1..6, do: RL.check(u, now)
    assert RL.check(u, now) == {:error, :rate_limited}

    RL.reset()
    assert RL.check(u, now) == :ok
  end
end
