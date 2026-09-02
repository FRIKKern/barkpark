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

  Keyed by `{dataset, workspace_id, published_id}` (the session's own `key/3`
  shape — the tenant token joined the key in PR #15215; this line said
  `{dataset, published_id}` until then). Each key holds a capped list of
  `{request_id, reply, monotonic_ms}` entries, newest first. `lookup/2`
  returns `{:ok, reply}` for a known `request_id` (the session replays it
  verbatim + `replayed: true` and applies nothing), `:miss`, or `:unavailable`
  when there is no table to read at all — a THIRD answer, because a miss and a
  missing ring are opposite instructions to the caller and used to be the same
  empty list (see "Ownership" below). `put/3` records a fresh reply after a
  real application. Per-key writes are serialized by the
  unique `SessionRegistry` (one session per key, its mailbox the serializer)
  so there is no same-key race on the list — an INVARIANT, not a property of
  this module, and one a refactor can remove silently. It is asserted, not
  assumed: see the `put/3` comment and
  `test/barkpark/plugins/sheets/replay_ring_single_writer_test.exs`.

  ## Ownership: the ring may die ALONE (heir, not restart)

  The ring is a DIFFERENT process from the sessions — that is the whole point,
  and it was also a hole in the other direction. Kill only this GenServer and
  the table died with its owner while every session kept running: the
  supervisor restarted the ring, `init/1` built a fresh EMPTY table, and the
  next retry of an already-applied `request_id` read `:miss` and re-applied a
  non-idempotent `insert_rows`. `safe_lookup/1`'s `rescue ArgumentError -> []`
  made even the crash window look like an ordinary miss: no log line, no error,
  a silently lost guarantee. Pinned by
  `test/barkpark/sheets/session_ring_crash_test.exs`, which kills the REAL
  supervised process between two identical `request_id`s.

  CHOSEN — (c) HEIR THE TABLE. `Barkpark.Plugins.Sheets.Supervisor` passes its
  own pid as `heir:`, `:ets.new/2` names it in the table options, and ETS hands
  the table to the supervisor at the INSTANT the ring dies. The restarted ring
  finds the table already there and ADOPTS it (see `init/1`) — entries intact,
  sessions undisturbed, nothing client-visible. After a transfer the supervisor
  is the permanent owner and the heir is cleared, which is STRICTLY stronger
  than the starting state: the table is anchored to the most stable process in
  the subtree and can now only die when the whole Sheets subtree does — the
  case where the sessions die with it and a fresh ring IS correct. The
  supervisor logs one "unexpected message" error report per transfer (the
  `{:"ETS-TRANSFER", ...}` notification `:supervisor` has no clause for); it
  does not crash, and the line is a true record of a ring crash. A dedicated
  heir process would suppress that line and let the heir be re-armed on every
  restart; deliberately not built — it buys nothing once the supervisor owns
  the table, and costs a process whose only job is to stay alive.

  REJECTED — (a) supervise the ring and the sessions in one `one_for_all`
  subtree so a ring crash restarts the sessions. Checked rather than assumed:
  it is NOT a data-loss risk — `Session` traps exits and its `terminate/2`
  persists through the full upsert pipeline inside its 30s shutdown, so a
  supervised stop flushes. It is a node-wide, CLIENT-VISIBLE disruption to
  repair a table that never had to be lost: every live sheet on the node is
  stopped, and because sessions are `restart: :temporary` they do not come
  back. Each editor's rev counter, `epoch`, undo/redo stacks and cross-tab
  index go with them; the next request rebuilds from the persisted row under a
  new incarnation stamp. Blast radius: every editor on the node. (c)'s blast
  radius is nobody.

  REJECTED AS THE SOLE REMEDY — (b) refuse the batch when the ring is
  unreachable. It cannot rescue the crash case at all: the table is genuinely
  gone there, so every retry carrying an in-flight `request_id` is refused
  until the ring restarts — (b) alone converts a silent double-apply into a
  guaranteed outage window. It is KEPT as the BACKSTOP for what (c) cannot
  cover (a table deleted outright, or a caller reaching the ring before it has
  ever started), because "refuse" is the only fail-CLOSED answer once the ring
  is truly unreachable: `lookup/2` returns `:unavailable`, the session replies
  `{:error, :replay_unavailable}`, and both rescues log at `:error` NAMING THE
  KEY. The silence was the actual defect — a fail-soft `[]` that reads as
  "miss" is indistinguishable from "never applied".

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
      so a fresh ring is correct). A restart of THIS GenServer alone no longer
      clears it — see "Ownership" above;
    * the one-statement window between a session applying a batch and calling
      `put/3` stays at-least-once — a crash there loses the ring entry and the
      next retry re-applies (documented, not fixed).
  """

  use GenServer

  require Logger

  @table :sheets_ops_replay
  @cap 32
  @ttl_ms 3_600_000

  # Carried in the `{:"ETS-TRANSFER", tab, from_pid, heir_data}` notification so
  # the supervisor's "unexpected message" error report names the subsystem that
  # sent it instead of showing a bare table reference.
  @heir_data :sheets_ops_replay_ring_crashed

  # The sweep cadence is DERIVED from the retention it enforces, not picked: a
  # key becomes evictable exactly `@ttl_ms` after its last write, so worst-case
  # residency is `@ttl_ms + one tick`. Four sweeps per TTL holds that at 1.25x
  # the declared retention instead of the 2x a once-per-TTL tick would give, and
  # costs one O(table) `select_delete` per interval — the same cost class as the
  # per-write prune that already runs on every `put/3`.
  @sweep_every_ms div(@ttl_ms, 4)

  @type key :: {String.t(), String.t() | nil, String.t()}

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Look up a cached reply for `request_id` under `key`. `{:ok, reply}` when the
  request was already applied on this node since the last ring eviction,
  `:miss` when the ring is readable and holds no such entry, and
  `:unavailable` when there is no table to read — the caller must REFUSE the
  batch in that case, never treat it as a miss.
  """
  @spec lookup(key(), String.t()) :: {:ok, map()} | :miss | :unavailable
  def lookup(key, request_id) when is_binary(request_id) do
    case safe_lookup(key) do
      # NOT a miss. There is no ring to have missed in, so "this request_id was
      # never applied" is a claim this function cannot make; the caller must
      # refuse rather than re-apply. Conflating the two is what made the crash
      # silent.
      :unavailable ->
        :unavailable

      {:ok, []} ->
        :miss

      {:ok, list} ->
        case List.keyfind(list, request_id, 0) do
          {^request_id, reply, _ts} -> {:ok, reply}
          _ -> :miss
        end
    end
  end

  @doc """
  Record `reply` for `request_id` under `key`. Prunes entries older than the
  1h TTL, drops any prior entry for the same `request_id`, prepends the fresh
  one and caps the list. Returns `:unavailable` (after an `:error` log naming
  the key) when there is no table to write: the batch has ALREADY been applied
  by then, so this is at-least-once by construction and the log is the only
  honest remedy left.
  """
  # ── THE SINGLE-WRITER FENCE (read this before moving this call) ──────────
  #
  # The read-modify-write below is on a PUBLIC ETS table:
  # `safe_lookup` (`:ets.lookup`) -> reject/prepend/take -> `safe_insert`
  # (an unconditional `:ets.insert`). Nothing in ETS makes that atomic. It is
  # correct today for a reason that lives in ANOTHER module, which is exactly
  # why it is written down here:
  #
  #   the ONLY caller is `Session.handle_call({:apply_ops, ops, request_id}, ...)`,
  #   and `Barkpark.Plugins.Sheets.SessionRegistry` is `keys: :unique`, so at
  #   most ONE live process exists per `{dataset, workspace_id, published_id}`
  #   — the same tuple as the ring key. That process's mailbox, not ETS, is
  #   the serializer.
  #
  # Move this call into a `Task`, a `spawn`, a `handle_cast` that can overtake,
  # or add any second writer to `:sheets_ops_replay`, and exactly-once breaks
  # with a fully green suite. `replay_ring_single_writer_test.exs` is what
  # stops that: it traces the actual `put/3` call and asserts the executing pid
  # IS the pid `Registry.lookup/2` returns for the key, and it walks the AST of
  # `api/lib` to assert there is exactly one call site and it is not nested in
  # a spawn-like construct.
  #
  # THE MEASURED SHAPE, so a later reader does not re-run it blind: 32
  # barrier-released writers on ONE key over 200 rounds lost entries in 200/200
  # rounds (2249 total, up to 13 in a round), while 16 writers returned a clean
  # green — the harness only sees the race above a threshold, so a quiet
  # 16-writer run is NOT evidence of safety. The harness is KEPT, behind the
  # `SHEETS_REPLAY_RING_RACE=1` compile gate in that same test file, so the
  # measurement is re-runnable instead of folklore. It never runs in CI: it is a
  # documented measurement, not a gate, and a load-sensitive one at that.
  #
  # REPLICATED 2026-09-02 on a 10-core Apple Silicon box, Elixir 1.19.5 / OTP 28,
  # same harness: 32 writers -> 173/200 rounds lossy, 2123 lost, worst round 22.
  # The lost-update behaviour reproduces. The "16 writers is clean" LEG DOES NOT:
  # 16 writers lost on 74/200 rounds (290 entries, worst round 8) on this box.
  # So the threshold is a property of the MACHINE AND ITS LOAD, not of the writer
  # count — which sharpens the original point rather than softening it. A quiet
  # run at any writer count is evidence about that box at that moment and nothing
  # more; only the fence is evidence about correctness.
  #
  # A lost put is not cosmetic: the next retry of that `request_id` reads
  # `:miss` and re-applies a non-idempotent `insert_rows` — the double-apply
  # this module exists to stop.
  #
  # WHY THE FENCE CANNOT LEAK A SECOND WRITER (version-scoped, not eternal):
  # the "registry restarts empty while old sessions live on unregistered"
  # overlap is refuted by mechanism — `Registry` LINKS every registrant to its
  # partition process, so a partition crash KILLS its registrants and the
  # "alive but unregistered" state that would admit a second writer cannot
  # occur. VERIFIED ON Elixir 1.19.5 / OTP 28 (the dev box this was written on)
  # and on the repo's declared toolchain, root `.tool-versions`
  # `elixir 1.18.4-otp-27` / CI `elixir.yml` test matrix `otp 27.0`,
  # `elixir 1.18.1`. It is a Registry implementation property, NOT a documented
  # guarantee, so the verdict flips if a future version stops linking — which
  # is why the single-writer test re-derives it on every run under whatever
  # toolchain runs it, instead of trusting this paragraph.
  @spec put(key(), String.t(), map()) :: :ok | :unavailable
  def put(key, request_id, reply) when is_binary(request_id) and is_map(reply) do
    now = System.monotonic_time(:millisecond)

    case safe_lookup(key) do
      :unavailable ->
        :unavailable

      {:ok, list} ->
        updated =
          list
          |> Enum.reject(fn {rid, _reply, ts} -> rid == request_id or now - ts > @ttl_ms end)
          |> then(&[{request_id, reply, now} | &1])
          |> Enum.take(@cap)

        safe_insert(key, updated)
    end
  end

  # ── ETS access (fail-LOUD if the ring is somehow not up) ─────────────────
  #
  # These two rescues used to return `[]` and `true`: a missing table was
  # reported as an empty ring, which `lookup/2` then reported as a miss, which
  # the session read as "never applied" and re-applied. Three layers, each
  # locally reasonable, adding up to a silently broken exactly-once guarantee.
  # They now return `:unavailable` and say so at `:error` with the key, and the
  # session refuses. An `ArgumentError` here is the ONLY failure ETS raises for
  # a table that is not there, so it is still rescued rather than allowed to
  # kill the calling SESSION — losing a live sheet to prove a point about the
  # ring would repeat mistake (a).

  defp safe_lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, list}] -> {:ok, list}
      [] -> {:ok, []}
    end
  rescue
    ArgumentError ->
      report_unavailable(:lookup, key)
      :unavailable
  end

  defp safe_insert(key, list) do
    :ets.insert(@table, {key, list})
    :ok
  rescue
    ArgumentError ->
      report_unavailable(:insert, key)
      :unavailable
  end

  # Named at `:error` because this line is the whole difference between a bug
  # that is found and one that is not: it is emitted at most once per affected
  # request, carries the ring key, and states the consequence rather than the
  # symptom.
  defp report_unavailable(op, key) do
    Logger.error(
      "Sheets ReplayRing #{op} found no #{inspect(@table)} table for ring key " <>
        "#{inspect(key)} — the exactly-once ring is UNAVAILABLE. A retry carrying this " <>
        "request_id can no longer be recognised, so the session refuses the batch " <>
        "({:error, :replay_unavailable}) instead of re-applying non-idempotent ops. " <>
        "The table normally survives a ring crash via its heir; if this fires, the table " <>
        "was deleted or the ring never started."
    )

    :telemetry.execute(
      [:barkpark, :sheets, :replay_ring, :unavailable],
      %{count: 1},
      %{op: op, key: key}
    )
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
    ArgumentError ->
      report_unavailable(:sweep, :whole_table)
      0
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
  def init(opts) do
    opts = if is_list(opts), do: opts, else: []
    adopt_or_create_table(Keyword.get(opts, :heir))

    schedule_sweep()

    {:ok, %{}}
  end

  # Two legal states, and the difference between them is a crash:
  #
  #   * no table  -> this is a cold start. Create it, naming the heir the
  #     supervisor handed us so the NEXT crash of this process does not take the
  #     table with it.
  #   * a table   -> we are a RESTART and the heir kept the table alive across
  #     our death. Adopt it: calling `:ets.new/2` here would raise
  #     `ArgumentError` on the already-taken name and crash-loop the ring,
  #     and even if it did not, a fresh table is exactly the empty ring this
  #     whole section exists to prevent.
  #
  # `heir` is `nil` only when the ring is started outside
  # `Barkpark.Plugins.Sheets.Supervisor` (a test starting it standalone). No
  # heir is then set and the pre-fix lifetime applies — which is why the crash
  # test drives the REAL supervised singleton.
  defp adopt_or_create_table(heir) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(
          @table,
          [
            :named_table,
            :set,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ] ++ heir_opt(heir)
        )

        :created

      _tid ->
        Logger.warning(
          "Sheets ReplayRing restarted and ADOPTED the surviving #{inspect(@table)} table " <>
            "(#{:ets.info(@table, :size)} key(s), now owned by " <>
            "#{inspect(:ets.info(@table, :owner))}) — the ring process crashed but its " <>
            "heir kept the table, so exactly-once held across the restart."
        )

        :adopted
    end
  end

  defp heir_opt(pid) when is_pid(pid), do: [{:heir, pid, @heir_data}]
  defp heir_opt(_none), do: []

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep()
    sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)
end
