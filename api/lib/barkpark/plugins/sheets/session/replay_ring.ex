defmodule Barkpark.Plugins.Sheets.Session.ReplayRing do
  @moduledoc """
  Exactly-once replay ring for `POST /v1/plugins/sheets/:slug/ops` batches.

  A retried ops batch that carries a `"request_id"` must not double-apply its
  non-idempotent ops (a re-sent `insert_rows` running twice is the named
  failure). The session's own retry (`Session.call_session/4`) and the
  controller's 503 path both mean a retried request can land on a FRESH
  session — a session that died twice by construction — so an in-GenServer
  guard is gone exactly when it is needed. The ring therefore lives OUTSIDE
  the sessions: a tiny GenServer owns one public, named ETS table
  (`:sheets_ops_replay`) that survives any individual session restart. Callers
  (the session processes) read and write the table DIRECTLY — this GenServer's
  only job is to own the table so it outlives the sessions.

  ## Contract

  Keyed by `{dataset, published_id}` (the session's own `key/2` shape). Each
  key holds a capped list of `{request_id, reply, monotonic_ms}` entries,
  newest first. `lookup/2` returns `{:ok, reply}` for a known `request_id`
  (the session replays it verbatim + `replayed: true` and applies nothing) or
  `:miss`. `put/3` records a fresh reply after a real application. Per-key
  writes are serialized by the unique `SessionRegistry` (one session per key,
  its mailbox the serializer) so there is no same-key race on the list.

  ## Bounds (accepted residuals — see the `Session` moduledoc)

    * cap 32 entries per sheet (oldest drop);
    * lazy TTL 1h, pruned on write (a stale entry may still replay until the
      next write to its key evicts it — bounded and harmless);
    * NODE-LOCAL: the table is a single-node ETS table (Barkpark is a
      single-node deploy); a BEAM restart clears it (the sessions die with it,
      so a fresh ring is correct);
    * the one-statement window between a session applying a batch and calling
      `put/3` stays at-least-once — a crash there loses the ring entry and the
      next retry re-applies (documented, not fixed).
  """

  use GenServer

  @table :sheets_ops_replay
  @cap 32
  @ttl_ms 3_600_000

  @type key :: {String.t(), String.t()}

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Look up a cached reply for `request_id` under `key`. `{:ok, reply}` when the
  request was already applied on this node since the last ring eviction,
  `:miss` otherwise (including when the ring is not started).
  """
  @spec lookup(key(), String.t()) :: {:ok, map()} | :miss
  def lookup(key, request_id) when is_binary(request_id) do
    case safe_lookup(key) do
      [] ->
        :miss

      list ->
        case List.keyfind(list, request_id, 0) do
          {^request_id, reply, _ts} -> {:ok, reply}
          _ -> :miss
        end
    end
  end

  @doc """
  Record `reply` for `request_id` under `key`. Prunes entries older than the
  1h TTL, drops any prior entry for the same `request_id`, prepends the fresh
  one and caps the list. A no-op (returns `:ok`) if the table is not started.
  """
  @spec put(key(), String.t(), map()) :: :ok
  def put(key, request_id, reply) when is_binary(request_id) and is_map(reply) do
    now = System.monotonic_time(:millisecond)

    updated =
      key
      |> safe_lookup()
      |> Enum.reject(fn {rid, _reply, ts} -> rid == request_id or now - ts > @ttl_ms end)
      |> then(&[{request_id, reply, now} | &1])
      |> Enum.take(@cap)

    safe_insert(key, updated)
    :ok
  end

  # ── ETS access (fail-soft if the ring is somehow not up) ─────────────────

  defp safe_lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, list}] -> list
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  defp safe_insert(key, list) do
    :ets.insert(@table, {key, list})
  rescue
    ArgumentError -> true
  end

  # ── GenServer (table owner only) ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end
end
