defmodule BarkparkCloud.Accounts.TwoFactorRateLimiter do
  @moduledoc """
  A 5-attempts-per-60s fixed window on the 2FA login challenge, keyed on the
  pending-login user id. Mirrors Coolify's
  `RateLimiter::for('two-factor', Limit::perMinute(5)->by($userId))`
  (`app/Providers/FortifyServiceProvider.php:145`).

  Cloud's router has no general HTTP rate limiter today, so this builds the
  smallest thing that matches: a GenServer owning one public ETS table of
  fixed-window counters. The key is `{user_id, window}` where
  `window = div(now_ms, @window_ms)`, so counters for an elapsed window are
  simply never read again and are swept lazily on the next `check/1` for that
  user. A full token-bucket / `Hammer` dependency would be overkill for one
  route.

  `check/1` is the only mutation: it bumps the current window's counter and
  returns `:ok` while at or under the limit, `{:error, :rate_limited}` once the
  limit is exceeded. `reset/0` clears the table (test determinism only).
  """
  use GenServer

  @table __MODULE__
  @limit 5
  @window_ms 60_000

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Record one challenge attempt for `user_id`. Returns `:ok` while the user is at
  or under #{@limit} attempts in the current #{div(@window_ms, 1000)}s window,
  `{:error, :rate_limited}` once that is exceeded.
  """
  @spec check(binary(), integer()) :: :ok | {:error, :rate_limited}
  def check(user_id, now_ms \\ System.system_time(:millisecond))

  def check(user_id, now_ms) when is_binary(user_id) and is_integer(now_ms) do
    window = div(now_ms, @window_ms)

    # Drop any stale rows for this user from an earlier window (a guard `:"$1"`
    # not equal to the current window) so the table can't grow unbounded.
    :ets.select_delete(@table, [
      {{{user_id, :"$1"}, :_}, [{:"/=", :"$1", window}], [true]}
    ])

    # update_counter is atomic; the default {key, 0} seeds a fresh window.
    count = :ets.update_counter(@table, {user_id, window}, {2, 1}, {{user_id, window}, 0})

    if count > @limit, do: {:error, :rate_limited}, else: :ok
  end

  @doc "Clear all counters (test helper — keeps async: false challenge tests deterministic)."
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end
end
