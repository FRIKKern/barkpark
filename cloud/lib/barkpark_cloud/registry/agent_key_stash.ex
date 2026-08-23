defmodule BarkparkCloud.Registry.AgentKeyStash do
  @moduledoc """
  PDF-D94 (`pdf-bl-console-key-custody`) — the IN-MEMORY, ONE-TIME stash a
  pasted agent provider key rides between `POST /v1/barkparks/:id/agent-key`
  and the Go worker's `POST /v1/internal/agent-key-jobs/claim`.

  Custody law (D62 amended by D94: NEVER WRITES → NEVER KEEPS): the control
  plane is TRANSPORT ONLY for a provider key. The key must be provably never
  persisted CP-side — no DB column, no log line, no audit payload. So it lives
  here: a public ETS table owned by a GenServer (the same table-owning shape as
  `TwoFactorRateLimiter`), keyed by the enqueued `push_agent_key` job id.

    * `put/3` stores `{key_var, key}` under the job id with a TTL.
    * `take/1` is DELETE-ON-READ (`:ets.take`): the claim that delivers the key
      to the worker is the LAST time the control plane can see it. A second
      claim (stale-claim re-hand-out after a worker crash) finds nothing and
      the router fails the job honestly — "paste it again".
    * A control-plane restart empties the table by construction — the honest
      failure mode D94 prefers over any durable copy.

  Expiry is LAZY, on the TwoFactorRateLimiter precedent: `take/1` refuses an
  expired row, and each `put/3` purges every expired row while it is there —
  no timer, no Oban job (the promise-actor manifest's "no non-Oban timers"
  absence stays true), and the table stays bounded by construction (one row
  per in-flight delivery, evicted on the next paste at the latest).
  """

  use GenServer

  @table :bp_agent_key_stash
  # 15 minutes: generous against a busy worker (5s poll cadence), tiny against
  # any custody concern. An unclaimed key evaporates.
  @ttl_ms 15 * 60 * 1000

  ## Client

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Stash `{key_var, key}` for `job_id` (TTL #{div(@ttl_ms, 60_000)} min)."
  @spec put(binary(), String.t(), String.t()) :: :ok
  def put(job_id, key_var, key)
      when is_binary(job_id) and is_binary(key_var) and is_binary(key) do
    now = System.monotonic_time(:millisecond)
    purge_expired(now)
    true = :ets.insert(@table, {job_id, key_var, key, now + @ttl_ms})
    :ok
  end

  @doc """
  Pop the stashed key for `job_id` — DELETE-ON-READ, one delivery ever.
  `:error` for an unknown/expired/already-delivered id.
  """
  @spec take(binary()) :: {:ok, {String.t(), String.t()}} | :error
  def take(job_id) when is_binary(job_id) do
    case :ets.take(@table, job_id) do
      [{^job_id, key_var, key, expires_at}] ->
        if System.monotonic_time(:millisecond) <= expires_at do
          {:ok, {key_var, key}}
        else
          :error
        end

      [] ->
        :error
    end
  end

  @doc "Test hook: drop every stashed entry (simulates the restart-loss edge)."
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  # Match spec: delete rows whose expires_at (element 4) is in the past.
  defp purge_expired(now) do
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
  end

  ## Server

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end
end
