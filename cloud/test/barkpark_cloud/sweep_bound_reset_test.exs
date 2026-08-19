defmodule BarkparkCloud.SweepBoundResetTest do
  @moduledoc """
  The stale-window sweep in both cloud ETS rate limiters must only ever delete
  windows STRICTLY OLDER than the caller's own.

  Both limiters derive `window` once from a wall clock at the top of `check/2`
  and then run a `:ets.select_delete/2` sweep for that key before the atomic
  `:ets.update_counter/4`. With the original `{:"/=", :"$1", window}` guard the
  sweep deleted every window for the key that was not the caller's own —
  including a NEWER one. A caller carrying a window-W view arriving while W+1
  already sat at its limit therefore erased W+1's exhausted counter, and the
  next W+1 attempt re-seeded at 1 and was ADMITTED. Fail-open on an
  auth-adjacent flood defence.

  These are three sequential calls in ONE process — no twin module, no barrier,
  no fan-out, no sleep — because `check/2` takes `now_ms` as an ordinary
  argument, so the straddle is expressible directly against the SHIPPING code on
  the SHIPPING table. That is strictly stronger than a byte-verbatim twin: it
  proves the original misbehaves, not that a copy does.

  SEVERITY: BOUNDED. One straddle event refunds at most one full `limit` of
  admissions for that key in the newer window (30 on `"register:"`, 5 on 2FA) —
  a re-granted budget, not an erased bound.

  VECTOR. Two ways a caller's window view goes stale, and they are not equally
  exotic:

    * THE BOUNDARY STRADDLE, which needs no clock anomaly at all. Caller A reads
      `now_ms` a few ms before a 60s boundary (window W) and caller B reads it a
      few ms after (W+1). B sweeps and bumps W+1 first; A's sweep then runs with
      the older `/=` guard and deletes B's W+1 row. Under the sustained flood
      these buckets exist to brake, requests are in flight across EVERY window
      boundary, so this interleaving is not a rare coincidence — it is the
      normal case once per minute per hot key.
    * A backwards wall-clock step (OTP 27 defaults to multi_time_warp and no
      vm.args here overrides it), which widens the same hole arbitrarily.

  NOT OBSERVED, though: nobody instrumented a production straddle or stepped a
  host clock. The test drives `now_ms` explicitly rather than racing the real
  clock, so what is proven here is that the code path admits the refund and that
  the `<` guard closes it — not a measured production trigger rate.
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.Accounts.TwoFactorRateLimiter
  alias BarkparkCloud.DeviceAuth.RateLimiter

  # A window boundary far from any real clock, so these rows can never collide
  # with a concurrent test's live-clock rows.
  @window_ms 60_000
  @w 1_000_000
  @in_w @w * @window_ms + 30_000
  @in_w1 (@w + 1) * @window_ms + 30_000

  setup do
    TwoFactorRateLimiter.reset()
    RateLimiter.reset()
    :ok
  end

  describe "two-factor limiter" do
    test "a straddling window-W caller cannot refund window W+1's exhausted budget" do
      user_id = "sweep-bound-reset-2fa-user"

      # W+1 is filled exactly to its 5-attempt limit.
      for _ <- 1..5, do: assert(:ok = TwoFactorRateLimiter.check(user_id, @in_w1))

      # A caller whose `window` view is the OLDER W arrives and runs the sweep.
      assert :ok = TwoFactorRateLimiter.check(user_id, @in_w)

      # W+1 must still be exhausted: the sweep may only drop strictly-older rows.
      assert {:error, {:rate_limited, retry_after}} =
               TwoFactorRateLimiter.check(user_id, @in_w1)

      assert retry_after >= 1
    end
  end

  describe "device-auth limiter" do
    test "a straddling window-W caller cannot refund window W+1's exhausted budget" do
      key = "start:203.0.113.7"

      # "start:" is a 10 / 60s bucket; fill W+1 exactly to it.
      for _ <- 1..10, do: assert(:ok = RateLimiter.check(key, @in_w1))

      assert :ok = RateLimiter.check(key, @in_w)

      assert {:error, :rate_limited} = RateLimiter.check(key, @in_w1)
    end
  end

  describe "growth boundedness under the strictly-older sweep" do
    test "a straddle leaves at most one transient extra row, reclaimed by the next forward call" do
      key = "start:203.0.113.8"

      assert :ok = RateLimiter.check(key, @in_w1)
      assert rows_for(RateLimiter, key) == [@w + 1]

      # The straddle adds W alongside W+1 — a transient SECOND row for this key,
      # because W's sweep is not allowed to touch the newer W+1.
      assert :ok = RateLimiter.check(key, @in_w)
      assert rows_for(RateLimiter, key) == [@w, @w + 1]

      # The next forward call sweeps everything strictly older than its own
      # window, so the pair collapses back to one row: bounded, not accreting.
      assert :ok = RateLimiter.check(key, @in_w1)
      assert rows_for(RateLimiter, key) == [@w + 1]
    end
  end

  # The window indices this key currently holds rows for, ascending.
  defp rows_for(table, key) do
    table
    |> :ets.select([{{{key, :"$1"}, :_}, [], [:"$1"]}])
    |> Enum.sort()
  end
end
