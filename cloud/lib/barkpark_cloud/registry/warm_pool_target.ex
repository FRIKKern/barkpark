defmodule BarkparkCloud.Registry.WarmPoolTarget do
  @moduledoc """
  The warm-pool size the Go worker says it is configured for, as last reported
  on its job poll.

  Why it exists: the claim store can hold `ready` warm servers while the worker
  runs with `WARM_POOL_SIZE=0`. On 2026-11-19 it held two, and
  `GET /v1/operator/warm-pool` answered `{ready: 2}`, so the owner believed warm
  servers stood ready. With the pool off, the worker's go-live path never claims
  them. The ready count alone cannot tell those two states apart; the worker's
  own target can.

  How it arrives: every `POST /v1/internal/provision-jobs/claim` (the worker
  polls it about every 5 s when idle) carries the header
  `x-barkpark-warm-pool-target: <n>`, `0` when the pool is off. The router pipes
  the conn through `note/1` after `require_worker`; a halted (refused) conn
  records nothing. This module keeps the last value and the time it was seen.

  It lives in memory only, in a public ETS table owned by this GenServer (the
  same shape as `AgentKeyStash`). A restart empties it. With blue/green control
  plane slots, each slot keeps its own table, and the worker reaches whichever
  slot Caddy routes to. A freshly started slot therefore reports the target as
  UNKNOWN (`worker_target: null`, `worker_pool: "unknown"`) until the worker's
  next poll lands on it, which is a few seconds when the worker is idle and can
  be minutes while it runs a provision. It never reports 0 or "on" for a worker
  it has not heard from. A worker built before this header existed also reads
  as unknown.

  A missing or malformed header, or a value outside 0..#{10_000}, records
  nothing, so a bad value cannot overwrite a good one. Reading never changes claim, refill or reconcile
  behaviour; this module is a report only.
  """

  use GenServer

  @table :bp_warm_pool_target
  @header "x-barkpark-warm-pool-target"
  # Far above any real pool; the bound keeps a junk header from being stored
  # and reported as "on" (or overflowing a reader's integer).
  @max_target 10_000

  ## Client

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The request header the worker sets on its job poll."
  @spec header() :: String.t()
  def header, do: @header

  @doc """
  Record the target from a worker request's `#{@header}` header, when the conn
  is not halted and the value parses (see `parse/1`). Returns the conn
  unchanged, so the router can pipe through it.
  """
  @spec note(Plug.Conn.t()) :: Plug.Conn.t()
  def note(%Plug.Conn{halted: true} = conn), do: conn

  def note(%Plug.Conn{} = conn) do
    with [raw | _] <- Plug.Conn.get_req_header(conn, @header),
         {:ok, n} <- parse(raw) do
      record(n)
    end

    conn
  end

  @doc "Parse a header value: an integer in 0..#{@max_target}, or `:error`."
  @spec parse(term()) :: {:ok, non_neg_integer()} | :error
  def parse(raw) when is_binary(raw) do
    case Integer.parse(String.trim(raw)) do
      {n, ""} when n in 0..@max_target -> {:ok, n}
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc "Store `n` as the worker's target, seen now."
  @spec record(non_neg_integer()) :: :ok
  def record(n) when is_integer(n) and n in 0..@max_target do
    if table?(), do: :ets.insert(@table, {:target, n, DateTime.utc_now()})
    :ok
  end

  @doc "The last reported target and when it was seen, or `:unknown`."
  @spec read() :: {:ok, non_neg_integer(), DateTime.t()} | :unknown
  def read do
    with true <- table?(),
         [{:target, n, seen_at}] <- :ets.lookup(@table, :target) do
      {:ok, n, seen_at}
    else
      _ -> :unknown
    end
  end

  @doc """
  The `GET /v1/operator/warm-pool` body. `ready` keeps its old meaning; the
  worker keys are new and are `null` (with `worker_pool: "unknown"`) until this
  control-plane slot has heard from the worker.
  """
  @spec status(non_neg_integer(), DateTime.t()) :: map()
  def status(ready, now \\ DateTime.utc_now()) do
    case read() do
      {:ok, n, seen_at} ->
        %{
          ready: ready,
          worker_target: n,
          worker_pool: if(n > 0, do: "on", else: "off"),
          worker_seen_at: DateTime.to_iso8601(seen_at),
          worker_seen_ago_s: max(DateTime.diff(now, seen_at, :second), 0)
        }

      :unknown ->
        %{
          ready: ready,
          worker_target: nil,
          worker_pool: "unknown",
          worker_seen_at: nil,
          worker_seen_ago_s: nil
        }
    end
  end

  @doc "Test hook: forget the reported target (a fresh slot)."
  def reset do
    if table?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  ## Server

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
