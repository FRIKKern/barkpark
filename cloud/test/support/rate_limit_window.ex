defmodule BarkparkCloud.RateLimitWindow do
  @moduledoc """
  ONE seam that makes every real-clock rate-limit loop deterministic against the
  CALENDAR minute.

  ## The defect this closes

  `BarkparkCloud.DeviceAuth.RateLimiter` and `Accounts.TwoFactorRateLimiter` are
  FIXED-window limiters: `window = div(now_ms, 60_000)`, so the window boundary
  is the wall-clock minute, not "60s after the first hit". A test that drives N
  hits through `Router.call/2` and then asserts the (N+1)th is braked is
  therefore WALL-CLOCK DEPENDENT: if the minute rolls between hit N and hit
  N+1, the last hit lands in a fresh window with count 1 and answers 2xx/4xx
  instead of 429. The router path takes the real clock (`check/1` defaults
  `now_ms` to `System.system_time/1`), so those tests cannot inject one.

  That is not hypothetical. cloud.yml run 35396590781 on main tip 04c5b204b
  reported "5508 tests, 1 failure" —
  `router_app_token_per_user_rate_limit_test.exs:68`, assertion "the flooding
  user must still be braked at the 11th call", stamped 21:30:00.015Z. Ten hits
  at 21:29:5x, the eleventh at 21:30:00.0.

  ## The seam

  `align!/0` is called ONCE at the top of any such test, before the first hit.
  It guarantees the whole test body lands inside a single limiter window: if
  fewer than `headroom_ms/0` remain of the current minute, it sleeps just past
  the boundary so the test starts at the top of a fresh window with a full
  60 seconds ahead of it.

  ## Why the sleep is BOUNDED, and where the threshold comes from

  The sleep only ever happens when the remainder is already below the headroom,
  so it is bounded by `headroom_ms/0` (+5ms of overshoot) — never by the window.
  It is skipped entirely for `(60_000 - headroom) / 60_000` of all runs.

  The headroom is MEASURED, not guessed. `mix test --trace` over the whole
  affected set on 2026-09-19 timed every test carrying a rate-limit loop; the
  slowest was

      * test DELETE app-token (revoke): a second user behind the SAME IP is not
        starved by the first user's flood (195.8ms) [L#68]

  (`router_app_token_per_user_rate_limit_test.exs`, the file that actually
  fired; every other looping test came in under 36ms). 2_000ms is
  ~10x that worst case, which leaves room for a loaded CI runner while capping
  the worst-case pause at ~2s and firing on only 1 run in 30.
  """

  # The limiter window, mirrored from DeviceAuth.RateLimiter/@window_ms and
  # Accounts.TwoFactorRateLimiter/@window_ms (both 60_000). Mirrored rather than
  # read because both are module attributes with no public accessor; the pair is
  # pinned by `rate_limit_window_test.exs`.
  @window_ms 60_000

  # 10x the measured 195.8ms worst-case loop — see the moduledoc.
  @headroom_ms 2_000

  @doc "The limiter window in ms (60_000)."
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  @doc "The minimum window remainder a rate-limit loop is allowed to start with."
  @spec headroom_ms() :: pos_integer()
  def headroom_ms, do: @headroom_ms

  @doc "Milliseconds left in the CURRENT limiter window, right now."
  @spec remaining_ms() :: pos_integer()
  def remaining_ms, do: remaining_ms(System.system_time(:millisecond))

  @doc "Milliseconds left in the limiter window containing `now_ms` (pure; testable)."
  @spec remaining_ms(integer()) :: pos_integer()
  def remaining_ms(now_ms) when is_integer(now_ms), do: @window_ms - rem(now_ms, @window_ms)

  @doc """
  Guarantee the caller starts a rate-limit loop with at least `headroom_ms/0`
  left of the current limiter window, sleeping past the boundary if it does not.

  Returns the milliseconds slept (0 when no sleep was needed), so a caller — or
  the seam's own test — can assert on it.
  """
  @spec align!(pos_integer()) :: non_neg_integer()
  def align!(headroom \\ @headroom_ms) when is_integer(headroom) and headroom > 0 do
    remaining = remaining_ms()

    if remaining < headroom do
      # +5ms so we land INSIDE the next window, never exactly on the boundary.
      slept = remaining + 5
      Process.sleep(slept)
      slept
    else
      0
    end
  end
end
