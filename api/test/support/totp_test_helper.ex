defmodule Barkpark.TotpTestHelper do
  @moduledoc """
  The ONLY producer of TOTP codes in `api/test/` (honest-gates charter, S1).

  ## The defect this removes

  A test that computes a code inline and then uses it across a gap —

      code = NimbleTOTP.verification_code(secret)
      {:ok, user, _} = Accounts.enable_totp(user, secret, code)

  — is racing the wall clock. TOTP codes are valid for the 30s *period* they
  were minted in, counted from the Unix epoch. If that period rolls inside the
  gap, the code the test generated is no longer the code the server computes,
  the server correctly rejects it (`:error` / 422 `invalid_code` / 401
  `mfa_required`), and the run reds for a reason that has nothing to do with the
  behaviour under test. **The server is right; the test is wrong.**

  Measured straddle probability at the two call shapes in this tree:

    * SHAPE B — HTTP round-trip (mean 45.7ms): ~1 in 657 per site, ~1 in 73
      suite runs across the 9 sites.
    * SHAPE A — same-process `Accounts.enable_totp/3` (p50 586us, p95 3998us,
      max 5728us): ~1 in 31,561 per site, ~1 in 1,973 suite runs across the 16
      sites. Shape A was originally filed as a "microsecond gap, zero observed
      failures" on the strength of a pure-`NimbleTOTP` proxy that put it at 1 in
      1,034,483 — measuring the real path moved it by 33x. Unobserved is not
      safe (charter D15), so shape A is migrated too.

  ## The contract

  `totp_code_stable!/2` computes the headroom left in the current period and,
  **only if that headroom is below `min_headroom_ms`**, sleeps out the boundary
  *before* generating. Generation and the server's validation then land in the
  same period by construction.

  Three things it deliberately is NOT:

    * **Not a blanket sleep.** Under headroom `wait_ms/2` returns exactly 0 and
      nothing sleeps. A helper that always sleeps is the same disease wearing a
      fix's clothes — `totp_test_helper_test.exs` sweeps all 30,000 offsets in a
      period and pins the exact set that fires.
    * **Not a retry wrapper.** It never re-generates after a rejection. Retrying
      around a race hides it and preserves the lie (charter D2); this removes the
      contaminating variable instead.
    * **Not a clock stub.** It moves the test into a safe part of the real
      period rather than freezing time, so the code under test still runs against
      the real `System.os_time/1` the server reads.

  ## Off-period codes

  `code_for_period_offset!/3` is the deliberate escape hatch for tests that must
  observe **window width** — how many periods the server accepts. Before this
  slice, `grep -rn 'verification_code(.*time:' api/test/` returned 0: the api
  suite generated zero off-period codes and was therefore structurally incapable
  of noticing if someone widened the live TOTP acceptance window. `FENCE B` in
  `accounts_test.exs` is that missing eye.
  """

  # TOTP period, in seconds. This mirrors NimbleTOTP's `@default_totp_period`;
  # the server never overrides it, so neither do we.
  @period_seconds 30
  @period_ms @period_seconds * 1_000

  # How much of the current period must remain for a freshly generated code to
  # still be current by the time the server validates it.
  #
  # This is a budget for the whole gap between generation and validation, and it
  # is sized ~40x the slowest shape we measured (shape B mean 45.7ms) so that a
  # contended CI runner cannot eat it. The cost of that generosity is bounded and
  # small: the wait fires on 2000/30000 = 6.7% of calls and sleeps at most 2s, so
  # the expected added wall time is (2000/30000) * (2000/2) ≈ 67ms per call —
  # ~1.7s across all 25 migrated sites, and 0ms on the other 93.3%.
  @default_min_headroom_ms 2_000

  @doc """
  Generate a TOTP code that is guaranteed not to expire mid-test.

  Waits out the period boundary first if — and only if — less than
  `:min_headroom_ms` (default #{@default_min_headroom_ms}ms) remains in the
  current period. Returns the six-digit code.

      code = totp_code_stable!(secret)
      {:ok, user, _codes} = Accounts.enable_totp(user, secret, code)

  Pass `:min_headroom_ms` when a call site needs a larger budget than the
  default — e.g. a test that generates once and then validates several times.
  """
  @spec totp_code_stable!(binary(), keyword()) :: String.t()
  def totp_code_stable!(secret, opts \\ []) when is_binary(secret) do
    await_period_headroom!(opts)
    NimbleTOTP.verification_code(secret)
  end

  @doc """
  Generate a code for a period `offset` away from the current one.

  Negative offsets are past periods, positive are future. Used by window-width
  fences — a server that accepts `code_for_period_offset!(secret, -1)` has a
  grace window, which is exactly the thing that must never be added silently.

  Boundary-guarded via the same headroom wait, so the offset the caller asked
  for is still the offset in effect when the server validates: without the
  guard, a roll between generation and validation would silently turn "previous
  period" into "two periods ago", and a fence asserting *rejection* would pass
  for the wrong reason.
  """
  @spec code_for_period_offset!(binary(), integer(), keyword()) :: String.t()
  def code_for_period_offset!(secret, offset, opts \\ [])
      when is_binary(secret) and is_integer(offset) do
    await_period_headroom!(opts)
    NimbleTOTP.verification_code(secret, time: System.os_time(:second) + offset * @period_seconds)
  end

  @doc """
  Block until the current period has at least `:min_headroom_ms` remaining.

  Returns the number of milliseconds actually slept — **0 whenever the wait did
  not fire**, which is what makes "this is not a blanket sleep" an assertable
  property rather than a claim in a comment.
  """
  @spec await_period_headroom!(keyword()) :: non_neg_integer()
  def await_period_headroom!(opts \\ []) do
    case wait_ms(System.os_time(:millisecond), min_headroom_ms(opts)) do
      0 ->
        0

      ms ->
        Process.sleep(ms)
        ms
    end
  end

  @doc """
  Milliseconds remaining in the TOTP period containing `now_ms`.

  Pure — `now_ms` is always injected, so the boundary arithmetic is testable
  without waiting on a real clock.
  """
  @spec headroom_ms(integer()) :: pos_integer()
  def headroom_ms(now_ms) when is_integer(now_ms),
    do: @period_ms - Integer.mod(now_ms, @period_ms)

  @doc """
  How long a generator at `now_ms` must sleep to land in a safe period: the
  remaining headroom when it is too thin to trust, `0` otherwise.

  Sleeping exactly `headroom_ms/1` lands on the first instant of the next
  period, i.e. the maximum possible headroom — so the wait fires at most once
  and never needs a second look.
  """
  @spec wait_ms(integer(), pos_integer()) :: non_neg_integer()
  def wait_ms(now_ms, min_headroom_ms \\ @default_min_headroom_ms)
      when is_integer(now_ms) and is_integer(min_headroom_ms) and min_headroom_ms > 0 do
    case headroom_ms(now_ms) do
      headroom when headroom < min_headroom_ms -> headroom
      _ -> 0
    end
  end

  @doc "The TOTP period in seconds (30) — the server never overrides it."
  @spec period_seconds() :: pos_integer()
  def period_seconds, do: @period_seconds

  @doc "The default headroom budget in milliseconds."
  @spec default_min_headroom_ms() :: pos_integer()
  def default_min_headroom_ms, do: @default_min_headroom_ms

  defp min_headroom_ms(opts), do: Keyword.get(opts, :min_headroom_ms, @default_min_headroom_ms)
end
