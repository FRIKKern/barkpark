defmodule Barkpark.SingleFlight do
  @moduledoc """
  Run an expensive derivation ONCE for everyone who asks for the same key at
  the same time, and serve its result to later askers for a short TTL
  (am-w2-s4, anonymous-metering wave 2).

  `run(key, ttl_ms, fun)`:

    * a fresh result for `key` (younger than `ttl_ms`) is returned from ETS;
    * otherwise, if another process is already computing `key`, the caller
      WAITS for that computation and gets its result;
    * otherwise the caller computes `fun.()` itself, in its own process, and
      every waiter that arrived meanwhile gets the same value.

  A leader that raises or dies does not strand its waiters: the coordinator
  monitors the leader, and on its exit every waiter computes for itself (the
  same outcome as having no single-flight at all). A waiter that hears nothing
  within its timeout also computes for itself. Nothing here can make a call
  fail that would have succeeded without it.

  The cache holds RESULTS, so a key must name everything the result depends
  on (dataset, tenant, the caller's visibility class). It is node-local, which
  is the point: it bounds the work one node does, and two nodes each computing
  once is still bounded.

  Process-free reads: the ETS table is `:public` + `read_concurrency`, so a
  cache hit never touches the coordinator.
  """
  use GenServer

  @table __MODULE__
  @wait_timeout 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The value of `fun.()` for `key`, computed at most once per `ttl_ms` across
  concurrent callers on this node. See the moduledoc.
  """
  @spec run(term(), non_neg_integer(), (-> value)) :: value when value: term()
  def run(key, ttl_ms, fun) when is_integer(ttl_ms) and ttl_ms >= 0 and is_function(fun, 0) do
    case fresh(key) do
      {:ok, value} ->
        value

      :miss ->
        if Process.whereis(__MODULE__), do: coordinate(key, ttl_ms, fun), else: fun.()
    end
  end

  @doc "Forget `key` (or every key with `:all`)."
  def evict(:all) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  def evict(key) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, key)
    :ok
  end

  defp fresh(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
      _ -> :miss
    end
  end

  defp coordinate(key, ttl_ms, fun) do
    case GenServer.call(__MODULE__, {:claim, key}) do
      :lead ->
        value =
          try do
            fun.()
          rescue
            e ->
              GenServer.call(__MODULE__, {:abort, key})
              reraise e, __STACKTRACE__
          catch
            kind, reason ->
              GenServer.call(__MODULE__, {:abort, key})
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        GenServer.call(__MODULE__, {:complete, key, value, ttl_ms})
        value

      {:wait, ref} ->
        receive do
          {^ref, {:ok, value}} -> value
          {^ref, :leader_down} -> fun.()
        after
          @wait_timeout -> fun.()
        end
    end
  end

  # ── coordinator ─────────────────────────────────────────────────────────────
  #
  # State: %{key => %{leader: pid, monitor: ref, waiters: [{pid, ref}]}}.

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:claim, key}, {pid, _tag}, inflight) do
    case Map.fetch(inflight, key) do
      {:ok, flight} ->
        ref = make_ref()

        {:reply, {:wait, ref},
         Map.put(inflight, key, %{flight | waiters: [{pid, ref} | flight.waiters]})}

      :error ->
        monitor = Process.monitor(pid)
        {:reply, :lead, Map.put(inflight, key, %{leader: pid, monitor: monitor, waiters: []})}
    end
  end

  # A leader whose derivation raised: its waiters compute for themselves.
  def handle_call({:abort, key}, _from, inflight) do
    {:reply, :ok, release(inflight, key, :leader_down)}
  end

  def handle_call({:complete, key, value, ttl_ms}, _from, inflight) do
    now = System.monotonic_time(:millisecond)
    # Expired entries are dropped here, so the table holds only live keys.
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    :ets.insert(@table, {key, value, now + ttl_ms})

    case Map.pop(inflight, key) do
      {nil, inflight} ->
        {:reply, :ok, inflight}

      {flight, inflight} ->
        Process.demonitor(flight.monitor, [:flush])
        Enum.each(flight.waiters, fn {pid, ref} -> send(pid, {ref, {:ok, value}}) end)
        {:reply, :ok, inflight}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, inflight) do
    case Enum.find(inflight, fn {_key, flight} -> flight.monitor == monitor end) do
      {key, _flight} -> {:noreply, release(inflight, key, :leader_down)}
      nil -> {:noreply, inflight}
    end
  end

  defp release(inflight, key, message) do
    case Map.pop(inflight, key) do
      {nil, inflight} ->
        inflight

      {flight, inflight} ->
        Process.demonitor(flight.monitor, [:flush])
        Enum.each(flight.waiters, fn {pid, ref} -> send(pid, {ref, message}) end)
        inflight
    end
  end
end
