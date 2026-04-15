defmodule Barkpark.RateLimiter do
  @table :barkpark_rate_limiter

  @default_capacity 200
  @default_refill_per_sec 200.0 / 60.0

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
end
