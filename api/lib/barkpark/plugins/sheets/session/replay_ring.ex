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
    * KEY CARDINALITY, previously the one unbounded axis in this list. `@cap`
      bounds the list INSIDE a key and `@ttl_ms` prunes entries INSIDE a key,
      lazily and only on the next write TO THAT SAME KEY — so a sheet written
      once left a permanent row holding up to 32 FULL reply maps, and
      `grep -n delete replay_ring.ex` returned nothing: no key eviction, no
      key-count cap, no sweeper. A key's list also never empties (`put/3`
      always prepends after the reject), so the existing logic could not drop
      a key even in principle. Any authenticated caller could mint rows one
      sheet at a time and they lived until the BEAM restarted. A periodic
      sweep now drops keys whose NEWEST entry is already past `@ttl_ms` — see
      `sweep/1`. The sibling that solved this same hole for the undo stacks
      (`Session.Ops.@undo_user_cap`) cites THIS module as its model for
      bounding depth, and bounded key count on its own; the debt ran the other
      way and went unpaid.
    * NODE-LOCAL: the table is a single-node ETS table (Barkpark is a
      single-node deploy); a BEAM restart clears it (the sessions die with it,
      so a fresh ring is correct);
    * the one-statement window between a session applying a batch and calling
      `put/3` stays at-least-once — a crash there loses the ring entry and the
      next retry re-applies (documented, not fixed).
  """

  use GenServer

  require Logger

  @table :sheets_ops_replay
  @cap 32
  @ttl_ms 3_600_000

  # The sweep cadence is DERIVED from the retention it enforces, not picked: a
  # key becomes evictable exactly `@ttl_ms` after its last write, so worst-case
  # residency is `@ttl_ms + one tick`. Four sweeps per TTL holds that at 1.25x
  # the declared retention instead of the 2x a once-per-TTL tick would give, and
  # costs one O(table) `select_delete` per interval — the same cost class as the
  # per-write prune that already runs on every `put/3`.
  @sweep_every_ms div(@ttl_ms, 4)

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

  @doc """
  Drop every key whose NEWEST entry is already past `@ttl_ms`.

  Entries are newest-first, so the head's timestamp is the key's last write: if
  THAT is past the TTL then every entry under the key is, and the next `put/3`
  to it would have rejected all of them anyway. Deleting the row is therefore
  the same outcome the module's own per-write prune reaches — it just no longer
  waits for a write that may never come.

  Returns the number of keys dropped. One `select_delete` pass, projecting no
  payload: the guard reads only `element(3, hd(list))`, so a table full of fat
  reply maps is never copied out to be examined.
  """
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now \\ System.monotonic_time(:millisecond)) do
    cutoff = now - @ttl_ms

    dropped =
      :ets.select_delete(@table, [
        {{:_, :"$1"}, [{:<, {:element, 3, {:hd, :"$1"}}, cutoff}], [true]}
      ])

    if dropped > 0, do: report_sweep(dropped, :ets.info(@table, :size))

    dropped
  rescue
    ArgumentError -> 0
  end

  # Routine hygiene, so :info and once per sweep — never once per key, which
  # would turn a bound into log spam and get it switched off. The CONSEQUENCE is
  # in the line because it is not nothing: a dropped key means a retry carrying
  # a request_id older than the TTL now RE-APPLIES its ops instead of replaying
  # the cached reply. That is what the declared 1h retention always meant; the
  # sweep is what makes it consistently true rather than dependent on whether
  # some later write happened to touch the key.
  defp report_sweep(dropped, remaining) do
    Logger.info(
      "Sheets ReplayRing swept #{dropped} key(s) whose newest cached reply was already " <>
        "past the #{@ttl_ms}ms TTL; #{remaining} key(s) remain. A retry older than the TTL " <>
        "re-applies rather than replays — the declared retention, now uniform."
    )

    :telemetry.execute(
      [:barkpark, :sheets, :replay_ring, :keys_swept],
      %{dropped: dropped, remaining: remaining, ttl_ms: @ttl_ms},
      %{}
    )
  end

  @doc false
  @spec sweep_every_ms() :: pos_integer()
  def sweep_every_ms, do: @sweep_every_ms

  @doc false
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  # ── GenServer (table owner + sweeper) ────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep()
    sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)
end
