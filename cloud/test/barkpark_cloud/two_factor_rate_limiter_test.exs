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

  # task-4ce7aa98a5aaa885: 5/min alone was 7,200 guesses a day.
  describe "the daily bound" do
    @day_ms 86_400_000

    test "30 attempts a UTC day across minute windows, then 429 until the day rolls over" do
      u = "u-daily-#{System.unique_integer([:positive])}"
      day_start = 500 * @day_ms

      # Six full minute windows of 5 = 30 attempts, all admitted.
      for m <- 0..5, _ <- 1..5 do
        assert RL.check(u, day_start + m * 60_000) == :ok
      end

      # The 31st, in a fresh minute window, is refused for the rest of the day.
      at = day_start + 6 * 60_000
      assert {:error, {:rate_limited, retry_after}} = RL.check(u, at)
      assert retry_after == div(@day_ms - 6 * 60_000, 1000)

      # The next UTC day starts with a fresh budget.
      assert RL.check(u, day_start + @day_ms) == :ok
    end

    test "attempts refused by the minute window do not spend the daily budget" do
      u = "u-daily-minute-#{System.unique_integer([:positive])}"
      day_start = 600 * @day_ms

      # 5 admitted + 20 refused in one minute: only 5 reach the daily counter.
      for _ <- 1..25, do: RL.check(u, day_start)

      # 25 more admitted across later minutes brings the day to exactly 30.
      for m <- 1..5, _ <- 1..5 do
        assert RL.check(u, day_start + m * 60_000) == :ok
      end

      assert {:error, {:rate_limited, _}} = RL.check(u, day_start + 6 * 60_000)
    end

    test "an elapsed day's counter is swept by the user's next check" do
      u = "u-daily-sweep-#{System.unique_integer([:positive])}"
      d0 = 700 * @day_ms

      assert RL.check(u, d0) == :ok
      assert RL.check(u, d0 + @day_ms) == :ok

      days =
        :ets.tab2list(RL)
        |> Enum.flat_map(fn
          {{^u, {:day, d}}, _} -> [d]
          _ -> []
        end)

      assert days == [701]
    end
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
