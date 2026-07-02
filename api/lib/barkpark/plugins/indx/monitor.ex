defmodule Barkpark.Plugins.Indx.Monitor do
  @moduledoc """
  Indx outcome counter — the operational instrument that closes the
  silent-fallback gap flagged in Barkpark Cloud P4b.

  Today the retriever falls back to empty results when the Indx engine is
  unreachable, unauthed, or returns malformed payloads — the user sees
  "no results" and has no way to tell whether that means "no matches" or
  "Indx down + we degraded silently". This module gives `bp doctor` (and
  any other operator surface) two things:

    * a per-scope counter table — `%{success: n, fallback: n, error: n,
      last_error_at, last_error_reason, fallback_rate}` — that
      `snapshot/1` / `snapshot_all/0` read in constant time.
    * one canonical telemetry event per outcome —
      `[:barkpark, :indx, :retriever, :outcome]` with
      `%{count: 1}` measurements and
      `%{scope, dataset, kind, reason?, status?}` metadata — that an
      operator can attach a handler to (Logger, Datadog, etc.) without
      patching the retriever.

  The counter table is a single public ETS table keyed by `{scope, kind}`
  with atomic `:ets.update_counter/4` increments — so the retriever
  records an outcome with one ETS op and no GenServer round trip. The
  GenServer owns the table only for lifetime; reads bypass it.

  Recording from the retriever uses the narrow public functions below
  (`record_success/2`, `record_fallback/3`). The `kind` atom is closed
  (`:success | :fallback`) so a new outcome class is a deliberate API
  bump.

  ## Bounded table

  The table accrues up to 3 permanent rows per distinct scope
  (`{scope, :success}`, `{scope, :fallback}`, `{scope, :last_error}`) and
  never evicts on its own — an unbounded, tenant-driven growth vein.
  Following the RateLimiter (#790) and DEK-cache (#792) fix, every write
  path that can create a NEW key first checks capacity and, when the table
  is at `@max_rows`, wipes it wholesale (`:ets.delete_all_objects/1`).
  This is lossy operational telemetry (counters + last-error stamps), so a
  full reset on overflow is acceptable — recording resumes immediately with
  fresh counts. Updates to keys that already exist never trigger the wipe.
  `@max_rows` is ~10k scopes × 3 rows.
  """

  use GenServer

  @table :barkpark_indx_monitor

  # Hard cap on total rows before a wholesale clear. ~10k distinct scopes
  # × 3 rows/scope. See the "Bounded table" moduledoc note (#790/#792).
  @max_rows 30_000

  # Internal row shape:
  #   {{scope, :success}, integer}
  #   {{scope, :fallback}, integer}
  #   {{scope, :last_error}, %{at: DateTime.t(), reason: term(), status: integer() | nil}}

  ## Public API

  @doc "Start the monitor under the host supervision tree."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Record a successful Indx call for `scope`. Optional `meta` carries
  `:dataset` for the telemetry event.
  """
  @spec record_success(String.t(), map()) :: :ok
  def record_success(scope, meta \\ %{}) when is_binary(scope) do
    bump({scope, :success})
    emit(:success, scope, meta)
    :ok
  end

  @doc """
  Record an Indx failure that resulted in a fallback (empty results returned
  to caller). `reason` is the underlying error term; `meta` may carry
  `:dataset` and `:status` (the HTTP status if known) for the telemetry
  metadata and the `last_error` row.
  """
  @spec record_fallback(String.t(), term(), map()) :: :ok
  def record_fallback(scope, reason, meta \\ %{}) when is_binary(scope) do
    bump({scope, :fallback})

    last = %{
      at: DateTime.truncate(DateTime.utc_now(), :microsecond),
      reason: inspect(reason),
      status: Map.get(meta, :status)
    }

    safe_insert({{scope, :last_error}, last})
    emit(:fallback, scope, Map.put(meta, :reason, reason))
    :ok
  end

  @doc """
  Read the live counts for one `scope`. Returns
  `%{success, fallback, fallback_rate, last_error_at, last_error_reason,
    last_error_status}`. A scope that has never been recorded returns
  zeros and `nil` last-error fields.
  """
  @spec snapshot(String.t()) :: map()
  def snapshot(scope) when is_binary(scope) do
    success = lookup_count({scope, :success})
    fallback = lookup_count({scope, :fallback})
    total = success + fallback

    last = lookup_last_error(scope)

    %{
      scope: scope,
      success: success,
      fallback: fallback,
      total: total,
      fallback_rate: if(total == 0, do: 0.0, else: fallback / total),
      last_error_at: last && last.at,
      last_error_reason: last && last.reason,
      last_error_status: last && last.status
    }
  end

  @doc "Snapshot every recorded scope. Newest-error scope first."
  @spec snapshot_all() :: [map()]
  def snapshot_all do
    case table() do
      nil ->
        []

      tab ->
        scopes =
          tab
          |> :ets.tab2list()
          |> Enum.map(fn {{scope, _}, _} -> scope end)
          |> Enum.uniq()

        scopes
        |> Enum.map(&snapshot/1)
        |> Enum.sort_by(& &1.last_error_at, fn a, b ->
          cond do
            is_nil(a) -> false
            is_nil(b) -> true
            true -> DateTime.compare(a, b) != :lt
          end
        end)
    end
  end

  @doc """
  Wipe all counters. Used by tests to keep snapshots hermetic. NOT for
  production reset — that should be a deliberate operator action under
  a separate management surface.
  """
  @spec reset() :: :ok
  def reset do
    case table() do
      nil -> :ok
      tab -> :ets.delete_all_objects(tab) && :ok
    end
  end

  ## GenServer

  @impl true
  def init(_opts) do
    tab =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: tab}}
  end

  ## Internals

  defp bump(key) do
    case table() do
      nil ->
        :ok

      tab ->
        ensure_capacity(tab, key)
        # Atomic counter — concurrent retriever calls never lose increments.
        :ets.update_counter(tab, key, {2, 1}, {key, 0})
        :ok
    end
  end

  defp safe_insert({key, _} = row) do
    case table() do
      nil ->
        :ok

      tab ->
        ensure_capacity(tab, key)
        :ets.insert(tab, row) && :ok
    end
  end

  # Bound the table: if inserting `key` would create a NEW row and we are
  # already at capacity, wipe the whole table. Lossy telemetry — a full
  # reset on overflow is acceptable (#790/#792 clear-on-full pattern).
  # Updates to an existing key never trip the clear.
  defp ensure_capacity(tab, key) do
    if not :ets.member(tab, key) and :ets.info(tab, :size) >= @max_rows do
      :ets.delete_all_objects(tab)
    end

    :ok
  end

  defp lookup_count(key) do
    case table() do
      nil ->
        0

      tab ->
        case :ets.lookup(tab, key) do
          [{^key, n}] -> n
          _ -> 0
        end
    end
  end

  defp lookup_last_error(scope) do
    case table() do
      nil ->
        nil

      tab ->
        case :ets.lookup(tab, {scope, :last_error}) do
          [{_, last}] -> last
          _ -> nil
        end
    end
  end

  defp table do
    case :ets.info(@table) do
      :undefined -> nil
      _ -> @table
    end
  end

  defp emit(kind, scope, meta) do
    measurements = %{count: 1}

    metadata =
      meta
      |> Map.put(:scope, scope)
      |> Map.put(:kind, kind)

    :telemetry.execute([:barkpark, :indx, :retriever, :outcome], measurements, metadata)
  end
end
