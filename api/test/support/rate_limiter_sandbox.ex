defmodule Barkpark.RateLimiterSandbox do
  @moduledoc """
  Per-test isolation for `Barkpark.RateLimiter`'s WHOLE-NODE token buckets.

  `RateLimiter` keeps its buckets in a `:named_table` ETS table
  (`:barkpark_rate_limiter`, rate_limiter.ex:26/50-56). A named table is node
  state, not process state: it outlives every test, it is not owned by the SQL
  sandbox, and nothing in `api/test/support` ever reset it. So a bucket a test
  spends stays spent for the rest of the run.

  That is cross-test contamination BY CONSTRUCTION, and the test suite's own keys
  make it bite. `rate_limiter_test.exs` asserts, on a literal key with a capacity
  of one:

      assert RateLimiter.check({:token, "a"}, capacity: 1, refill_per_sec: 0.0) == :ok
      assert RateLimiter.check({:token, "a"}, capacity: 1, refill_per_sec: 0.0) == :rate_limited

  The first line is only true if nobody has spent `{:token, "a"}` yet. Keys like
  `{:token, "a"}`, `{:token, "b"}` and `{:token, "new-key"}` are short literals
  with no per-test uniqueness, so whether that assertion holds depends on what
  ran before it — the definition of an order-dependent test.

  ## Why a reset is safe here, and why it is gated on `async`

  Wiping a whole-node table from a test is only safe if no OTHER test can be
  using it at the same time. ExUnit runs `async: true` tests concurrently with
  each other, and runs `async: false` tests serially after them — so a reset
  performed only for non-async tests can never race a peer.

  Measured on origin/main: ALL FIFTEEN test files that reference `RateLimiter` or
  `:barkpark_rate_limiter` are already `async: false`. Nothing is being re-pinned
  to dodge a race — the pinning already existed, undocumented and unenforced.
  `rate_limiter_async_isolation_test.exs` now enforces it, so an `async: true`
  rate-limit test (which this reset could not protect, and which would race its
  peers on shared node state) reds instead of flaking.

  ## Use

      setup :reset_rate_limiter!

  It is idempotent and safe to call when the table does not exist yet.
  """

  @table :barkpark_rate_limiter

  @doc """
  Drop every token bucket, so this test starts from a table nobody has spent.

  Takes the ExUnit context so it can be used directly as `setup
  :reset_rate_limiter!`. REFUSES to wipe on behalf of an `async: true` test: the
  table is shared node state, and clearing it under a concurrently-running peer
  would trade one contamination for a worse one.
  """
  @spec reset_rate_limiter!(map()) :: :ok
  def reset_rate_limiter!(context) when is_map(context) do
    if Map.get(context, :async, false) do
      raise """
      Barkpark.RateLimiterSandbox.reset_rate_limiter!/1 was called from an
      `async: true` test (#{inspect(Map.get(context, :module))}).

      `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state. Clearing it
      while concurrent async tests are running would wipe their buckets mid-flight.
      Rate-limit tests must be `async: false`; see
      test/barkpark/rate_limiter_async_isolation_test.exs.
      """
    end

    reset!()
  end

  @doc """
  Drop every token bucket. The unconditional form, for callers that are not an
  ExUnit `setup` (and have already established they are not async).
  """
  @spec reset!() :: :ok
  def reset!() do
    case :ets.whereis(@table) do
      :undefined ->
        # The table is created by RateLimiter.start_link/1 at boot. If it is
        # absent the limiter has not started, so there is nothing to contaminate.
        :ok

      _tid ->
        :ets.delete_all_objects(@table)
        :ok
    end
  end

  @doc "The named table under test — exposed so guards can assert on it by name."
  @spec table() :: atom()
  def table, do: @table
end
