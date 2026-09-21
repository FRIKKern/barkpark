defmodule BarkparkCloud.RateLimitWindowTest do
  @moduledoc """
  The seam that every real-clock rate-limit loop leans on, pinned.

  Three things are asserted, and the first is the one that matters: the seam's
  POSTCONDITION holds no matter where in the minute it is called. The proof is
  not "call it and look" — that is green 59 times in 60 whatever the code does.
  It is the pure `remaining_ms/1` arm, swept across the whole window, plus a
  live call whose postcondition is re-read from the real clock.

  Also pinned: the mirrored `@window_ms` really is both limiters' window. The
  helper hard-codes 60_000 because neither limiter exposes its attribute; if
  either one ever moves, this file reds instead of the seam silently drifting.

  `async: false` — the mirror arm drives the two limiters' real ETS tables, the
  same singleton every other rate-limit file serialises on.
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.Accounts.TwoFactorRateLimiter
  alias BarkparkCloud.DeviceAuth.RateLimiter
  alias BarkparkCloud.RateLimitWindow, as: W

  setup do
    RateLimiter.reset()
    TwoFactorRateLimiter.reset()

    on_exit(fn ->
      RateLimiter.reset()
      TwoFactorRateLimiter.reset()
    end)

    :ok
  end

  test "remaining_ms/1 is the distance to the next calendar-minute boundary, everywhere in the window" do
    # A window base that is exactly on a boundary, so the offsets below ARE the
    # position within the window.
    base = 1_758_000_000_000 - rem(1_758_000_000_000, W.window_ms())

    for offset <- [0, 1, 999, 1_000, 30_000, 57_999, 58_000, 59_999] do
      assert W.remaining_ms(base + offset) == W.window_ms() - offset,
             "remaining_ms/1 is wrong #{offset}ms into the window"
    end

    # Never zero and never more than a whole window — the two ways a caller
    # could be handed a remainder that does not bound a loop.
    for offset <- 0..(W.window_ms() - 1)//97 do
      r = W.remaining_ms(base + offset)
      assert r > 0 and r <= W.window_ms()
    end
  end

  test "align!/1 leaves at least the headroom, INCLUDING when it is called at the boundary" do
    # The real call: whatever the clock said, the postcondition holds after.
    slept = W.align!()
    assert slept >= 0

    assert W.remaining_ms() >= W.headroom_ms(),
           "align!/0 returned with only #{W.remaining_ms()}ms of window left"

    # And the bound: the sleep can never exceed the headroom it is protecting,
    # so the seam can never pause a suite for a whole window.
    assert slept <= W.headroom_ms() + 5
  end

  test "the mirrored window matches BOTH limiters' own fixed window" do
    # Read from the limiters themselves, not from a comment: each one's window
    # is the distance at which a key's budget resets. Driven off the REAL clock
    # so the rows sit in the live window and no concurrent sweep can reclaim
    # them out from under the assertion.
    now = System.system_time(:millisecond)

    key = "start:mirror-#{System.unique_integer([:positive])}"
    for _ <- 1..10, do: assert(RateLimiter.check(key, now) == :ok)
    assert {:error, :rate_limited} = RateLimiter.check(key, now)

    assert :ok = RateLimiter.check(key, now + W.window_ms()),
           "DeviceAuth.RateLimiter's window is not #{W.window_ms()}ms — the seam's mirror drifted"

    user = "mirror-user-#{System.unique_integer([:positive])}"
    for _ <- 1..5, do: assert(TwoFactorRateLimiter.check(user, now) == :ok)
    assert {:error, {:rate_limited, _}} = TwoFactorRateLimiter.check(user, now)

    assert :ok = TwoFactorRateLimiter.check(user, now + W.window_ms()),
           "TwoFactorRateLimiter's window is not #{W.window_ms()}ms — the seam's mirror drifted"
  end
end
