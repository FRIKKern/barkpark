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
  user id being checked, so it bounds how many rows ONE user accrues — to one,
  or transiently two while a straddling caller's older window sits beside a
  newer one, collapsing back to one on that user's next forward call — and
  nothing more. A full token-bucket / `Hammer` dependency would be overkill for
  one route.

  THE PER-KEY SWEEP IS NOT A BOUND ON THE TABLE, only on one key. A user who
  challenges once and never returns leaves a row nothing reclaims. Keyed on an
  authenticated user id this is bounded by the user table rather than by a
  caller's imagination — a far slower leak than the sibling
  `DeviceAuth.RateLimiter`'s attacker-chosen `"poll:"` key space, which is what
  acpc-bl-poll-key-unbounded-ets-growth measured at ~13 GB/day. It is the SAME
  defect at a smaller scale, so it takes the SAME fix rather than waiting to
  become one: `maybe_prune/1` sweeps every user's elapsed rows, at most once per
  window, elected by an atomic `insert_new/2` claim so exactly one caller per
  window pays the scan. The sibling module carries the full reasoning — why the
  sweep is in-band (Oban is this plane's only scheduler, and ETS is per-node so
  a job could not reach another node's table anyway), why it is claimed, and why
  the `{:__prune__, window}` marker cannot collide with a real key.

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
  # See `DeviceAuth.RateLimiter` — below this the global sweep is not worth the
  # `insert_new` it costs.
  @prune_floor 256

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

    maybe_prune(window)

    # update_counter is atomic; the default {key, 0} seeds a fresh window.
    count = :ets.update_counter(@table, {user_id, window}, {2, 1}, {{user_id, window}, 0})

    if count > @limit, do: {:error, {:rate_limited, retry_after(window, now_ms)}}, else: :ok
  end

  # THE GLOBAL SWEEP, at most once per window — the twin of
  # `DeviceAuth.RateLimiter.maybe_prune/1`, deliberately duplicated rather than
  # shared: the two limiters own SEPARATE tables on purpose (the key shapes
  # differ), and a shared module would exist only to hold six lines while adding
  # a dependency between two modules that currently have none.
  #
  # `:ets.info(:size)` is O(1), so a small table pays one integer compare.
  # Above the floor, the atomic `insert_new/2` elects one caller per window to
  # pay the scan. The guard deletes only STRICTLY earlier windows, so a
  # concurrent caller's current counter is never reset and handed a fresh budget
  # — the same reason the per-key sweep above is `<` and not `/=`.
  defp maybe_prune(window) do
    if :ets.info(@table, :size) > @prune_floor and
         :ets.insert_new(@table, {{:__prune__, window}, 0}) do
      :ets.select_delete(@table, [
        {{{:_, :"$1"}, :_}, [{:<, :"$1", window}], [true]}
      ])
    end

    :ok
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
