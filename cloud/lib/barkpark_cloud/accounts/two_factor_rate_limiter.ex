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
  user. That sweep is PER-KEY and only strictly-older: its match head pins the
  user id being checked, so it bounds how many rows ONE user accrues (to one)
  and nothing more — there is no periodic prune, so rows for users who never
  return again stay until `reset/0`. A full token-bucket / `Hammer` dependency
  would be overkill for one route.

  `check/1` is the only mutation: it bumps the current window's counter and
  returns `:ok` while at or under the limit, `{:error, {:rate_limited,
  retry_after_seconds}}` once the limit is exceeded. `reset/0` clears the table
  (test determinism only).

  `retry_after_seconds` is DERIVED, never guessed: a fixed window means the
  budget refills at the window boundary, so the wait is exactly the remainder of
  the current window (`(window + 1) * @window_ms - now_ms`, rounded UP to whole
  seconds and floored at 1 — a caller told "retry in 0s" would just bounce off
  the same 429). Mirrors the `Notifications.deliver_test/2` precedent, which
  already returns `{:error, {:rate_limited, retry_after}}` so the router can put
  a real number in the 429 body instead of an opaque "try again later".
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
  `{:error, {:rate_limited, retry_after_seconds}}` once that is exceeded —
  `retry_after_seconds` being the whole seconds left of the current window (>= 1).
  """
  @spec check(binary(), integer()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(user_id, now_ms \\ System.system_time(:millisecond))

  def check(user_id, now_ms) when is_binary(user_id) and is_integer(now_ms) do
    window = div(now_ms, @window_ms)

    # Drop this user's rows from any STRICTLY EARLIER window (a guard `:"$1"`
    # less than the current window) so this key's rows can't accrete. Strictly
    # earlier, never merely different: a caller whose `window` view is stale —
    # by the scheduling gap since it was derived, or by a backwards clock step —
    # would otherwise delete a NEWER window's counter and hand it a fresh budget.
    :ets.select_delete(@table, [
      {{{user_id, :"$1"}, :_}, [{:<, :"$1", window}], [true]}
    ])

    # update_counter is atomic; the default {key, 0} seeds a fresh window.
    count = :ets.update_counter(@table, {user_id, window}, {2, 1}, {{user_id, window}, 0})

    if count > @limit, do: {:error, {:rate_limited, retry_after(window, now_ms)}}, else: :ok
  end

  # Whole seconds until the fixed window rolls over and the budget refills.
  # Rounded UP (a 200ms remainder is "1s", not "0s") and floored at 1.
  defp retry_after(window, now_ms) do
    remaining_ms = (window + 1) * @window_ms - now_ms
    remaining_ms |> Kernel./(1000) |> Float.ceil() |> trunc() |> max(1)
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
