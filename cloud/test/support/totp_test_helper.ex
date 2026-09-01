defmodule BarkparkCloud.TotpTestHelper do
  @moduledoc """
  The ONLY producer of TOTP codes in `cloud/test/` — the cloud-side twin of
  `Barkpark.TotpTestHelper` (api/test/support/totp_test_helper.ex).

  ## Why a twin and not a shared module

  `cloud/` is a SEPARATE mix project with its own `elixirc_paths` and its own
  deps; `api/test/support` is not on its load path and is not a dependency.
  Sharing the module would mean either making one app's test tree a build input
  of the other's, or hoisting test support into a lib both depend on — both are
  heavier and more surprising than a sibling with an identical contract. So the
  contract is duplicated deliberately, and `totp_test_helper_test.exs` guards it
  in TWO layers, because one is not enough:

    * **CONTRACT PARITY** — the api module's exported `name/arity` set must stay
      a subset of this one. Catches a dropped or renamed function.
    * **BEHAVIOURAL PARITY** — the api source is read and compiled into cloud's
      test VM at run time, and both implementations are run against the same
      pinned inputs. Catches a drifted BODY, which the first layer cannot see at
      all: a mutation that moved the api twin's period from 30s to 60s and
      disarmed its `wait_ms/2` entirely — turning it back into the wall-clock
      race this module exists to remove — left the name/arity check green with
      exit 0. "Cannot drift silently" is a claim about behaviour, so it needs a
      check on behaviour.

  ## The defect this removes

  A test that computes a code inline and then uses it across a gap —

      code = NimbleTOTP.verification_code(secret)
      {:ok, user, _} = Accounts.enable_totp(user, secret, code)

  — is racing the wall clock. TOTP codes are valid for the 30s *period* they
  were minted in, counted from the Unix epoch. If that period rolls inside the
  gap, the server correctly rejects a code the test believes is current, and the
  run reds for the clock rather than for the behaviour under test. **The server
  is right; the test is wrong.**

  ## The contract

  `totp_code_stable!/2` computes the headroom left in the current period and,
  **only if it is below `min_headroom_ms`**, sleeps out the boundary *before*
  generating, so generation and validation land in the same period by
  construction.

  It is deliberately NOT a blanket sleep (under headroom `wait_ms/2` returns
  exactly 0 — asserted, not claimed), NOT a retry wrapper (retrying around a
  race preserves the lie), and NOT a clock stub (the code under test still runs
  against the real `System.os_time/1` the server reads).

  ## Off-period codes, and why cloud needs a BASE-PINNED variant

  cloud's 2FA suite probes WINDOW WIDTH — how many periods the server accepts —
  so it must keep generating deliberately off-period codes.
  `code_for_period_offset!/3` covers the common case.

  But `two_factor_test.exs` test (b) seeds `two_factor_last_step` from a
  captured `now` and then mints codes at N, N+1 and N-1 **relative to that same
  `now`**. Re-reading the clock per call would let a period roll mid-test and
  silently turn "next step" into "this step", so the assertion could pass or
  fail for the wrong reason. `stable_period_base!/1` + `code_at_period_offset/3`
  exist for that shape: establish headroom ONCE, pin the base, then derive every
  code from it purely. The api tree has no test of that shape, which is why the
  api helper has no such pair — a difference the parity test knows about and
  records rather than papers over.
  """

  # TOTP period, in seconds. Mirrors NimbleTOTP's `@default_totp_period`; the
  # server never overrides it, so neither do we.
  @period_seconds 30
  @period_ms @period_seconds * 1_000

  # How much of the current period must remain for a freshly generated code to
  # still be current when the server validates it. Sized well above the slowest
  # shape in this tree (an HTTP round trip through the router) so a contended
  # runner cannot eat it. The wait fires on 2000/30000 = 6.7% of calls and
  # sleeps at most 2s, so the expected added wall time is ~67ms per call and 0ms
  # on the other 93.3%.
  @default_min_headroom_ms 2_000

  @doc """
  Generate a TOTP code that is guaranteed not to expire mid-test.

  Waits out the period boundary first if — and only if — less than
  `:min_headroom_ms` (default #{@default_min_headroom_ms}ms) remains.
  """
  @spec totp_code_stable!(binary(), keyword()) :: String.t()
  def totp_code_stable!(secret, opts \\ []) when is_binary(secret) do
    await_period_headroom!(opts)
    NimbleTOTP.verification_code(secret)
  end

  @doc """
  Generate a code for a period `offset` away from the current one.

  Negative offsets are past periods, positive are future. Boundary-guarded via
  the same headroom wait, so the offset the caller asked for is still the offset
  in effect when the server validates.

  When several offsets must share ONE base instant, use `stable_period_base!/1`
  with `code_at_period_offset/3` instead — this function re-reads the clock on
  every call by design.
  """
  @spec code_for_period_offset!(binary(), integer(), keyword()) :: String.t()
  def code_for_period_offset!(secret, offset, opts \\ [])
      when is_binary(secret) and is_integer(offset) do
    base = stable_period_base!(opts)
    code_at_period_offset(secret, base, offset)
  end

  @doc """
  Establish period headroom once and return the Unix-second instant to pin every
  derived code to.

  For tests that mint several codes at different offsets from ONE base, or that
  seed persistent state (`two_factor_last_step`) from the same instant they
  generate against. Taking the base after the wait is what makes the whole group
  land in one period.
  """
  @spec stable_period_base!(keyword()) :: integer()
  def stable_period_base!(opts \\ []) do
    await_period_headroom!(opts)
    System.os_time(:second)
  end

  @doc """
  The code for `offset` periods away from `base_seconds`.

  PURE with respect to the clock: it reads no time of its own, so every code in
  a group derives from the single base the caller pinned.
  """
  @spec code_at_period_offset(binary(), integer(), integer()) :: String.t()
  def code_at_period_offset(secret, base_seconds, offset)
      when is_binary(secret) and is_integer(base_seconds) and is_integer(offset) do
    NimbleTOTP.verification_code(secret, time: base_seconds + offset * @period_seconds)
  end

  @doc """
  Block until the current period has at least `:min_headroom_ms` remaining.

  Returns the milliseconds actually slept — **0 whenever the wait did not
  fire**, which is what makes "this is not a blanket sleep" assertable rather
  than a claim in a comment.
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

  Pure — `now_ms` is injected, so the boundary arithmetic is testable without
  waiting on a real clock.
  """
  @spec headroom_ms(integer()) :: pos_integer()
  def headroom_ms(now_ms) when is_integer(now_ms),
    do: @period_ms - Integer.mod(now_ms, @period_ms)

  @doc """
  How long a generator at `now_ms` must sleep to land in a safe period: the
  remaining headroom when it is too thin to trust, `0` otherwise.

  Sleeping exactly `headroom_ms/1` lands on the first instant of the next
  period — the maximum possible headroom — so the wait fires at most once.
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
