defmodule Barkpark.Plugins.Sheets.Session do
  @moduledoc """
  Per-sheet collaborative session (M1) — a GenServer that owns one sheet
  document's content in memory and serializes cell-granular ops against it.

  CORE, plugin-independent (fresh-install invariant): sessions work with the
  Sheets plugin off — only the HTTP ops route
  (`POST /v1/plugins/sheets/:slug/ops`) is plugin wiring. Direct
  `/v1/data/mutate` writes keep working without a session.

  ## Lifecycle

  Started LAZILY on the first op via `apply_ops/3` — a `DynamicSupervisor`
  (`Barkpark.Plugins.Sheets.SessionSupervisor`) child keyed in
  `Barkpark.Plugins.Sheets.SessionRegistry` by `{dataset, published-id}`. `init/1`
  reads the persisted row ONCE (draft-first, published fallback — the same
  precedence the export controller uses); while the session lives, its
  memory is authoritative. The process hibernates when idle
  (`:hibernate_after`) and stops itself after `idle_stop_ms` without calls;
  `terminate/2` persists any unflushed state (exits are trapped so a
  supervisor shutdown reaches it). On a NON-graceful BEAM death (kill -9,
  OOM, power loss) up to `debounce_ms`/`flush_after_ops` worth of
  acknowledged-but-unpersisted ops are lost by design.

  ## Ops (v1)

  String-keyed maps, the wire shape. Cell ops:

    * `%{"op" => "set_cell", "tab" => i, "ref" => "A1", "raw" => raw}` —
      `raw` is a scalar; a string with a leading `"="` is a formula (the
      importer convention) and stores as `%{"f" => <without "=">}`, anything
      else stores as `%{"v" => raw}`. A string or formula whose byte length
      exceeds Excel's 32,767-char cell limit is rejected (`value_too_large`).
      Retyping a cell PRESERVES its prior `"fmt"`/`"s"`; an OPTIONAL `"fmt"`
      (a `Barkpark.Plugins.Sheets.Fmt` class, or `null` to clear —
      `invalid_fmt` otherwise) and/or `"s"` (a style map, or `null` to clear
      — `invalid_style` otherwise) on the op OVERRIDE that carry (fill stamps
      the source cell's format onto every target). A `ref` a merge COVERS
      (inside a `merges` range but not its anchor) is rejected (`merged_cell`).
    * `%{"op" => "clear_cell", "tab" => i, "ref" => "A1"}`
    * `%{"op" => "set_cell_meta", "tab" => i, "ref" => "A1", "fmt" => …?, "s" => …?}`
      — display-only: stamps "fmt" (a `Barkpark.Plugins.Sheets.Fmt` class, or
      `null` to clear) and/or "s" (a STRICT style map — `b`/`i` boolean, `al`
      left|center|right, `bg` #rrggbb — or `null` to clear) onto the EXISTING
      cell WITHOUT re-parsing its value (never coerces "0123"→123). An absent
      key is a no-op; an empty "s" map clears "s". Formatting an EMPTY cell is
      refused (`empty_cell`); a merge-covered ref is refused (`merged_cell`).

  Structural ops (the grid editor) — Excel ref-shift semantics live in
  `Barkpark.Plugins.Sheets.Structure` (cell keys shift, formula refs/ranges
  rewrite — dead refs become the literal `#REF!` — merges shift/clip/drop,
  `col_widths`/`row_heights` re-key, frozen bands clamp), then the op's
  tab recomputes through the engine:

    * `%{"op" => "insert_rows"|"delete_rows"|"insert_cols"|"delete_cols",
      "tab" => i, "at" => n, "count" => n}` — 1-based `at`; an insert that
      would push occupied cells past the grid bounds errors
      (`grid_bounds_exceeded`).
    * `%{"op" => "set_col_width", "tab" => i, "col" => n, "px" => px|nil}`
      and `%{"op" => "set_row_height", "tab" => i, "row" => n, "px" => px|nil}`
      — `nil` clears the entry.
    * `%{"op" => "set_frozen", "tab" => i, "rows" => n, "cols" => n}` —
      freezes the top `rows`/left `cols` bands (non-negative ints); a `0`
      band clears its key (`invalid_frozen` on a negative/non-integer).
    * `%{"op" => "rename_tab", "tab" => i, "name" => s}`,
      `%{"op" => "add_tab", "name" => s}` (appends an empty tab), and
      `%{"op" => "delete_tab", "tab" => i}` — deleting the LAST tab is
      refused (`last_tab`).
    * `%{"op" => "move_tab", "from" => i, "to" => j}` — reorders a tab
      (both indices must exist; `from == j` is a no-op). A pure permutation,
      so it recomputes nothing; the `:structure` delta carries `from`/`to`
      for the client to remap its view.
    * `%{"op" => "duplicate_tab", "tab" => i}` — inserts a deep copy of tab
      `i` at `i + 1`, named `"Copy of <name>"` (deduped case-insensitively
      with ` 2`/` 3`… suffixes). The copy's non-empty cells count against
      the session cap FIRST (`cell_cap_exceeded`) — the cap is session-total
      but historically only `set_cell` enforced it.
    * `%{"op" => "merge_cells", "tab" => i, "range" => "A1:B3"}` and
      `%{"op" => "unmerge_cells", "tab" => i, "range" => "A1:B3"}` — merge
      adds a canonical (normalized, ordered) range to the tab's `merges`
      list, rejecting a single-cell range (`merge_degenerate`), one past
      the grid bounds (`merge_out_of_bounds`), one over the 10,000-cell area
      cap (`merge_area_exceeded`), or one overlapping an existing merge
      (`merge_overlap`); unmerge drops every merge whose rect intersects the
      range (`no_merge_in_range` when none does). V1 is NON-destructive —
      covered cells keep their data, so an unmerge restores every value.
    * `%{"op" => "set_cond_format", "tab" => i, "rules" => [rule, …]}` —
      replaces the tab's WHOLE `cond_formats` list (CF-C). Each rule is
      `%{"id","range","when"=>%{"op","value",…},"style"=>%{"bg",…}}`; the list
      is validated with byte-identical strictness to the plugin's before_save
      gate (`Barkpark.Plugins.Sheets.cond_format_list_errors/2`, CF-D6) so a
      session-accepted rule can never strand the debounced persist (CF-AM1) —
      an invalid list is rejected whole (`invalid_cond_format`). No recompute
      (rules change render style, never a cell value); the inverse restores the
      prior list.
    * `%{"op" => "sort_range", "tab" => i, "range" => "A2:D50",
      "keys" => [%{"col" => 0, "dir" => "asc"}, …]}` — sorts the range's rows
      in place (SF-A): a PURE row permutation that moves every cell map
      VERBATIM — `f` is NEVER rewritten, so a sorted `=A1` still reads `=A1`
      (Excel semantics, SF-D1). `keys` are absolute 0-based column indexes
      inside the range, evaluated left-to-right (multi-key); the comparator
      reads the computed `v` on the total ladder num < text(ci) < FALSE <
      TRUE < errors(equal) < blanks(last, both directions) — a DELIBERATE
      cross-type divergence from the engine (SF-D4). A merge intersecting the
      range refuses (`sort_merge_overlap`), a range reaching the frozen head
      band refuses (`sort_frozen_overlap`), malformed keys refuse
      (`invalid_sort_keys`), a range past the grid bounds refuses
      (`sort_out_of_bounds`). The tab RECOMPUTES afterwards (the insert/delete
      precedent) so moved formulas refresh; an already-sorted range is a
      no-op. The inverse is the exact inverse permutation.

  Validation per op: the ref must be A1-style within the Excel grid bounds,
  the tab index must exist, and a `set_cell` that would push the sheet past
  the non-empty-cell cap errors (`cell_cap_exceeded`). Invalid ops are
  REJECTED INDIVIDUALLY — the rest of the batch still applies. A single
  `apply_ops/3` call carries at most 1_000 ops — beyond that the whole
  call is refused (`{:error, :batch_too_large, n}`) before it reaches the
  mailbox; large legitimate batches (grid pastes, big clears) chunk at the
  caller. The mailbox is the serializer: concurrent callers' ops interleave
  whole, last write wins per cell — structural ops ride the same mailbox,
  so a batch never observes a half-shifted grid.

  ## Idempotency (request_id replay ring)

  `apply_ops/4` takes an OPTIONAL `request_id` (a non-empty string ≤ 200
  bytes, shape-validated at the controller — `invalid_request_id` 422
  otherwise). The FIRST batch with a given `request_id` applies normally and
  caches its reply in `Barkpark.Plugins.Sheets.Session.ReplayRing` (a public
  named ETS table owned by a tiny GenServer OUTSIDE the sessions); a LATER
  batch with the SAME `request_id` replays that cached reply verbatim +
  `replayed: true` and applies NOTHING. That is what makes a retried
  non-idempotent batch (an `insert_rows` re-sent after a lost response or a
  503) apply EXACTLY ONCE. The ring lives outside the session on purpose: a
  503 means the session died twice, so the retry lands on a FRESH session — an
  in-GenServer guard would be gone exactly when needed. `request_id: nil` (the
  `apply_ops/3` default) is byte-identical to the pre-ring behavior: every call
  applies. Same `request_id` with DIFFERENT ops returns the FIRST reply
  (idempotency-key semantics — the caller owns the key). Accepted residuals,
  NOT fixed:

    * NODE-LOCAL — the ring is a single-node ETS table (Barkpark is a
      single-node deploy);
    * a BEAM restart clears the ring (the sessions die with it, so a fresh
      empty ring is correct);
    * the one-statement window between applying the batch and the ring `put`
      stays at-least-once — a crash there loses the entry and the next retry
      re-applies.

  ## Per-user undo/redo (M4)

  Any op may carry an optional `"user"` string — when present, the session
  records the op's INVERSE onto that user's undo stack (depth 100, oldest
  entries drop): `set_cell`/`clear_cell` store the prior cell map; `insert_*` store
  the matching `delete_*`; `delete_*` store the matching `insert_*` PLUS the
  deleted span's captured cells; `set_col_width`/`set_row_height` store the
  prior px; `set_frozen` the prior bands; `rename_tab` the prior name; `add_tab` its `delete_tab`;
  `delete_tab` the captured tab; `move_tab`/`duplicate_tab` their inverse
  (a mirrored `move_tab` / a `delete_tab` of the inserted slot);
  `set_cond_format` the prior `cond_formats` list (a structural set_cond_format);
  `sort_range` the EXACT inverse row permutation (`{:permute, …}` — verbatim
  moves both ways, loss-free);
  `merge_cells` a GRANULAR remove of just the range it added and `unmerge_cells`
  a granular re-add of just the ranges it dropped (skipping any a later op has
  re-covered — a re-added merge may land at pre-shift coordinates, the same
  lossy contract as `delete_*` undo), never a whole-list snapshot that would
  clobber another user's merges. Undo/redo arrive as
  ops through the same mailbox:

    * `%{"op" => "undo", "user" => u}` — pops u's undo stack, applies the
      inverse, pushes ITS inverse onto u's redo stack.
    * `%{"op" => "redo", "user" => u}` — the mirror image.

  Empty stacks reject per-op (`nothing_to_undo`/`nothing_to_redo`); any new
  own-op clears that user's redo stack. The applied inverse rides the
  normal recompute + delta path, so every client re-renders. Undoing
  something another user already overwrote just applies the inverse —
  Google Sheets semantics: it may overwrite their newer value (documented;
  LWW stands). Formula refs a `delete_*` rewrote to the literal `#REF!`
  are NOT restored by its undo (the rewrite is lossy by design).

  Every inverse entry pins an ABSOLUTE tab index, so a reorder (`move_tab`),
  an insert (`duplicate_tab` or a `tab_restore` undo), or a delete
  (`delete_tab`) remaps EVERY user's undo AND redo stacks by the same
  permutation the tabs underwent — without it a later undo would land on the
  wrong tab (a silent cross-user corruption). An entry pinned to the deleted
  tab ITSELF is deliberately kept un-remapped: it surfaces as a consumed
  dead entry at undo time, keeping the history behind it reachable.

  ## Recompute + delta broadcast

  The session recomputes each touched tab through
  `Barkpark.Plugins.Sheets.Engine` (formulas are tab-local, so other tabs cannot
  change; tabs holding NO formula cell skip the engine entirely — a
  per-tab formula count keeps the common bulk-import case O(1) per op,
  since a full recompute measures ~70–90ms at the 50_000-cell cap). Within
  an `apply_ops` batch the cell ops (`set_cell`/`clear_cell`/`set_cell_meta`)
  COALESCE: each writes its raw cell immediately but defers the recompute
  and the delta to a single per-tab flush at the batch boundary (and before
  any structural/undo op, which forces the flush so it starts from a
  recomputed grid) — so a 1000-op paste into a formula tab is ONE recompute,
  not 1000. Each dirty tab then broadcasts a compact delta:

      {:sheets_op, %{sheet_id: pubid, rev: n, tab: i, changed: %{"A1" => cell | nil, …}}}

  on `topic/3` — the existing `Content.doc_topic/4` SUFFIXED with
  `":sheets:op"`, so every existing doc-topic subscriber is unaffected.
  `rev` is the session's applied-op counter — monotonic WITHIN a session
  incarnation only (a restarted session re-counts from 0); the payload's
  `epoch` stamp disambiguates incarnations. `changed` carries
  EVERY cell whose stored map changed (recompute dependents included),
  `nil` marking a removal. A structural op may produce a LARGE `changed`
  (every shifted cell appears under both its old key, as `nil`, and its
  new key) — its delta therefore also carries
  `structure: %{op: s, at: n | nil, count: n | nil, tab: i}` so clients
  can re-key locally instead of replaying the map. A `sort_range` structure
  ALSO carries `rect: {c1, r1, c2, r2}` and `perm: [new-position, …]` (the
  applied old-row-offset → new-position permutation, SF-AM3) so a collaborator
  with a selection/editor inside the sorted rect remaps its coordinates
  instead of clobbering with stale ones.

  ## Persistence

  DEBOUNCED through the canonical `Content.upsert_document/4` path (engine
  recompute, revisions, write-through embed snapshots and the standard
  broadcasts all ride along): after `debounce_ms` without further ops OR
  every `flush_after_ops` ops, whichever first — and on terminate. Reads
  outside the session (GET endpoints, exports) may serve the last persisted
  row; `flush/2` is the cheap pre-read barrier (the export controller calls
  it — a no-op when no session is live). A flush whose persist FAILS
  surfaces `{:error, reason}` to the caller — the state stays dirty and the
  debounce retry stays armed, so read-your-writes never silently serves the
  stale row. A direct mutate to the same sheet
  while a session lives is a DOCUMENTED conflict: the session detects the
  external rev change at persist time, logs a warning, and its persist wins
  (full conflict handling is M4 territory).

  ## Configuration

  `config :barkpark, Barkpark.Plugins.Sheets.Session, …` — `debounce_ms` (2_000),
  `flush_after_ops` (25), `idle_stop_ms` (300_000), `hibernate_after`
  (15_000), `cell_cap` (50_000, mirroring the plugin gate's import cap).
  Read at session start; tests override via `Application.put_env/3`.
  """

  # `shutdown: 30_000`: terminate persists through the FULL upsert pipeline
  # (engine recompute + revision insert + write-through embed snapshots) —
  # the 5s worker default races a big-sheet flush during a deploy shutdown
  # and the supervisor would brutal-kill mid-persist, losing the
  # acknowledged tail.
  use GenServer, restart: :temporary, shutdown: 30_000

  require Logger

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session.Ops
  alias Barkpark.Plugins.Sheets.Session.ReplayRing

  @registry Barkpark.Plugins.Sheets.SessionRegistry
  @supervisor Barkpark.Plugins.Sheets.SessionSupervisor

  @call_timeout 30_000

  # Per-call batch bound: one apply_ops call carries at most this many ops.
  # Refused outright ({:error, :batch_too_large, n}) before the call reaches
  # the session mailbox — the 50k cell cap and the 30s call timeout are the
  # only other bounds, and neither stops a pathological million-op list.
  # Large legitimate batches chunk at the caller (SheetGrid.send_ops/2).
  @max_ops_per_call 1_000

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Apply `ops` (a list of wire-shaped op maps, see the moduledoc) to the
  sheet at `slug` in `dataset`, resolving-or-starting the session.

  Returns `{:ok, %{rev: n, applied: n, errors: [%{index:, code:, message:}]}}`,
  `{:error, :not_found}` when no sheet resolves for the slug,
  `{:error, :batch_too_large, n}` when `ops` exceeds `max_ops_per_call/0`,
  or `{:error, :session_unavailable}` when the session died twice in a row
  (see `call_session/4`).

  ## Exactly-once retry (`request_id`)

  An OPTIONAL fourth argument `request_id` (a non-empty string, validated at
  the controller layer) makes the batch idempotent under retry. The FIRST
  call with a given `request_id` applies the batch and caches its reply in the
  restart-surviving `ReplayRing`; a LATER call with the SAME `request_id`
  replays the cached reply verbatim + `replayed: true` and applies NOTHING —
  so a re-sent `insert_rows` batch (e.g. after a lost response or a 503) never
  double-applies. `request_id: nil` (the default, and the `apply_ops/3`
  contract) is byte-identical to the pre-ring behavior: every call applies.
  Same `request_id` with DIFFERENT ops returns the FIRST reply (idempotency-key
  semantics — the caller committed to that key). See the moduledoc's
  "Idempotency (request_id replay ring)" section for the accepted residuals.
  """
  @spec apply_ops(String.t(), String.t(), [map()], String.t() | nil) ::
          {:ok, %{rev: non_neg_integer(), applied: non_neg_integer(), errors: [map()]}}
          | {:error, term()}
          | {:error, :batch_too_large, pos_integer()}
  def apply_ops(slug, dataset, ops, request_id \\ nil)
      when is_binary(slug) and is_binary(dataset) and is_list(ops) and
             (is_nil(request_id) or is_binary(request_id)) do
    case length(ops) do
      n when n > @max_ops_per_call -> {:error, :batch_too_large, n}
      _ -> call_session(slug, dataset, {:apply_ops, ops, request_id})
    end
  end

  @doc "The per-call `apply_ops/3` batch bound — callers chunk above it."
  @spec max_ops_per_call() :: pos_integer()
  def max_ops_per_call, do: @max_ops_per_call

  @doc """
  Ask a LIVE session to persist its unflushed state — the read-your-writes
  barrier for exports and GETs. Never starts a session: a no-op `:ok` when
  none is registered (or it stopped concurrently). `{:error, reason}` when
  the persist itself failed — the session keeps its dirty state and the
  debounce retry stays armed, so callers must NOT serve the stale row as
  fresh (the export controller maps this to a 503 with a retry hint).
  """
  @spec flush(String.t(), String.t()) :: :ok | {:error, term()}
  def flush(slug, dataset) do
    case whereis(slug, dataset) do
      nil -> :ok
      pid -> safe_call(pid, :flush)
    end
  end

  @doc """
  The session's in-memory content (authoritative while it lives).
  `{:error, :no_session}` when none is live — this never starts one.
  """
  @spec peek(String.t(), String.t()) :: {:ok, map()} | {:error, :no_session}
  def peek(slug, dataset) do
    case whereis(slug, dataset) do
      nil -> {:error, :no_session}
      pid -> GenServer.call(pid, :peek, @call_timeout)
    end
  end

  @doc """
  Stop a live session (normal shutdown — `terminate/2` persists any dirty
  state). A no-op when none is registered.
  """
  @spec stop(String.t(), String.t()) :: :ok
  def stop(slug, dataset) do
    case whereis(slug, dataset) do
      nil -> :ok
      pid -> safe_stop(pid)
    end
  end

  @doc "The live session pid for `{slug, dataset}`, or `nil`."
  @spec whereis(String.t(), String.t()) :: pid() | nil
  def whereis(slug, dataset) do
    case Registry.lookup(@registry, key(slug, dataset)) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  The delta-broadcast topic for a sheet: `Content.doc_topic/4` suffixed with
  `":sheets:op"` — a SIBLING of the doc topic, so existing doc-topic
  subscribers never see session deltas. Subscribers receive
  `{:sheets_op, payload}` (see the moduledoc for the payload shape).
  """
  @spec topic(String.t(), String.t(), String.t() | nil) :: String.t()
  def topic(slug, dataset, workspace_id) do
    Content.doc_topic(Content.published_id(slug), "sheet", workspace_id, dataset) <> ":sheets:op"
  end

  @doc """
  The grid-presence topic for a sheet (M4) — keyed exactly like `topic/3`
  but suffixed with `":sheets:presence"`, so cursor/selection presence
  diffs never interleave with op deltas. Editors track here via
  `BarkparkWeb.Presence` with
  `%{name, color, tab, active, selection, editing, joined_at}` metas.
  """
  @spec presence_topic(String.t(), String.t(), String.t() | nil) :: String.t()
  def presence_topic(slug, dataset, workspace_id) do
    Content.doc_topic(Content.published_id(slug), "sheet", workspace_id, dataset) <>
      ":sheets:presence"
  end

  @doc false
  def start_link({dataset, pubid} = session_key) when is_binary(dataset) and is_binary(pubid) do
    GenServer.start_link(__MODULE__, session_key,
      name: {:via, Registry, {@registry, session_key}},
      hibernate_after: config().hibernate_after
    )
  end

  # ── resolve-or-start + call plumbing ─────────────────────────────────────

  defp key(slug, dataset), do: {dataset, Content.published_id(slug)}

  defp call_session(slug, dataset, msg, retry? \\ true) do
    with {:ok, pid} <- ensure_session(slug, dataset) do
      try do
        GenServer.call(pid, msg, @call_timeout)
      catch
        # The session idled out (or crashed) between lookup and call —
        # restart it once; its state reloads from the persisted row. A
        # SECOND death in the same window is NOT retried (a crash-looping
        # session must not become an infinite loop): the caller gets a
        # clean error tuple instead of the raw exit.
        :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal, :shutdown] ->
          if retry? do
            call_session(slug, dataset, msg, false)
          else
            {:error, :session_unavailable}
          end
      end
    end
  end

  defp ensure_session(slug, dataset) do
    session_key = key(slug, dataset)

    case Registry.lookup(@registry, session_key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, session_key}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp safe_call(pid, msg) do
    GenServer.call(pid, msg, @call_timeout)
  catch
    :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal, :shutdown] -> :ok
  end

  defp safe_stop(pid) do
    GenServer.stop(pid, :normal, @call_timeout)
  catch
    :exit, _ -> :ok
  end

  # ── GenServer ────────────────────────────────────────────────────────────

  @impl true
  def init({dataset, pubid}) do
    # Trap exits so a supervisor shutdown runs terminate/2 (the dirty-state
    # persist) instead of killing the process outright.
    Process.flag(:trap_exit, true)

    case load_doc(pubid, dataset) do
      {:ok, doc} ->
        content = doc.content || %{}

        {:ok,
         schedule_idle(%{
           slug: pubid,
           dataset: dataset,
           title: doc.title,
           workspace_id: doc.workspace_id,
           content: content,
           rev: 0,
           # Incarnation stamp: rev restarts at 0 with every new session
           # process, so clients must be able to tell "same counter, new
           # incarnation" apart from a stale frame. Wall-clock microseconds
           # (NOT unique_integer — that also restarts with the BEAM, the
           # exact case this disambiguates) — two incarnations of the same
           # sheet cannot init in the same microsecond.
           epoch: System.system_time(:microsecond),
           persisted_doc_id: doc.doc_id,
           persisted_rev: doc.rev,
           dirty?: false,
           ops_since_flush: 0,
           # Batch-scoped: tab_idx => the tab's cells BEFORE the current batch
           # first touched it. Cell ops defer their recompute+broadcast here;
           # flush_pending/1 settles each dirty tab once at the batch boundary.
           # Always drained back to %{} before handle_call returns.
           dirty_tabs: %{},
           flush_timer: nil,
           idle_timer: nil,
           nonempty: Ops.count_nonempty(content),
           formula_counts: Ops.count_formulas(content),
           undo: %{},
           redo: %{},
           cfg: config()
         })}

      {:error, :not_found} ->
        {:stop, :not_found}
    end
  end

  @impl true
  def handle_call({:apply_ops, ops, request_id}, _from, state) do
    ring_key = {state.dataset, state.slug}

    case request_id && ReplayRing.lookup(ring_key, request_id) do
      {:ok, cached} ->
        # Exactly-once: this request_id already applied on this node. Replay
        # the cached reply verbatim (+ replayed: true) and apply NOTHING, so a
        # retried non-idempotent batch (insert_rows) never runs twice.
        {:reply, {:ok, Map.put(cached, :replayed, true)}, schedule_idle(state)}

      _ ->
        {reply, state} = do_apply_ops(ops, state)
        if request_id, do: ReplayRing.put(ring_key, request_id, reply)
        {:reply, {:ok, reply}, schedule_idle(state)}
    end
  end

  # The flush reply carries the persist result — a failed persist must not
  # read as :ok, or read-your-writes callers (export) silently serve the
  # stale row. The error branch of persist_result/1 keeps the state dirty
  # and the debounce retry armed.
  def handle_call(:flush, _from, state) do
    {result, state} = persist_result(state)
    {:reply, result, schedule_idle(state)}
  end

  def handle_call(:peek, _from, state) do
    {:reply, {:ok, state.content}, schedule_idle(state)}
  end

  # The real batch application — unchanged from the pre-ring path. Returns the
  # reply map (WITHOUT the additive `replayed` flag; the replay path adds it)
  # plus the settled state, so the caller can ring-cache the reply before
  # replying to the client.
  defp do_apply_ops(ops, state) do
    {state, applied, errors} =
      ops
      |> Enum.with_index()
      |> Enum.reduce({state, 0, []}, fn {op, index}, {st, n, errs} ->
        # Coalesced recompute: cell ops defer their per-op recompute+broadcast
        # to a single per-tab flush; any other op (structural, undo/redo) first
        # settles the pending cell edits so it observes — and broadcasts from —
        # a fully recomputed grid.
        st = if Ops.cell_op?(op), do: st, else: Ops.flush_pending(st)

        case Ops.apply_one(op, st) do
          {:ok, st, inverse} ->
            {Ops.record_undo(st, op, inverse), n + 1, errs}

          {:error, code, message} ->
            {st, n, [%{index: index, code: code, message: message} | errs]}

          # A failed undo/redo consumes its dead entry (apply_history pops it
          # and returns the advanced state) but does NOT count as applied and
          # is NOT pushed to the opposite stack. Wire error shape is unchanged.
          {:error, code, message, st} ->
            {st, n, [%{index: index, code: code, message: message} | errs]}
        end
      end)

    # Settle any tabs the batch's trailing cell ops left dirty: recompute each
    # once and broadcast its coalesced delta BEFORE the persist sees the state.
    state = Ops.flush_pending(state)
    state = if applied > 0, do: maybe_flush_or_debounce(state), else: state
    reply = %{rev: state.rev, epoch: state.epoch, applied: applied, errors: Enum.reverse(errors)}
    {reply, state}
  end

  @impl true
  def handle_info(:flush_debounce, state) do
    {:noreply, persist(%{state | flush_timer: nil})}
  end

  def handle_info(:idle_stop, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    case persist_result(state) do
      {:ok, _state} ->
        :ok

      {{:error, _reason}, state} ->
        # The supervisor is taking us down — there is no next debounce to
        # retry on. One bounded retry rides out a transient pool/timeout
        # blip; a second failure is confirmed loss of the acknowledged tail.
        Process.sleep(250)

        case persist_result(state) do
          {:ok, _state} ->
            :ok

          {{:error, reason}, state} ->
            Logger.error(
              "[Sheets.Session] terminate persist FAILED twice for " <>
                "#{state.dataset}/#{state.slug}: #{inspect(reason)} — " <>
                "acknowledged ops since the last flush are lost"
            )

            :ok
        end
    end
  end

  # The op-application machinery — op dispatch (`apply_one/2`), the per-user
  # undo/redo machine, validation, cell mutation, structural shifts,
  # recompute, the delta broadcast, and the cached counters — lives in
  # `Barkpark.Plugins.Sheets.Session.Ops`. The GenServer keeps only the
  # callbacks, client API, persistence, and timers; `handle_call/3`
  # dispatches each op through `Ops.apply_one/2` + `Ops.record_undo/3`.

  # ── persistence ──────────────────────────────────────────────────────────

  defp maybe_flush_or_debounce(state) do
    if state.ops_since_flush >= state.cfg.flush_after_ops do
      persist(state)
    else
      arm_debounce(state)
    end
  end

  # Persist through the canonical upsert path — engine recompute (idempotent
  # double-compute, by design), revisions, write-through embed snapshots and
  # the standard broadcasts all ride along. No-op when clean. Fire-and-forget
  # callers (debounce, op-count flush, terminate) take the state alone;
  # the :flush call uses persist_result/1 to surface a failed persist.
  defp persist(state) do
    {_result, state} = persist_result(state)
    state
  end

  defp persist_result(%{dirty?: false} = state), do: {:ok, state}

  defp persist_result(state) do
    detect_external_change(state)

    attrs = %{"doc_id" => state.slug, "content" => state.content}
    attrs = if is_binary(state.title), do: Map.put(attrs, "title", state.title), else: attrs

    case Content.upsert_document("sheet", attrs, state.dataset, source: "sheets_session") do
      {:ok, doc} ->
        state =
          cancel_debounce(%{
            state
            | dirty?: false,
              ops_since_flush: 0,
              persisted_doc_id: doc.doc_id,
              persisted_rev: doc.rev
          })

        broadcast_persisted(state, true)
        {:ok, state}

      {:error, reason} ->
        Logger.warning(
          "[Sheets.Session] persist failed for #{state.dataset}/#{state.slug}: #{inspect(reason)} — retrying on the next debounce"
        )

        # The debounce retry stays armed, so the client's "Save failed —
        # retrying" indicator is honest: the next flush attempt is scheduled.
        state = arm_debounce(%{state | ops_since_flush: 0})
        broadcast_persisted(state, false)
        {{:error, reason}, state}
    end
  end

  # The save-status seam: every persist ATTEMPT (both branches — the only
  # clean-state no-op is the `dirty?: false` head above, which never touches
  # storage) announces its outcome on the SAME `:sheets:op` topic the deltas
  # ride, so a subscribed Studio grid can render a live "Saving…/All changes
  # saved/Save failed" indicator with no new subscription. `rev`/`epoch` let
  # the client discard a stale persist frame that landed after it advanced.
  defp broadcast_persisted(state, ok?) do
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      topic(state.slug, state.dataset, state.workspace_id),
      {:sheets_persisted,
       %{
         sheet_id: state.slug,
         rev: state.rev,
         epoch: state.epoch,
         ok: ok?,
         saved_at: DateTime.utc_now()
       }}
    )
  end

  # A direct mutate to the same sheet while this session lives is a
  # DOCUMENTED conflict (M4 presence/locks territory): detect the external
  # rev change, warn, and let this persist win.
  defp detect_external_change(state) do
    case Content.get_document(state.persisted_doc_id, "sheet", state.dataset) do
      {:ok, %{rev: rev}} when rev != state.persisted_rev ->
        Logger.warning(
          "[Sheets.Session] external write detected on #{state.dataset}/#{state.persisted_doc_id} " <>
            "(rev #{rev} != session's #{state.persisted_rev}) — the session's persist wins"
        )

      _ ->
        :ok
    end
  end

  # ── timers + counters ────────────────────────────────────────────────────

  defp arm_debounce(state) do
    state = cancel_debounce(state)
    %{state | flush_timer: Process.send_after(self(), :flush_debounce, state.cfg.debounce_ms)}
  end

  defp cancel_debounce(%{flush_timer: nil} = state), do: state

  defp cancel_debounce(%{flush_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | flush_timer: nil}
  end

  defp schedule_idle(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: Process.send_after(self(), :idle_stop, state.cfg.idle_stop_ms)}
  end

  # Draft-first, published fallback — the export controller's precedence.
  defp load_doc(pubid, dataset) do
    with {:error, :not_found} <- Content.get_document(Content.draft_id(pubid), "sheet", dataset),
         {:error, :not_found} <- Content.get_document(pubid, "sheet", dataset) do
      {:error, :not_found}
    else
      {:ok, doc} -> {:ok, doc}
    end
  end

  defp config do
    env = Application.get_env(:barkpark, __MODULE__, [])

    %{
      debounce_ms: Keyword.get(env, :debounce_ms, 2_000),
      flush_after_ops: Keyword.get(env, :flush_after_ops, 25),
      idle_stop_ms: Keyword.get(env, :idle_stop_ms, 300_000),
      hibernate_after: Keyword.get(env, :hibernate_after, 15_000),
      cell_cap: Keyword.get(env, :cell_cap, 50_000)
    }
  end
end
