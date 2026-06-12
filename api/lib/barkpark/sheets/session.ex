defmodule Barkpark.Sheets.Session do
  @moduledoc """
  Per-sheet collaborative session (M1) — a GenServer that owns one sheet
  document's content in memory and serializes cell-granular ops against it.

  CORE, plugin-independent (fresh-install invariant): sessions work with the
  Sheets plugin off — only the HTTP ops route
  (`POST /v1/plugins/sheets/:slug/ops`) is plugin wiring. Direct
  `/v1/data/mutate` writes keep working without a session.

  ## Lifecycle

  Started LAZILY on the first op via `apply_ops/3` — a `DynamicSupervisor`
  (`Barkpark.Sheets.SessionSupervisor`) child keyed in
  `Barkpark.Sheets.SessionRegistry` by `{dataset, published-id}`. `init/1`
  reads the persisted row ONCE (draft-first, published fallback — the same
  precedence the export controller uses); while the session lives, its
  memory is authoritative. The process hibernates when idle
  (`:hibernate_after`) and stops itself after `idle_stop_ms` without calls;
  `terminate/2` persists any unflushed state (exits are trapped so a
  supervisor shutdown reaches it).

  ## Ops (v1)

  String-keyed maps, the wire shape. Cell ops:

    * `%{"op" => "set_cell", "tab" => i, "ref" => "A1", "raw" => raw}` —
      `raw` is a scalar; a string with a leading `"="` is a formula (the
      importer convention) and stores as `%{"f" => <without "=">}`, anything
      else stores as `%{"v" => raw}`.
    * `%{"op" => "clear_cell", "tab" => i, "ref" => "A1"}`

  Structural ops (the grid editor) — Excel ref-shift semantics live in
  `Barkpark.Sheets.Structure` (cell keys shift, formula refs/ranges
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
    * `%{"op" => "rename_tab", "tab" => i, "name" => s}`,
      `%{"op" => "add_tab", "name" => s}` (appends an empty tab), and
      `%{"op" => "delete_tab", "tab" => i}` — deleting the LAST tab is
      refused (`last_tab`).

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

  ## Per-user undo/redo (M4)

  Any op may carry an optional `"user"` string — when present, the session
  records the op's INVERSE onto that user's undo stack (depth 100, oldest
  entries drop): `set_cell`/`clear_cell` store the prior cell map; `insert_*` store
  the matching `delete_*`; `delete_*` store the matching `insert_*` PLUS the
  deleted span's captured cells; `set_col_width`/`set_row_height` store the
  prior px; `rename_tab` the prior name; `add_tab` its `delete_tab`;
  `delete_tab` the captured tab. Undo/redo arrive as ops through the same
  mailbox:

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

  ## Recompute + delta broadcast

  After each applied op the session recomputes the op's tab through
  `Barkpark.Sheets.Engine` (formulas are tab-local, so other tabs cannot
  change; tabs holding NO formula cell skip the engine entirely — a
  per-tab formula count keeps the common bulk-import case O(1) per op,
  since a full recompute measures ~70–90ms at the 50_000-cell cap) and
  broadcasts a compact delta:

      {:sheets_op, %{sheet_id: pubid, rev: n, tab: i, changed: %{"A1" => cell | nil, …}}}

  on `topic/3` — the existing `Content.doc_topic/4` SUFFIXED with
  `":sheets:op"`, so every existing doc-topic subscriber is unaffected.
  `rev` is the session's monotonic applied-op counter; `changed` carries
  EVERY cell whose stored map changed (recompute dependents included),
  `nil` marking a removal. A structural op may produce a LARGE `changed`
  (every shifted cell appears under both its old key, as `nil`, and its
  new key) — its delta therefore also carries
  `structure: %{op: s, at: n | nil, count: n | nil, tab: i}` so clients
  can re-key locally instead of replaying the map.

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

  `config :barkpark, Barkpark.Sheets.Session, …` — `debounce_ms` (2_000),
  `flush_after_ops` (25), `idle_stop_ms` (300_000), `hibernate_after`
  (15_000), `cell_cap` (50_000, mirroring the plugin gate's import cap).
  Read at session start; tests override via `Application.put_env/3`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Barkpark.Content
  alias Barkpark.Sheets
  alias Barkpark.Sheets.Engine
  alias Barkpark.Sheets.Structure

  @registry Barkpark.Sheets.SessionRegistry
  @supervisor Barkpark.Sheets.SessionSupervisor

  # Excel's grid bounds — column XFD, row 1_048_576. Deliberately duplicated
  # (the established convention: `Barkpark.Sheets.Engine` and the plugin gate
  # `Barkpark.Plugins.Sheets` each keep their own copy of the same two
  # integers): the Session is CORE and must not reach into the plugin, and
  # `Barkpark.Sheets.parse_ref/1` stays a pure, total A1 parser.
  @grid_max_col 16_384
  @grid_max_row 1_048_576

  @call_timeout 30_000

  # Per-call batch bound: one apply_ops call carries at most this many ops.
  # Refused outright ({:error, :batch_too_large, n}) before the call reaches
  # the session mailbox — the 50k cell cap and the 30s call timeout are the
  # only other bounds, and neither stops a pathological million-op list.
  # Large legitimate batches chunk at the caller (SheetGrid.send_ops/2).
  @max_ops_per_call 1_000

  # Per-user undo/redo stack depth (M4, bound at the grill).
  @undo_depth 100

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Apply `ops` (a list of wire-shaped op maps, see the moduledoc) to the
  sheet at `slug` in `dataset`, resolving-or-starting the session.

  Returns `{:ok, %{rev: n, applied: n, errors: [%{index:, code:, message:}]}}`,
  `{:error, :not_found}` when no sheet resolves for the slug,
  `{:error, :batch_too_large, n}` when `ops` exceeds `max_ops_per_call/0`,
  or `{:error, :session_unavailable}` when the session died twice in a row
  (see `call_session/4`).
  """
  @spec apply_ops(String.t(), String.t(), [map()]) ::
          {:ok, %{rev: non_neg_integer(), applied: non_neg_integer(), errors: [map()]}}
          | {:error, term()}
          | {:error, :batch_too_large, pos_integer()}
  def apply_ops(slug, dataset, ops)
      when is_binary(slug) and is_binary(dataset) and is_list(ops) do
    case length(ops) do
      n when n > @max_ops_per_call -> {:error, :batch_too_large, n}
      _ -> call_session(slug, dataset, {:apply_ops, ops})
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
           persisted_doc_id: doc.doc_id,
           persisted_rev: doc.rev,
           dirty?: false,
           ops_since_flush: 0,
           flush_timer: nil,
           idle_timer: nil,
           nonempty: count_nonempty(content),
           formula_counts: count_formulas(content),
           undo: %{},
           redo: %{},
           cfg: config()
         })}

      {:error, :not_found} ->
        {:stop, :not_found}
    end
  end

  @impl true
  def handle_call({:apply_ops, ops}, _from, state) do
    {state, applied, errors} =
      ops
      |> Enum.with_index()
      |> Enum.reduce({state, 0, []}, fn {op, index}, {st, n, errs} ->
        case apply_one(op, st) do
          {:ok, st, inverse} ->
            {record_undo(st, op, inverse), n + 1, errs}

          {:error, code, message} ->
            {st, n, [%{index: index, code: code, message: message} | errs]}
        end
      end)

    state = if applied > 0, do: maybe_flush_or_debounce(state), else: state
    reply = %{rev: state.rev, applied: applied, errors: Enum.reverse(errors)}
    {:reply, {:ok, reply}, schedule_idle(state)}
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
    persist(state)
    :ok
  end

  # ── op application ───────────────────────────────────────────────────────
  #
  # Every clause returns {:ok, state, inverse | nil} — the inverse is the
  # per-user undo entry (see apply_entry/2), nil when the op records no
  # history (undo/redo themselves mutate the stacks inline).

  defp apply_one(%{"op" => "set_cell", "tab" => tab, "ref" => ref, "raw" => raw}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, ref} <- validate_ref(ref),
         {:ok, cell} <- build_cell(raw),
         :ok <- check_cap(state, tab_idx, ref, cell) do
      inverse = {:cell, tab_idx, ref, cell_before(state, tab_idx, ref)}
      {:ok, apply_cell(state, tab_idx, ref, cell), inverse}
    end
  end

  defp apply_one(%{"op" => "clear_cell", "tab" => tab, "ref" => ref}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, ref} <- validate_ref(ref) do
      inverse = {:cell, tab_idx, ref, cell_before(state, tab_idx, ref)}
      {:ok, apply_cell(state, tab_idx, ref, nil), inverse}
    end
  end

  defp apply_one(%{"op" => op, "tab" => tab, "at" => at, "count" => count}, state)
       when op in ["insert_rows", "delete_rows", "insert_cols", "delete_cols"] do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         old_tab = Sheets.get_tab(state.content, tab_idx),
         {:ok, new_tab} <- structural_shift(op, old_tab, at, count) do
      inverse = shift_inverse(op, tab_idx, old_tab, at, count)

      {:ok,
       apply_structural(state, tab_idx, new_tab, true, %{op: op, at: at, count: count, tab: tab_idx}),
       inverse}
    end
  end

  defp apply_one(%{"op" => "set_col_width", "tab" => tab, "col" => col} = op_map, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         old_tab = Sheets.get_tab(state.content, tab_idx),
         {:ok, new_tab} <- Structure.set_col_width(old_tab, col, Map.get(op_map, "px")) do
      inverse = {:structural, %{"op" => "set_col_width", "tab" => tab_idx, "col" => col, "px" => prior_px(old_tab, "col_widths", col)}}

      {:ok,
       apply_structural(state, tab_idx, new_tab, false, %{op: "set_col_width", at: col, count: nil, tab: tab_idx}),
       inverse}
    end
  end

  defp apply_one(%{"op" => "set_row_height", "tab" => tab, "row" => row} = op_map, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         old_tab = Sheets.get_tab(state.content, tab_idx),
         {:ok, new_tab} <- Structure.set_row_height(old_tab, row, Map.get(op_map, "px")) do
      inverse = {:structural, %{"op" => "set_row_height", "tab" => tab_idx, "row" => row, "px" => prior_px(old_tab, "row_heights", row)}}

      {:ok,
       apply_structural(state, tab_idx, new_tab, false, %{op: "set_row_height", at: row, count: nil, tab: tab_idx}),
       inverse}
    end
  end

  defp apply_one(%{"op" => "rename_tab", "tab" => tab, "name" => name}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, name} <- validate_tab_name(name) do
      old_tab = Sheets.get_tab(state.content, tab_idx)
      prior_name = Map.get(old_tab, "name") || "Sheet #{tab_idx + 1}"
      inverse = {:structural, %{"op" => "rename_tab", "tab" => tab_idx, "name" => prior_name}}
      new_tab = Map.put(old_tab, "name", name)

      {:ok,
       apply_structural(state, tab_idx, new_tab, false, %{op: "rename_tab", at: nil, count: nil, tab: tab_idx}),
       inverse}
    end
  end

  defp apply_one(%{"op" => "add_tab", "name" => name}, state) do
    with {:ok, name} <- validate_tab_name(name) do
      tabs = Map.get(state.content, "tabs") || []
      new_idx = length(tabs)
      content = Map.put(state.content, "tabs", tabs ++ [%{"name" => name, "cells" => %{}}])
      inverse = {:structural, %{"op" => "delete_tab", "tab" => new_idx}}

      {:ok,
       finalize_structural(state, content, new_idx, %{}, %{op: "add_tab", at: nil, count: nil, tab: new_idx}),
       inverse}
    end
  end

  defp apply_one(%{"op" => "delete_tab", "tab" => tab}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab) do
      tabs = Map.get(state.content, "tabs")

      if length(tabs) == 1 do
        {:error, "last_tab", "a sheet keeps at least one tab — cannot delete the last one"}
      else
        old_tab = Enum.at(tabs, tab_idx)
        old_cells = Map.get(old_tab, "cells") || %{}
        changed = Map.new(old_cells, fn {addr, _cell} -> {addr, nil} end)
        content = Map.put(state.content, "tabs", List.delete_at(tabs, tab_idx))

        {:ok,
         finalize_structural(state, content, tab_idx, changed, %{op: "delete_tab", at: nil, count: nil, tab: tab_idx}),
         {:tab_restore, tab_idx, old_tab}}
      end
    end
  end

  defp apply_one(%{"op" => op} = op_map, state) when op in ["undo", "redo"] do
    apply_history(op_map, state, String.to_existing_atom(op))
  end

  defp apply_one(_op, _state) do
    {:error, "malformed_op",
     "op must be set_cell/clear_cell (\"tab\"+\"ref\"), " <>
       "insert_rows/delete_rows/insert_cols/delete_cols (\"tab\"+\"at\"+\"count\"), " <>
       "set_col_width (\"tab\"+\"col\"+\"px\"), set_row_height (\"tab\"+\"row\"+\"px\"), " <>
       "rename_tab (\"tab\"+\"name\"), add_tab (\"name\"), delete_tab (\"tab\") " <>
       "or undo/redo (\"user\")"}
  end

  # ── per-user undo/redo (M4) ──────────────────────────────────────────────
  #
  # Inverse entries live as internal terms, never wire ops — a prior cell is
  # a FULL stored map (formula + computed value + style), not a raw scalar:
  #
  #   * {:cell, tab_idx, ref, cell | nil}      — restore one cell exactly
  #   * {:structural, op_map}                  — a plain structural wire op
  #   * {:structural_restore, op_map, cells}   — insert_* + the deleted
  #     span's captured cells (the inverse of a delete_*)
  #   * {:tab_restore, idx, tab}               — re-insert a deleted tab
  #
  # Applying an entry yields its OWN inverse, which lands on the opposite
  # stack — undo and redo are the same machine run in either direction.

  defp apply_history(%{"user" => user}, state, kind) when is_binary(user) and user != "" do
    {from, onto} = if kind == :undo, do: {:undo, :redo}, else: {:redo, :undo}

    case Map.get(Map.fetch!(state, from), user, []) do
      [] ->
        {:error, "nothing_to_#{kind}", "no entries on #{inspect(user)}'s #{kind} stack"}

      [entry | rest] ->
        # The entry is consumed either way: an entry that no longer applies
        # (its tab vanished under another user) would otherwise jam the
        # stack permanently.
        state = put_stack(state, from, user, rest)

        case apply_entry(entry, state) do
          {:ok, state, counter} -> {:ok, push_stack(state, onto, user, counter), nil}
          {:error, _code, _message} = error -> error
        end
    end
  end

  defp apply_history(_op, _state, kind),
    do: {:error, "invalid_user", "#{kind} requires a non-blank \"user\" string"}

  # A successfully applied own-op pushes its inverse and clears the user's
  # redo stack; ops without a "user" (imports, anonymous wire calls) and
  # undo/redo themselves (inverse nil) record nothing.
  defp record_undo(state, _op, nil), do: state

  defp record_undo(state, op, inverse) do
    case Map.get(op, "user") do
      user when is_binary(user) and user != "" ->
        state |> push_stack(:undo, user, inverse) |> put_stack(:redo, user, [])

      _ ->
        state
    end
  end

  defp push_stack(state, key, user, entry) do
    stacks = Map.fetch!(state, key)
    stack = Enum.take([entry | Map.get(stacks, user, [])], @undo_depth)
    Map.put(state, key, Map.put(stacks, user, stack))
  end

  defp put_stack(state, key, user, stack) do
    Map.put(state, key, Map.put(Map.fetch!(state, key), user, stack))
  end

  defp apply_entry({:cell, tab, ref, cell}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab) do
      counter = {:cell, tab_idx, ref, cell_before(state, tab_idx, ref)}
      {:ok, apply_cell(state, tab_idx, ref, cell), counter}
    end
  end

  defp apply_entry({:structural, op_map}, state), do: apply_one(op_map, state)

  defp apply_entry({:structural_restore, %{"op" => op, "tab" => tab, "at" => at, "count" => count}, captured}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, new_tab} <- structural_shift(op, Sheets.get_tab(state.content, tab_idx), at, count) do
      new_tab = Map.update(new_tab, "cells", captured, &Map.merge(&1, captured))
      counter = {:structural, %{"op" => delete_op_for(op), "tab" => tab_idx, "at" => at, "count" => count}}

      {:ok,
       apply_structural(state, tab_idx, new_tab, true, %{op: op, at: at, count: count, tab: tab_idx}),
       counter}
    end
  end

  defp apply_entry({:tab_restore, idx, tab}, state) do
    tabs = Map.get(state.content, "tabs") || []
    idx = min(idx, length(tabs))
    content = Map.put(state.content, "tabs", List.insert_at(tabs, idx, tab))
    changed = Map.get(tab, "cells") || %{}
    counter = {:structural, %{"op" => "delete_tab", "tab" => idx}}

    {:ok,
     finalize_structural(state, content, idx, changed, %{op: "restore_tab", at: nil, count: nil, tab: idx}),
     counter}
  end

  # insert_* invert to plain deletes; delete_* invert to inserts carrying
  # the deleted span's cells (keyed by their original refs).
  defp shift_inverse(op, tab_idx, _old_tab, at, count) when op in ["insert_rows", "insert_cols"] do
    {:structural, %{"op" => delete_op_for(op), "tab" => tab_idx, "at" => at, "count" => count}}
  end

  defp shift_inverse(op, tab_idx, old_tab, at, count) do
    axis = if op == "delete_rows", do: :row, else: :col
    insert_op = if op == "delete_rows", do: "insert_rows", else: "insert_cols"
    captured = captured_span(old_tab, axis, at, count)
    {:structural_restore, %{"op" => insert_op, "tab" => tab_idx, "at" => at, "count" => count}, captured}
  end

  defp delete_op_for("insert_rows"), do: "delete_rows"
  defp delete_op_for("insert_cols"), do: "delete_cols"

  defp captured_span(tab, axis, at, count) do
    for {addr, cell} <- Map.get(tab, "cells") || %{},
        {:ok, {col, row}} <- [Sheets.parse_ref(addr)],
        (if axis == :row, do: row, else: col) in at..(at + count - 1),
        into: %{} do
      {addr, cell}
    end
  end

  defp prior_px(tab, key, index) do
    case Map.get(tab, key) do
      sizes when is_map(sizes) -> Map.get(sizes, Integer.to_string(index))
      _ -> nil
    end
  end

  defp cell_before(state, tab_idx, ref) do
    case Map.get(Sheets.get_tab(state.content, tab_idx) || %{}, "cells") do
      cells when is_map(cells) -> Map.get(cells, ref)
      _ -> nil
    end
  end

  defp structural_shift("insert_rows", tab, at, count), do: Structure.insert_rows(tab, at, count)
  defp structural_shift("delete_rows", tab, at, count), do: Structure.delete_rows(tab, at, count)
  defp structural_shift("insert_cols", tab, at, count), do: Structure.insert_cols(tab, at, count)
  defp structural_shift("delete_cols", tab, at, count), do: Structure.delete_cols(tab, at, count)

  defp validate_tab_name(name) do
    if is_binary(name) and String.trim(name) != "" do
      {:ok, name}
    else
      {:error, "invalid_name", "name must be a non-blank string, got #{inspect(name)}"}
    end
  end

  defp fetch_tab(content, tab) when is_integer(tab) and tab >= 0 do
    case Sheets.get_tab(content, tab) do
      %{} -> {:ok, tab}
      _ -> {:error, "tab_not_found", "the sheet has no tab #{tab}"}
    end
  end

  defp fetch_tab(_content, tab),
    do: {:error, "invalid_tab", "tab must be a non-negative integer, got #{inspect(tab)}"}

  # Normalizes through format_ref so "a1" and "A1" address the same cell.
  defp validate_ref(ref) do
    case Sheets.parse_ref(ref) do
      {:ok, {col, row}} when col <= @grid_max_col and row <= @grid_max_row ->
        {:ok, Sheets.format_ref({col, row})}

      {:ok, _} ->
        {:error, "ref_out_of_bounds",
         "ref #{inspect(ref)} is beyond the grid bounds (column #{@grid_max_col}/XFD, row #{@grid_max_row})"}

      :error ->
        {:error, "invalid_ref", "ref must be A1-style, got #{inspect(ref)}"}
    end
  end

  # Leading "=" means formula — the importer convention; the canonical
  # stored "f" drops the "=" (the engine tolerates both, see its moduledoc).
  defp build_cell("=" <> formula), do: {:ok, %{"f" => formula}}

  defp build_cell(raw) when is_binary(raw) or is_number(raw) or is_boolean(raw) or is_nil(raw),
    do: {:ok, %{"v" => raw}}

  defp build_cell(_raw),
    do: {:error, "invalid_raw", "raw must be a scalar (string, number, boolean or null)"}

  # Cap-aware set_cell: counts non-empty cells (the import predicate — a
  # usable "v" or a formula) incrementally; an op that would push past the
  # cap errors before touching the content.
  defp check_cap(state, tab_idx, ref, cell) do
    old_cell =
      case Map.get(Sheets.get_tab(state.content, tab_idx), "cells") do
        cells when is_map(cells) -> Map.get(cells, ref)
        _ -> nil
      end

    if state.nonempty + nonempty_flag(cell) - nonempty_flag(old_cell) > state.cfg.cell_cap do
      {:error, "cell_cap_exceeded",
       "the sheet holds #{state.nonempty} non-empty cells; the cap is #{state.cfg.cell_cap}"}
    else
      :ok
    end
  end

  defp apply_cell(state, tab_idx, ref, cell_or_nil) do
    tabs = Map.get(state.content, "tabs")
    old_tab = Enum.at(tabs, tab_idx)
    old_cells = Map.get(old_tab, "cells") || %{}
    old_cell = Map.get(old_cells, ref)

    base_cells =
      case cell_or_nil do
        nil -> Map.delete(old_cells, ref)
        cell -> Map.put(old_cells, ref, cell)
      end

    formula_count =
      Map.get(state.formula_counts, tab_idx, 0) + formula_flag(cell_or_nil) -
        formula_flag(old_cell)

    new_tab = Map.put(old_tab, "cells", base_cells)
    # Refs are tab-local (engine contract), so only the op's tab can change —
    # and a tab with zero formula cells has nothing to derive: skip the
    # engine entirely (the bulk-import fast path; see the moduledoc).
    new_tab = if formula_count > 0, do: recompute_tab(new_tab), else: new_tab

    changed = diff_cells(old_cells, Map.get(new_tab, "cells") || %{})

    state = %{
      state
      | content: Map.put(state.content, "tabs", List.replace_at(tabs, tab_idx, new_tab)),
        rev: state.rev + 1,
        dirty?: true,
        ops_since_flush: state.ops_since_flush + 1,
        nonempty: state.nonempty + nonempty_flag(cell_or_nil) - nonempty_flag(old_cell),
        formula_counts: Map.put(state.formula_counts, tab_idx, formula_count)
    }

    broadcast_delta(state, tab_idx, changed)
    state
  end

  # Structural ops rewrite a whole tab: swap the rewritten tab in,
  # recompute when it still holds formulas (`recompute?` — rewritten refs
  # must settle; layout/rename ops skip the engine), diff the cells for
  # the delta, and RECOUNT the cached counters — cells move or die
  # wholesale here, so incremental bookkeeping is not worth the bug
  # surface (structural ops are rare next to cell ops).
  defp apply_structural(state, tab_idx, new_tab, recompute?, structure) do
    tabs = Map.get(state.content, "tabs")
    old_cells = Map.get(Enum.at(tabs, tab_idx), "cells") || %{}
    new_tab = if recompute? and holds_formula?(new_tab), do: recompute_tab(new_tab), else: new_tab
    changed = diff_cells(old_cells, Map.get(new_tab, "cells") || %{})
    content = Map.put(state.content, "tabs", List.replace_at(tabs, tab_idx, new_tab))
    finalize_structural(state, content, tab_idx, changed, structure)
  end

  defp finalize_structural(state, content, tab_idx, changed, structure) do
    state = %{
      state
      | content: content,
        rev: state.rev + 1,
        dirty?: true,
        ops_since_flush: state.ops_since_flush + 1,
        nonempty: count_nonempty(content),
        formula_counts: count_formulas(content)
    }

    broadcast_delta(state, tab_idx, changed, structure)
    state
  end

  defp holds_formula?(tab) do
    Enum.any?(Map.get(tab, "cells") || %{}, fn {_addr, cell} ->
      is_map(cell) and is_binary(Map.get(cell, "f"))
    end)
  end

  defp recompute_tab(tab) do
    %{"tabs" => [tab]} = Engine.recompute(%{"tabs" => [tab]})
    tab
  end

  # Every cell whose stored map changed — recompute dependents included;
  # nil marks a removal.
  defp diff_cells(old, new) do
    for addr <- Enum.uniq(Map.keys(old) ++ Map.keys(new)),
        Map.get(old, addr) != Map.get(new, addr),
        into: %{} do
      {addr, Map.get(new, addr)}
    end
  end

  defp broadcast_delta(state, tab_idx, changed, structure \\ nil) do
    payload = %{sheet_id: state.slug, rev: state.rev, tab: tab_idx, changed: changed}
    payload = if structure, do: Map.put(payload, :structure, structure), else: payload

    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      topic(state.slug, state.dataset, state.workspace_id),
      {:sheets_op, payload}
    )
  end

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
        {:ok,
         cancel_debounce(%{
           state
           | dirty?: false,
             ops_since_flush: 0,
             persisted_doc_id: doc.doc_id,
             persisted_rev: doc.rev
         })}

      {:error, reason} ->
        Logger.warning(
          "[Sheets.Session] persist failed for #{state.dataset}/#{state.slug}: #{inspect(reason)} — retrying on the next debounce"
        )

        {{:error, reason}, arm_debounce(%{state | ops_since_flush: 0})}
    end
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

  # The import controller's non-empty predicate: a usable "v" or a formula.
  defp nonempty_flag(nil), do: 0

  defp nonempty_flag(cell) do
    if Map.get(cell, "v") not in [nil, ""] or is_binary(Map.get(cell, "f")), do: 1, else: 0
  end

  defp formula_flag(nil), do: 0
  defp formula_flag(cell), do: if(is_binary(Map.get(cell, "f")), do: 1, else: 0)

  defp count_nonempty(content) do
    for tab <- Map.get(content, "tabs") || [],
        is_map(tab),
        {_addr, cell} <- Map.get(tab, "cells") || %{},
        is_map(cell),
        reduce: 0 do
      acc -> acc + nonempty_flag(cell)
    end
  end

  defp count_formulas(content) do
    for {tab, idx} <- Enum.with_index(Map.get(content, "tabs") || []),
        is_map(tab),
        {_addr, cell} <- Map.get(tab, "cells") || %{},
        is_map(cell),
        reduce: %{} do
      acc -> Map.update(acc, idx, formula_flag(cell), &(&1 + formula_flag(cell)))
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
