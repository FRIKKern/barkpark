defmodule BarkparkCloud.Accounts.TwoFactorRateLimiterTest do
  @moduledoc """
  The 5/60s fixed-window limiter behind the 2FA login challenge. `check/2` takes
  an injected `now_ms` so the window-rollover behaviour is DETERMINISTIC (no
  wall-clock sleeps): each 60_000 ms bucket is an independent window. The
  injected clock is also what makes the `retry_after` seconds in the
  `{:error, {:rate_limited, n}}` reply assertable to the exact integer.
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
    assert {:error, {:rate_limited, 60}} = RL.check(u, now)
    # still limited later in the same window, and the countdown SHRINKS toward the
    # window boundary rather than repeating a canned constant.
    assert {:error, {:rate_limited, 1}} = RL.check(u, now + 59_000)
  end

  test "the window rolls over: the next 60s window starts with a fresh budget" do
    u = uid()
    w0 = 100 * 60_000
    w1 = 101 * 60_000

    for _ <- 1..5, do: assert(RL.check(u, w0) == :ok)
    assert {:error, {:rate_limited, _}} = RL.check(u, w0)

    # A timestamp in the NEXT window is a clean slate — this fails if the sweep
    # or the window key math regresses (e.g. a global rather than per-window
    # counter).
    for _ <- 1..5, do: assert(RL.check(u, w1) == :ok)
    assert {:error, {:rate_limited, _}} = RL.check(u, w1)
  end

  test "counters are isolated per user" do
    a = uid()
    b = uid()
    now = 200 * 60_000

    for _ <- 1..6, do: RL.check(a, now)
    assert {:error, {:rate_limited, _}} = RL.check(a, now)
    # a different user in the same window is untouched
    assert RL.check(b, now) == :ok
  end

  test "retry_after is the remainder of the fixed window, rounded UP and floored at 1" do
    u = uid()
    w = 400 * 60_000

    for _ <- 1..5, do: RL.check(u, w)

    # Exactly on the boundary: the whole window is still to wait.
    assert {:error, {:rate_limited, 60}} = RL.check(u, w)
    # Mid-window: seconds left, rounded UP (500ms in → 59.5s left → 60).
    assert {:error, {:rate_limited, 60}} = RL.check(u, w + 500)
    assert {:error, {:rate_limited, 30}} = RL.check(u, w + 30_000)
    # The last sliver of the window never reports 0 — a 0 would tell the caller
    # to retry immediately into the same 429.
    assert {:error, {:rate_limited, 1}} = RL.check(u, w + 59_999)
  end

  test "reset/0 clears all counters (test-isolation contract)" do
    u = uid()
    now = 300 * 60_000

    for _ <- 1..6, do: RL.check(u, now)
    assert {:error, {:rate_limited, _}} = RL.check(u, now)

    RL.reset()
    assert RL.check(u, now) == :ok
  end
end
