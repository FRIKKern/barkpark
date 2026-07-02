defmodule Barkpark.RateLimiter do
  @table :barkpark_rate_limiter

  @default_capacity 200
  @default_refill_per_sec 200.0 / 60.0

  # The table holds one {key, tokens, last_ms} bucket per rate-limit key
  # (IP/token) and nothing ever deleted them — so in the long-lived API server it
  # grew without bound (one permanent entry per unique client ever seen).
  # maybe_prune/1 opportunistically drops buckets untouched for @stale_after_ms.
  # The plug's capacity/refill is a CONSTANT 60s full-refill (both scale with
  # per_minute), so any bucket idle ≥5 min is fully refilled — dropping it is
  # behaviour-identical to keeping it (the next request just re-creates a full
  # bucket), with no rate-limit reset/bypass. The prune only runs once the table
  # passes @max_entries, so the steady-state hot path costs one :ets.info/2.
  @max_entries 10_000
  @stale_after_ms 300_000

  def start_link(_opts \\ []) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end

    {:ok, self()}
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @spec check(term(), keyword()) :: :ok | :rate_limited
  def check(key, opts \\ []) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)
    refill = Keyword.get(opts, :refill_per_sec, @default_refill_per_sec)
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [] ->
        maybe_prune(now_ms)
        :ets.insert(@table, {key, capacity - 1.0, now_ms})
        :ok

      [{^key, tokens, last_ms}] ->
        elapsed_s = (now_ms - last_ms) / 1000
        refilled = min(capacity * 1.0, tokens + elapsed_s * refill)

        if refilled >= 1.0 do
          :ets.insert(@table, {key, refilled - 1.0, now_ms})
          :ok
        else
          :rate_limited
        end
    end
  end

  # Drop fully-refilled (stale) buckets once the table grows past @max_entries.
  # Runs on the new-key path only, and does real work only when over the bound,
  # so a pruned table stays under it until it grows again — naturally throttled.
  defp maybe_prune(now_ms) do
    if :ets.info(@table, :size) > @max_entries do
      cutoff = now_ms - @stale_after_ms
      :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    end

    :ok
  end
end
