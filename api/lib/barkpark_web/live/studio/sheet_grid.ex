defmodule BarkparkWeb.Studio.SheetGrid do
  @moduledoc """
  Studio grid editor for `type:"sheet"` documents (Sheets M2) — one
  `Phoenix.LiveComponent` owning the whole editing surface: the table grid,
  the formula bar + A1 name box, keyboard navigation with rectangular
  selection, TSV clipboard, row/column structure menus + resize, and the
  bottom tab strip.

  This module is the thin facade: it owns the LiveComponent callbacks
  (`mount/2`, `update/2`, every `handle_event/3`) and the render template
  (`render/1`, `sheet_table/1`, `peer_layer/1`) — Phoenix routes events and
  resolves HEEx component calls here, so those stay. The logic is sharded
  into three sibling modules under `sheet_grid/`:

    * `SheetGrid.Geometry`  — pure selection/range/peer-box math + the px
      sums the frozen bands pin with (`left_px`/`top_px`/`col_px`/`row_px`).
    * `SheetGrid.GridData`  — grid/tab derivation (`derive_grid/1`,
      `merge_maps/3`, `clamp_row_offset/2`) and the change-tracking contract.
    * `SheetGrid.Cells`     — pure cell presentation (`display/1`,
      `cell_class/5`, `cell_style/7`) the render template stamps per `<td>`.
    * `SheetGrid.Ops`       — commit/persistence (`send_ops/2`, `commit/3`,
      delta application, `push_presence/2`).

  ## Wire protocol — edits are ops, state is deltas

  EVERY edit becomes a `Barkpark.Plugins.Sheets.Session.apply_ops/3` call
  (server-side, no HTTP hop) and the component NEVER applies an op to its
  own assigns. The hosting StudioLive subscribes to the session delta topic
  (`Session.topic/3`) and forwards each `{:sheets_op, payload}` here via
  `send_update/3`: cell deltas merge into the local `content`; structural
  deltas (`payload.structure` — the changed map alone cannot re-key
  col_widths/merges/frozen bands) refetch the authoritative content via
  `Session.peek/2`. Own ops and remote edits ride the SAME path, so a
  second browser on the same sheet stays live by construction (M4 layers
  presence on top). Per-op errors (`cell_cap_exceeded`, bounds, …) surface
  as a transient notice.

  ## Rendering bounds

  No virtualization yet (future work): the grid BODY renders one
  `@max_rows`-tall (500) `row_range` window at a time; the pager walks
  `row_offset` across the pages (pure navigation — never `Ops.send_ops`, so
  it works on the read-only reader and starts no session), so a tall
  published sheet is fully reachable. Absolute row numbers everywhere
  (`data-ref`/`data-r`/`aria-rowindex`), `aria-rowcount` = the full height.
  v1 limitations, both recorded here: row-sticky frozen rows + the peer
  overlay render only on page 0 (frozen COLS pin on every page), and columns
  past `@max_cols` (64) are a NOTICE-ONLY clip surfaced in the pager text —
  there is no horizontal paging.
  Frozen rows/cols pin via CSS sticky, merges render as colspan/rowspan,
  `"s"` cell styles (b/i/bg/al) inline; engine error values (`#CYCLE!` …)
  and `"stale"` cells carry marker classes. Formula cells show the computed
  `"v"` in the grid and the `=`-prefixed `"f"` in the bar.

  The thin client half is `Hooks.SheetGrid`
  (`priv/static/assets/bp-sheet-grid.js`): keyboard map, clipboard TSV
  read/write, header resize drag, scroll-position keep. No grid/spreadsheet
  JS dependency (Golden Rule: no blocking scripts, LiveView-native).

  View mode (the header toggle) reuses the SAME `sheet_table/1` renderer
  minus every editing affordance — formula bar, hook, menus, resize handles
  and tab mutation buttons all drop away.

  ## Read-only hosting (M4 — the public reader)

  A host passing `read_only={true}` (the `/sheets/:slug` reader) gets the
  bare published grid: no document header, no formula bar, no hook, no menus,
  no active-cell highlight — the tab strip keeps ONLY its switch buttons. The
  guard is server-side too: `Ops.send_ops/2` drops every mutation while
  read-only, so a forged client event can never write through an
  unauthenticated mount.

  PUBLISHED-ONLY for read-only hosts: content comes from `@doc.content` (the
  published perspective) and NEVER from `Session.peek` — a live session is
  draft-backed, so peeking it would leak unpublished edits. Session deltas
  do NOT apply either: the `{:sheets_op, …}` update clause is a no-op while
  read-only (the reader also stops forwarding them and stops peeking on
  refetch — each read path sealed independently, fail closed). A read-only
  host refreshes via the `%{published_content: …}` update clause when a
  publish lands. The editable (Studio) host keeps peeking the live session
  and applying every delta.

  ## Per-user undo/redo (M4)

  `Ops.send_ops/2` stamps the studio identity's `user_id` onto every op as
  `"user"`, so the session records per-user inverse stacks; the hook's
  Cmd/Ctrl+Z / Cmd/Ctrl+Shift+Z push `"undo"`/`"redo"` events that ride the
  same path as ops (`%{"op" => "undo", "user" => …}`). Empty-stack
  rejections surface as the transient notice like any other per-op error.

  ## Collaborator presence (M4)

  The hosting StudioLive tracks this user on the per-sheet presence topic
  (`Session.presence_topic/3` via `BarkparkWeb.Presence`) and passes the
  materialised list down as `presences` plus the topic and own `user_id`.
  This component OWNS the meta updates (same pid — components run in the LV
  process): the hook's client-throttled (~10/s) `presence-meta` frames carry
  the active cell + selection range; the `editing` flag is set on edit-start
  and cleared on commit/cancel — a soft lock, purely visual, LWW stands.
  Rendering: a collaborator's cursor renders as a colored outline box + name
  tag (emphasized while editing), a selection range as ONE translucent rect;
  colors are the user's studio identity color (deterministic per user_id
  from `PresenceState`'s fixed palette when none is stored).

  Presence paints on a dedicated absolutely-positioned overlay layer
  (`peer_layer/1`) SIBLING to the table, never inside the cell
  comprehension — deliberately: presence frames are the hottest re-render
  trigger (up to ~10/s per moving peer), and when peer decoration lived on
  the `<td>`s every frame re-evaluated the full grid body. Two halves make
  the skip real (review-phase measurement, 500-row × 10-col sheet,
  MIX_ENV=test, 2026-06): the overlay split keeps peer assigns out of the
  table's dynamics, and `GridData.derive_grid/1` persists every grid assign
  on the socket in update/2 — assigns computed in render/1 are render-local,
  so they re-mark as changed on every call and silently defeat LiveView's
  equality-based change tracking. Before: ~15ms server cost per presence
  frame (full grid re-render); after: ~0.3ms (only the overlay layer
  re-renders) — the live lock is the "MEASURE:" test in
  `studio_live_sheet_presence_test.exs`, budget 10ms. The geometry reuses
  the frozen-band px math (`Geometry.left_px`/`top_px`), so overlay boxes
  align with the cells by construction; boxes scroll with the content (the
  layer is absolutely positioned inside `.sheet-scroll`) and slide UNDER
  frozen bands like any non-sticky cell.
  """

  use BarkparkWeb, :live_component

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Core, as: Sheets
  alias Barkpark.Plugins.Sheets.Engine
  alias Barkpark.Plugins.Sheets.Session
  alias Barkpark.Plugins.Sheets.Structure
  alias BarkparkWeb.Studio.SheetGrid.{Cells, Geometry, GridData, Ops}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       content: nil,
       rev: 0,
       epoch: nil,
       tab: 0,
       row_offset: 0,
       active: {1, 1},
       anchor: nil,
       editing: nil,
       notice: nil,
       status: "",
       menu: nil,
       renaming_tab: nil,
       mode: :edit,
       read_only: false,
       user_id: nil,
       presence_topic: nil,
       presences: [],
       fn_names: fn_names()
     )}
  end

  # The formula-function vocabulary for autocomplete (the datalist on the
  # formula bar + the in-cell dropdown), stamped once at mount and static
  # thereafter. Canonically it flows from `Engine.function_names/0` so every
  # engine function (incl. wave-5/6 + the stats batch) surfaces with zero
  # coordination. SPEC-DRIFT FALLBACK: the stats-batch slice lands
  # `Engine.function_names/0`; until it does, this mirrors the Engine's
  # supported set so the datalist/dropdown work standalone. Integration
  # (pick 0 before pick 3) makes the real function authoritative — the
  # `function_exported?` guard transparently switches over with no merge fixup.
  defp fn_names do
    if Code.ensure_loaded?(Engine) and function_exported?(Engine, :function_names, 0) do
      Engine.function_names()
    else
      ~w(SUM AVG AVERAGE MIN MAX COUNT COUNTA IF ROUND ABS
         AND OR NOT IFERROR ROUNDUP ROUNDDOWN INT
         LEN TRIM UPPER LOWER LEFT RIGHT MID CONCATENATE TEXTJOIN
         EXACT FIND SEARCH SUBSTITUTE REPLACE REPT PROPER VALUE
         ISBLANK ISNUMBER ISTEXT ISLOGICAL ISERROR ISERR ISNA
         CHOOSE SWITCH IFS
         DATE YEAR MONTH DAY TODAY NOW
         NA COUNTIF SUMIF AVERAGEIF
         VLOOKUP MATCH INDEX
         COUNTIFS SUMIFS AVERAGEIFS)
    end
  end

  # A session delta forwarded by StudioLive's `{:sheets_op, …}` handle_info.
  # Read-only hosts (the public reader) drop it: session deltas carry
  # unpublished draft edits and must never stream to anonymous viewers.
  @impl true
  def update(%{sheets_op: payload}, socket) do
    if socket.assigns.read_only do
      {:ok, socket}
    else
      {:ok, socket |> Ops.apply_delta(payload) |> GridData.derive_grid()}
    end
  end

  # A published-row refresh forwarded by the reader when a publish lands —
  # the read-only host's only content-update path (no session peek, no delta).
  def update(%{published_content: content}, socket) do
    socket = assign(socket, content: content)
    tab = min(socket.assigns.tab, max(length(GridData.tabs(socket)) - 1, 0))
    {:ok, socket |> assign(tab: tab) |> GridData.derive_grid()}
  end

  def update(assigns, socket) do
    socket =
      assign(
        socket,
        Map.take(assigns, [
          :id,
          :doc,
          :dataset,
          :is_draft,
          :read_only,
          :user_id,
          :presence_topic,
          :presences
        ])
      )

    socket = GridData.derive_editable(socket)

    if socket.assigns[:content] do
      {:ok, socket}
    else
      doc = assigns.doc
      slug = Content.published_id(doc.doc_id)

      # Editable hosts: a live session's memory is authoritative; the
      # persisted row backs the cold open (same draft-first row the session
      # itself loads). Read-only hosts (the public reader) NEVER peek — the
      # session is draft-backed, so its memory would leak unpublished edits;
      # content comes from the published `@doc.content` only.
      content =
        if socket.assigns.read_only do
          doc.content || %{}
        else
          case Session.peek(slug, assigns.dataset) do
            {:ok, content} -> content
            {:error, :no_session} -> doc.content || %{}
          end
        end

      {:ok, socket |> assign(slug: slug, content: content) |> GridData.derive_grid()}
    end
  end

  # ── events: selection + navigation ──────────────────────────────────────

  @impl true
  def handle_event("cell-click", %{"ref" => ref} = params, socket) do
    case Sheets.parse_ref(ref) do
      {:ok, pos} ->
        socket = commit_clickaway(socket, params)
        anchor = if params["shift"], do: socket.assigns.anchor || socket.assigns.active, else: nil
        {:noreply, assign(socket, active: pos, anchor: anchor, editing: nil, menu: nil)}

      :error ->
        {:noreply, socket}
    end
  end

  # Excel semantics: a click that moves the selection while an editor is open
  # COMMITS the draft to the still-active cell — never a silent discard. `commit`
  # rides an open CELL editor (guarded by editing != nil, the soft lock; v1
  # policy commits formula drafts on click-away too — Excel's point mode is the
  # deferred formula-editing task, and either policy beats losing the text).
  # `bar_commit` rides a dirty FORMULA BAR, whose editing is ALREADY nil — so it
  # commits UNGUARDED (the editing guard would swallow it). Both land on
  # socket.assigns.active BEFORE the caller reassigns the active cell/selection.

  def handle_event("nav", %{"key" => key} = params, socket) do
    active = move(socket.assigns.active, key, move_bounds(socket))
    anchor = if params["shift"], do: socket.assigns.anchor || socket.assigns.active, else: nil
    {:noreply, assign(socket, active: active, anchor: anchor, editing: nil, menu: nil)}
  end

  # Row paging (M4) — step the `row_offset` window over a sheet taller than one
  # page. PURE navigation: an assign + `derive_grid` (which clamps the offset to
  # a real page), NEVER `Ops.send_ops`, so it works identically on the read-only
  # reader and can never start a session or mutate content. The active cell jumps
  # to the new window's top-left; a polite status line announces the range.
  def handle_event("rows-page", %{"dir" => dir}, socket) when dir in ["prev", "next"] do
    delta = if dir == "next", do: 1, else: -1

    socket =
      socket
      |> assign(
        row_offset: socket.assigns.row_offset + delta,
        anchor: nil,
        editing: nil,
        menu: nil
      )
      |> GridData.derive_grid()

    range = socket.assigns.row_range

    {:noreply,
     assign(socket,
       active: {1, range.first},
       status: "Showing rows #{range.first}–#{range.last} of #{socket.assigns.rows}"
     )}
  end

  # Header click selects the whole rendered row/col via the {active, anchor}
  # model — no new selection machinery. A plain click spans index i; shift
  # extends from the prior active row/col. The row case's active = {1, i}
  # makes the wave-5 rowcol-key target row i by construction. HONEST BOUND:
  # "whole column/row" = the RENDERED grid (the {cols, rows} cap), matching
  # every other selection gesture — not the sheet's logical infinity.
  def handle_event(
        "head-click",
        %{"kind" => kind, "index" => i, "shift" => shift} = params,
        socket
      )
      when kind in ["col", "row"] do
    # A header click is a click-away: commit any open cell editor / dirty bar to
    # the still-active cell BEFORE the whole-row/col selection reassigns it.
    socket = commit_clickaway(socket, params)
    # Whole row/col over the RENDERED window (`row_range`), not row 1 — the top
    # of the current page anchors the column selection so `active` stays visible.
    {cols, row_lo, row_hi} = move_bounds(socket)
    {active_col, active_row} = socket.assigns.active

    {active, anchor} =
      case kind do
        "col" ->
          i = min(max(to_int(i), 1), cols)
          {{i, row_lo}, {if(shift, do: active_col, else: i), row_hi}}

        "row" ->
          i = min(max(to_int(i), row_lo), row_hi)
          {{1, i}, {cols, if(shift, do: active_row, else: i)}}
      end

    {:noreply, assign(socket, active: active, anchor: anchor, editing: nil, menu: nil)}
  end

  def handle_event("name-jump", %{"ref" => ref}, socket) do
    case Sheets.parse_ref(ref) do
      {:ok, pos} -> {:noreply, assign(socket, active: pos, anchor: nil)}
      :error -> {:noreply, socket}
    end
  end

  # ── events: cell editing ─────────────────────────────────────────────────

  def handle_event("edit-start", params, socket) do
    prefill =
      case params["seed"] do
        seed when is_binary(seed) and seed != "" -> seed
        _ -> Cells.raw_of(GridData.cell_at(socket, socket.assigns.active))
      end

    {:noreply,
     socket
     |> assign(editing: %{prefill: prefill}, menu: nil)
     |> Ops.push_presence(%{
       editing: Sheets.format_ref(socket.assigns.active),
       tab: socket.assigns.tab
     })}
  end

  def handle_event("edit-cancel", _params, socket) do
    {:noreply, socket |> assign(editing: nil) |> Ops.push_presence(%{editing: nil})}
  end

  def handle_event("edit-commit", _params, %{assigns: %{read_only: true}} = socket),
    do: {:noreply, socket}

  def handle_event("edit-commit", %{"value" => value} = params, socket) do
    committed = socket.assigns.active
    socket = Ops.commit(socket, committed, value)
    active = move(committed, move_key(params["move"]), move_bounds(socket))

    {:noreply,
     socket
     |> announce_commit(committed)
     |> assign(editing: nil, active: active, anchor: nil)
     |> Ops.push_presence(%{editing: nil})}
  end

  def handle_event("bar-commit", _params, %{assigns: %{read_only: true}} = socket),
    do: {:noreply, socket}

  def handle_event("bar-commit", %{"value" => value} = params, socket) do
    committed = socket.assigns.active
    socket = Ops.commit(socket, committed, value)
    active = move(committed, move_key(params["move"]), move_bounds(socket))

    {:noreply,
     socket
     |> announce_commit(committed)
     |> assign(editing: nil, active: active, anchor: nil)
     |> Ops.push_presence(%{editing: nil})}
  end

  def handle_event("clear-selection", _params, socket) do
    {c1, c2, r1, r2} = Geometry.selection_rect(socket.assigns.active, socket.assigns.anchor)
    cells = Map.get(GridData.current_tab(socket), "cells") || %{}

    ops =
      for c <- c1..c2,
          r <- r1..r2,
          ref = Sheets.format_ref({c, r}),
          Map.has_key?(cells, ref) do
        %{"op" => "clear_cell", "tab" => socket.assigns.tab, "ref" => ref}
      end

    {:noreply, Ops.send_ops(socket, ops)}
  end

  # Fill down/right (Ctrl+D / Ctrl+R): the selection's first row (down) or
  # first column (right) is the source; every other cell in the rect copies
  # it with a per-step formula rebase. A formula source rebases its relative
  # refs ($-anchors pinned); a scalar source copies verbatim (no parse_raw
  # round-trip); a blank source CLEARS the target (Excel). Excel's single-
  # CELL Ctrl+D (copy from the row above the selection) is a v1 carve-out.
  def handle_event("fill", %{"dir" => dir}, socket) when dir in ["down", "right"] do
    {c1, c2, r1, r2} = Geometry.selection_rect(socket.assigns.active, socket.assigns.anchor)
    cells = Map.get(GridData.current_tab(socket), "cells") || %{}
    tab = socket.assigns.tab

    covered = socket.assigns.covered

    targets =
      if dir == "down" do
        for c <- c1..c2, r <- (r1 + 1)..r2//1, do: {c, r, {c, r1}, 0, r - r1}
      else
        for c <- (c1 + 1)..c2//1, r <- r1..r2, do: {c, r, {c1, r}, c - c1, 0}
      end

    # Never fill INTO or FROM a merge-covered cell: writing a covered target
    # plants data Studio never renders, and clearing a covered source would
    # emit a spurious clear_cell. The merge anchor still fills normally.
    targets =
      Enum.reject(targets, fn {c, r, src, _dc, _dr} ->
        MapSet.member?(covered, {c, r}) or MapSet.member?(covered, src)
      end)

    ops =
      Enum.map(targets, fn {c, r, src, dc, dr} ->
        ref = Sheets.format_ref({c, r})
        src_cell = Map.get(cells, Sheets.format_ref(src))

        case src_cell do
          %{"f" => f} when is_binary(f) ->
            stamp_meta(
              %{
                "op" => "set_cell",
                "tab" => tab,
                "ref" => ref,
                "raw" => "=" <> Structure.rebase_formula(f, dc, dr)
              },
              src_cell
            )

          %{"v" => v} ->
            stamp_meta(%{"op" => "set_cell", "tab" => tab, "ref" => ref, "raw" => v}, src_cell)

          _ ->
            %{"op" => "clear_cell", "tab" => tab, "ref" => ref}
        end
      end)

    {:noreply, Ops.send_ops(socket, ops)}
  end

  # Merge the current rectangular selection into one span. A single cell is
  # refused up front (nothing to merge); overlap/bounds/area rejections come
  # back through send_ops' notice path. On success the selection collapses to
  # the anchor and the :structure delta refetches the re-keyed merges.
  def handle_event("merge-selection", _params, socket) do
    {c1, c2, r1, r2} = Geometry.selection_rect(socket.assigns.active, socket.assigns.anchor)

    if c1 == c2 and r1 == r2 do
      {:noreply, assign(socket, notice: "select at least two cells to merge")}
    else
      range = Sheets.format_ref({c1, r1}) <> ":" <> Sheets.format_ref({c2, r2})
      op = %{"op" => "merge_cells", "tab" => socket.assigns.tab, "range" => range}

      {:noreply,
       socket
       |> Ops.send_ops([op])
       |> assign(active: {c1, r1}, anchor: nil)}
    end
  end

  # Drop every merge intersecting the selection (a single active cell is a
  # valid unmerge target — it hits any span covering it). NON-destructive:
  # the covered cells' data reappears once the span is gone.
  def handle_event("unmerge-selection", _params, socket) do
    {c1, c2, r1, r2} = Geometry.selection_rect(socket.assigns.active, socket.assigns.anchor)
    range = Sheets.format_ref({c1, r1}) <> ":" <> Sheets.format_ref({c2, r2})
    op = %{"op" => "unmerge_cells", "tab" => socket.assigns.tab, "range" => range}

    {:noreply,
     socket
     |> Ops.send_ops([op])
     |> assign(active: {c1, r1}, anchor: nil)}
  end

  # Toggle Excel-style freeze panes. When nothing is frozen, freeze ABOVE
  # and LEFT of the active cell ({c, r} → rows r-1, cols c-1); A1 has no
  # rows above / cols left, so freeze the top row (rows 1, cols 0). When
  # anything is frozen, unfreeze (0/0). Rides send_ops so it is undoable.
  def handle_event("freeze-panes", _params, socket) do
    {rows, cols} =
      if socket.assigns.frozen_rows == 0 and socket.assigns.frozen_cols == 0 do
        case socket.assigns.active do
          {1, 1} -> {1, 0}
          {c, r} -> {r - 1, c - 1}
        end
      else
        {0, 0}
      end

    op = %{"op" => "set_frozen", "tab" => socket.assigns.tab, "rows" => rows, "cols" => cols}
    {:noreply, Ops.send_ops(socket, [op])}
  end

  # TSV paste starting at the active cell — values only; per-op errors
  # (cap, bounds) come back on the apply_ops reply as the notice.
  def handle_event("paste", %{"tsv" => tsv}, socket) when is_binary(tsv) do
    {c0, r0} = socket.assigns.active
    tab = socket.assigns.tab
    covered = socket.assigns.covered

    lines =
      case String.split(tsv, ["\r\n", "\n"]) do
        rows -> if List.last(rows) == "", do: Enum.drop(rows, -1), else: rows
      end

    # Skip any target a merge covers — a paste over an xlsx-imported (or
    # Studio-created) merge must not write cells the grid never renders.
    ops =
      for {line, i} <- Enum.with_index(lines),
          {val, j} <- Enum.with_index(String.split(line, "\t")),
          not MapSet.member?(covered, {c0 + j, r0 + i}) do
        ref = Sheets.format_ref({c0 + j, r0 + i})

        if val == "" do
          %{"op" => "clear_cell", "tab" => tab, "ref" => ref}
        else
          %{"op" => "set_cell", "tab" => tab, "ref" => ref, "raw" => Ops.parse_raw(val)}
        end
      end

    {:noreply, Ops.send_ops(socket, ops)}
  end

  # ── events: collaborator presence (M4) ───────────────────────────────────

  # The hook's client-throttled (~10/s) cursor/selection frame. Refs are
  # validated server-side; a malformed frame degrades to nil rather than
  # erroring — presence is advisory, never load-bearing.
  def handle_event("presence-meta", params, socket) do
    active =
      with ref when is_binary(ref) <- params["active"],
           {:ok, pos} <- Sheets.parse_ref(ref) do
        Sheets.format_ref(pos)
      else
        _ -> nil
      end

    selection =
      case Geometry.parse_range(params["selection"]) do
        {:ok, _} -> params["selection"]
        :error -> nil
      end

    {:noreply,
     Ops.push_presence(socket, %{active: active, selection: selection, tab: socket.assigns.tab})}
  end

  # ── events: structure (rows / cols / sizes) ─────────────────────────────

  def handle_event("menu-open", %{"kind" => kind, "index" => index}, socket) do
    key = {if(kind == "col", do: :col, else: :row), to_int(index)}
    {:noreply, assign(socket, menu: if(socket.assigns.menu == key, do: nil, else: key))}
  end

  def handle_event("menu-close", _params, socket) do
    {:noreply, assign(socket, menu: nil)}
  end

  def handle_event("rowcol-insert", %{"kind" => kind, "at" => at, "where" => where}, socket) do
    at = to_int(at) + if(where == "after", do: 1, else: 0)
    op = if kind == "col", do: "insert_cols", else: "insert_rows"

    {:noreply,
     socket
     |> assign(menu: nil)
     |> Ops.send_ops([%{"op" => op, "tab" => socket.assigns.tab, "at" => at, "count" => 1}])}
  end

  def handle_event("rowcol-delete", %{"kind" => kind, "at" => at}, socket) do
    op = if kind == "col", do: "delete_cols", else: "delete_rows"

    {:noreply,
     socket
     |> assign(menu: nil)
     |> Ops.send_ops([
       %{"op" => op, "tab" => socket.assigns.tab, "at" => to_int(at), "count" => 1}
     ])}
  end

  # Keyboard structural editing (Cmd/Ctrl+Alt+= / -, Shift → columns) —
  # operates on the whole rectangular selection, no header-select or menu.
  # Insert lands BEFORE the selection (Excel); op comes from an explicit
  # map, never String.to_atom on client input.
  def handle_event("rowcol-key", %{"kind" => kind, "action" => action}, socket)
      when kind in ["row", "col"] and action in ["insert", "delete"] do
    {c1, c2, r1, r2} = Geometry.selection_rect(socket.assigns.active, socket.assigns.anchor)
    {at, count} = if kind == "row", do: {r1, r2 - r1 + 1}, else: {c1, c2 - c1 + 1}

    op =
      case {kind, action} do
        {"row", "insert"} -> "insert_rows"
        {"row", "delete"} -> "delete_rows"
        {"col", "insert"} -> "insert_cols"
        {"col", "delete"} -> "delete_cols"
      end

    {:noreply,
     socket
     |> assign(menu: nil, anchor: nil)
     |> Ops.send_ops([%{"op" => op, "tab" => socket.assigns.tab, "at" => at, "count" => count}])}
  end

  def handle_event("resize", %{"kind" => kind, "index" => index, "px" => px}, socket) do
    op =
      case kind do
        "col" ->
          %{
            "op" => "set_col_width",
            "tab" => socket.assigns.tab,
            "col" => to_int(index),
            "px" => to_int(px)
          }

        "row" ->
          %{
            "op" => "set_row_height",
            "tab" => socket.assigns.tab,
            "row" => to_int(index),
            "px" => to_int(px)
          }
      end

    {:noreply, Ops.send_ops(socket, [op])}
  end

  # ── events: tab strip ────────────────────────────────────────────────────

  def handle_event("tab-switch", %{"tab" => idx}, socket) do
    idx = to_int(idx)
    count = length(GridData.tabs(socket))

    {:noreply,
     socket
     |> assign(
       tab: idx,
       row_offset: 0,
       active: {1, 1},
       anchor: nil,
       editing: nil,
       menu: nil,
       renaming_tab: nil,
       status: "Sheet #{idx + 1} of #{count}: #{tab_name(socket, idx)}"
     )
     |> GridData.derive_grid()
     |> Ops.push_presence(%{tab: idx, active: "A1", selection: nil, editing: nil})}
  end

  def handle_event("tab-add", _params, socket) do
    n = length(GridData.tabs(socket)) + 1
    {:noreply, Ops.send_ops(socket, [%{"op" => "add_tab", "name" => "Sheet #{n}"}])}
  end

  # ◀ / ▶ move the active tab one slot. The move_tab op reindexes the tab list
  # server-side and broadcasts a :structure delta; Ops.apply_delta remaps @tab
  # so THIS sender (and every other viewer) follows the moved tab. The ends are
  # guarded here too — the button is `disabled` at the edges, this is belt-and-
  # braces. (move_tab lands with the tab-ops slice; the announce is client-side.)
  def handle_event("tab-move", %{"dir" => dir}, socket) when dir in ["left", "right"] do
    from = socket.assigns.tab
    to = if dir == "left", do: from - 1, else: from + 1
    last = length(GridData.tabs(socket)) - 1

    if to < 0 or to > last do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(status: "Moved #{tab_name(socket, from)} #{dir}")
       |> Ops.send_ops([%{"op" => "move_tab", "from" => from, "to" => to}])}
    end
  end

  # Duplicate the active tab. The copy lands right after the source; the viewer
  # deliberately STAYS on the source (apply_delta's remap keeps @tab there —
  # auto-switching to the copy is a later UX call).
  def handle_event("tab-duplicate", _params, socket) do
    {:noreply,
     socket
     |> assign(status: "Duplicated as Copy of #{tab_name(socket, socket.assigns.tab)}")
     |> Ops.send_ops([%{"op" => "duplicate_tab", "tab" => socket.assigns.tab}])}
  end

  def handle_event("tab-rename-start", %{"tab" => idx}, socket) do
    {:noreply, assign(socket, renaming_tab: to_int(idx))}
  end

  def handle_event("tab-rename", %{"tab" => idx, "name" => name}, socket) do
    {:noreply,
     socket
     |> assign(renaming_tab: nil)
     |> Ops.send_ops([%{"op" => "rename_tab", "tab" => to_int(idx), "name" => name}])}
  end

  # Escape (or blur / click-away) abandons an in-progress inline rename.
  def handle_event("tab-rename-cancel", _params, socket) do
    {:noreply, assign(socket, renaming_tab: nil)}
  end

  def handle_event("tab-delete", %{"tab" => idx}, socket) do
    {:noreply, Ops.send_ops(socket, [%{"op" => "delete_tab", "tab" => to_int(idx)}])}
  end

  # ── events: per-user undo/redo (M4) ──────────────────────────────────────

  # The hook's Cmd/Ctrl+Z / Cmd/Ctrl+Shift+Z. Ops.send_ops stamps the user,
  # so the session pops THIS identity's stack; the resulting delta
  # re-renders every client like any other op.
  def handle_event("undo", _params, socket) do
    socket = Ops.send_ops(socket, [%{"op" => "undo"}])
    # A rejection (empty stack) already fired the assertive alert via @notice;
    # only announce the success on the polite channel so the two never overlap.
    status = if socket.assigns.notice == nil, do: "Undid last change", else: ""
    {:noreply, assign(socket, status: status)}
  end

  def handle_event("redo", _params, socket) do
    socket = Ops.send_ops(socket, [%{"op" => "redo"}])
    status = if socket.assigns.notice == nil, do: "Redid change", else: ""
    {:noreply, assign(socket, status: status)}
  end

  # ── events: number-format + cell styling (the toolbar apply-UI) ───────────
  #
  # Each control iterates the current selection and emits ONE display-only
  # `set_cell_meta` per OCCUPIED, non-merge-covered cell (empty + covered cells
  # are skipped up front exactly like `fill` — the op would refuse them anyway).
  # The ops ride `Ops.send_ops`, so undo/redo, the notice, and the delta all
  # reuse the existing path. `fmt` is a whole-selection stamp; B/I are Excel
  # TOGGLES (read the ACTIVE cell, invert once, apply the result to every cell);
  # align sets; bg sets (or clears on "").

  # The $ / % / , buttons + the Fixed/Date/Datetime/General select. "" (General)
  # → nil, which CLEARS the format.
  def handle_event("set-fmt", %{"fmt" => fmt}, socket) do
    fmt = if fmt in ["", "general"], do: nil, else: fmt
    {:noreply, apply_meta_to_selection(socket, fn _cell -> %{"fmt" => fmt} end)}
  end

  # Bold / italic — Excel toggle: the ACTIVE cell decides the new value (its key
  # absent/false → turn ON, true → turn OFF), then that ONE value stamps every
  # selected cell (merging into each cell's own "s" so bg/align survive).
  def handle_event("toggle-style", %{"k" => k}, socket) when k in ["b", "i"] do
    cells = Map.get(GridData.current_tab(socket), "cells") || %{}
    turn_on? = Map.get(active_style(cells, socket.assigns.active), k) != true

    meta_fun = fn cell ->
      s = Map.get(cell, "s") || %{}
      %{"s" => if(turn_on?, do: Map.put(s, k, true), else: Map.delete(s, k))}
    end

    {:noreply, apply_meta_to_selection(socket, meta_fun)}
  end

  def handle_event("set-align", %{"al" => al}, socket) when al in ["left", "center", "right"] do
    meta_fun = fn cell -> %{"s" => Map.put(Map.get(cell, "s") || %{}, "al", al)} end
    {:noreply, apply_meta_to_selection(socket, meta_fun)}
  end

  # A fixed-swatch bg (or "" to clear). No free-form picker in v1.
  def handle_event("set-bg", %{"bg" => bg}, socket) do
    meta_fun = fn cell ->
      s = Map.get(cell, "s") || %{}
      %{"s" => if(bg == "", do: Map.delete(s, "bg"), else: Map.put(s, "bg", bg))}
    end

    {:noreply, apply_meta_to_selection(socket, meta_fun)}
  end

  # ── events: chrome ───────────────────────────────────────────────────────

  def handle_event("toggle-mode", _params, socket) do
    {:noreply,
     socket
     |> assign(
       mode: if(socket.assigns.mode == :edit, do: :view, else: :edit),
       editing: nil,
       menu: nil
     )
     |> GridData.derive_editable()}
  end

  def handle_event("notice-dismiss", _params, socket) do
    {:noreply, assign(socket, notice: nil)}
  end

  # ── selection/commit helpers (grouped below the handle_event clauses) ──

  defp commit_clickaway(socket, params) do
    socket =
      case params["commit"] do
        draft when is_binary(draft) and socket.assigns.editing != nil ->
          socket
          |> Ops.commit(socket.assigns.active, draft)
          |> Ops.push_presence(%{editing: nil})

        _ ->
          socket
      end

    case params["bar_commit"] do
      draft when is_binary(draft) ->
        socket
        |> Ops.commit(socket.assigns.active, draft)
        |> Ops.push_presence(%{editing: nil})

      _ ->
        socket
    end
  end

  # One set_cell_meta per occupied, non-covered cell in the selection rect;
  # `meta_fun.(cell)` yields the "fmt"/"s" keys to merge onto the op.
  defp apply_meta_to_selection(socket, meta_fun) do
    {c1, c2, r1, r2} = Geometry.selection_rect(socket.assigns.active, socket.assigns.anchor)
    cells = Map.get(GridData.current_tab(socket), "cells") || %{}
    covered = socket.assigns.covered
    tab = socket.assigns.tab

    ops =
      for c <- c1..c2,
          r <- r1..r2,
          not MapSet.member?(covered, {c, r}),
          ref = Sheets.format_ref({c, r}),
          cell = Map.get(cells, ref),
          not is_nil(cell) do
        Map.merge(%{"op" => "set_cell_meta", "tab" => tab, "ref" => ref}, meta_fun.(cell))
      end

    Ops.send_ops(socket, ops)
  end

  # The active cell's "s" style map (empty when the cell or its style is
  # absent) — drives B/I toggle direction and the toolbar's aria-pressed.
  defp active_style(cells, active),
    do: Map.get(Map.get(cells, Sheets.format_ref(active)) || %{}, "s") || %{}

  # Carry the source cell's number format + style onto each filled target —
  # ALWAYS both keys (nil when the source has none) so a stale target format
  # is cleared, Excel's fill semantics.
  defp stamp_meta(op, src_cell) do
    Map.merge(op, %{"fmt" => Map.get(src_cell, "fmt"), "s" => Map.get(src_cell, "s")})
  end

  # ── screen-reader status ─────────────────────────────────────────────────

  # Announce a committed cell on the polite live region (`@status`) so a
  # keyboard/SR user hears that the edit landed AND what it computed to — a
  # formula speaks its result, not "=SUM(...)". Only on success: a per-op
  # rejection already fired the assertive alert (`@notice`), so we clear the
  # polite channel to keep the two from double-speaking. The committed value
  # is read straight from the session (authoritative post-recompute) because
  # the delta that patches `@content` arrives asynchronously — this handler's
  # own assigns still carry the pre-commit value.
  # The read-only reader must never peek the live (draft) Session — a forged
  # commit event would otherwise leak draft cell values through @status. Fail
  # closed: return the socket untouched so committed_display is never reached.
  defp announce_commit(%{assigns: %{read_only: true}} = socket, _pos), do: socket

  defp announce_commit(socket, pos) do
    if socket.assigns.notice == nil do
      ref = Sheets.format_ref(pos)
      assign(socket, status: "#{ref}: #{committed_display(socket, ref)}")
    else
      assign(socket, status: "")
    end
  end

  defp committed_display(socket, ref) do
    with {:ok, content} <- Session.peek(socket.assigns.slug, socket.assigns.dataset),
         tab when is_map(tab) <- Enum.at(Map.get(content, "tabs") || [], socket.assigns.tab),
         cells when is_map(cells) <- Map.get(tab, "cells") do
      Cells.display(Map.get(cells, ref))
    else
      _ -> ""
    end
  end

  # ── nav helpers ───────────────────────────────────────────────────────────

  # `{cols, row_lo, row_hi}` — column extent + the CURRENT row window's bounds
  # (from `row_range`). Clamping to the window (not row 1..rows) keeps the
  # active cell on the visible page as it moves; paging is what crosses pages.
  defp move_bounds(socket) do
    range = socket.assigns.row_range
    {socket.assigns.cols, range.first, range.last}
  end

  defp move(pos, nil, _bounds), do: pos

  defp move({c, r}, key, {cols, row_lo, row_hi}) do
    case key do
      "ArrowUp" -> {c, max(r - 1, row_lo)}
      "ArrowDown" -> {c, min(r + 1, row_hi)}
      "ArrowLeft" -> {max(c - 1, 1), r}
      "ArrowRight" -> {min(c + 1, cols), r}
      "Home" -> {1, r}
      "End" -> {cols, r}
      "PageUp" -> {c, max(r - 20, row_lo)}
      "PageDown" -> {c, min(r + 20, row_hi)}
      _ -> {c, r}
    end
  end

  defp move_key("down"), do: "ArrowDown"
  defp move_key("up"), do: "ArrowUp"
  defp move_key("right"), do: "ArrowRight"
  defp move_key("left"), do: "ArrowLeft"
  defp move_key(_), do: nil

  # The tab's display name (falls back to the 1-based default) — used for the
  # polite-region announcements on switch / move / duplicate.
  defp tab_name(socket, idx) do
    case Enum.at(GridData.tabs(socket), idx) do
      %{"name" => name} when is_binary(name) and name != "" -> name
      _ -> "Sheet #{idx + 1}"
    end
  end

  defp to_int(i) when is_integer(i), do: i

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _rest} -> i
      :error -> 0
    end
  end

  # The presence overlay — absolutely positioned boxes inside .sheet-scroll,
  # painting cursor outlines (inset shadow + name tag) and selection rects
  # (translucent fill) OVER the table without ever touching its assigns.
  # pointer-events: none (CSS), so clicks fall through to the cells.
  defp peer_layer(assigns) do
    ~H"""
    <div :if={@cursors != [] or @sels != []} class="sheet-peer-layer" data-test-id="sheet-peer-layer">
      <div
        :for={sel <- @sels}
        class="sheet-peer-sel"
        data-peer-range={sel.range}
        style={"left: #{sel.left}px; top: #{sel.top}px; width: #{sel.w}px; height: #{sel.h}px; background: #{Geometry.rgba(sel.color, 0.12)};"}
      >
      </div>
      <div
        :for={cur <- @cursors}
        class="sheet-peer-cursor"
        data-peer-cell={cur.ref}
        style={"left: #{cur.left}px; top: #{cur.top}px; width: #{cur.w}px; height: #{cur.h}px; box-shadow: inset 0 0 0 2px #{cur.peer.color};"}
      >
        <span
          class={"sheet-peer-tag" <> if(cur.peer.editing, do: " sheet-peer-editing", else: "")}
          style={"background: #{cur.peer.color};"}
          data-test-id="sheet-peer-tag"
        ><%= cur.peer.name %></span>
      </div>
    </div>
    """
  end

  # ── render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    # ONLY the presence-derived assigns are computed here — they change on
    # (almost) every presence frame and feed nothing but the tiny overlay
    # layer. Everything the grid body needs is persisted by
    # GridData.derive_grid/1 (see its comment for why render-local assigns
    # would break tracking).
    {peer_cursors, peer_sels} =
      assigns.presences
      |> Geometry.grid_peers(assigns.user_id, assigns.tab)
      |> Geometry.peer_boxes(assigns.cols, assigns.rows, assigns.col_widths, assigns.row_heights)

    # Selection aggregate for the status bar — render-local for the SAME
    # reason as peer_cursors above: it changes on every selection event and
    # feeds only the footer, so persisting it would re-mark the grid body.
    # Cost is bounded by the sparse-cells iteration under the render cap.
    sel_stats =
      if assigns.editable,
        do:
          Cells.sel_stats(assigns.cells, Geometry.selection_rect(assigns.active, assigns.anchor))

    # The active cell's style drives the B/I toggle's aria-pressed — render-
    # local (changes on every cursor move, feeds only the toolbar).
    active_s = if assigns.editable, do: active_style(assigns.cells, assigns.active), else: %{}

    assigns =
      assign(assigns,
        peer_cursors: peer_cursors,
        peer_sels: peer_sels,
        sel_stats: sel_stats,
        active_s: active_s
      )

    ~H"""
    <div
      id={@id}
      class={"editor-panel sheet-editor" <> if(@read_only, do: " sheet-reader", else: "")}
      data-test-id={if @read_only, do: "sheet-reader", else: "studio-sheet-editor"}
    >
      <.document_header :if={not @read_only} dataset={@dataset} title={@doc.title || @slug}>
        <:status_pill>
          <span class={"badge badge-#{if @is_draft, do: "draft", else: "published"}"}>
            <%= if @is_draft, do: "draft", else: "published" %>
          </span>
        </:status_pill>
        <:actions>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="toggle-mode"
            phx-target={@myself}
            data-test-id="sheet-mode-toggle"
          >
            <.icon name={if @editable, do: "eye", else: "pencil"} size={14} />
            <%= if @editable, do: "View", else: "Edit" %>
          </button>
        </:actions>
      </.document_header>

      <div :if={@editable} class="sheet-toolbar" data-test-id="sheet-toolbar">
        <form phx-submit="name-jump" phx-target={@myself}>
          <input
            name="ref"
            type="text"
            class="sheet-namebox-input"
            value={Sheets.format_ref(@active)}
            autocomplete="off"
            aria-label="Cell reference (name box)"
            data-test-id="sheet-namebox"
          />
        </form>
        <form class="sheet-bar-form" phx-submit="bar-commit" phx-target={@myself}>
          <input
            name="value"
            type="text"
            class="sheet-bar-input"
            value={Cells.bar_value(@cells, @active)}
            data-raw={Cells.bar_value(@cells, @active)}
            autocomplete="off"
            spellcheck="false"
            placeholder="Enter a value or =FORMULA"
            aria-label={"Formula bar for " <> Sheets.format_ref(@active)}
            list={"#{@id}-fns"}
            data-test-id="sheet-formula-bar"
          />
          <%!-- Native datalist autocomplete for the formula bar. A datalist
                matches an option against the WHOLE input value, so the option
                value is the full "=NAME(" prefix — typing "=SU" then matches
                "=SUM(" (a bare "SUM" would never match after the "="). This is
                start-of-formula help only; in-cell editing is superseded by the
                JS-filtered combobox dropdown below. --%>
          <datalist id={"#{@id}-fns"} data-test-id="sheet-fns-list">
            <option :for={name <- @fn_names} value={"=" <> name <> "("} label={name}></option>
          </datalist>
        </form>
        <button
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="merge-selection"
          phx-target={@myself}
          title="Merge the selected cells"
          data-test-id="sheet-merge-btn"
        >
          Merge
        </button>
        <button
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="unmerge-selection"
          phx-target={@myself}
          title="Unmerge cells in the selection"
          data-test-id="sheet-unmerge-btn"
        >
          Unmerge
        </button>
        <button
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="freeze-panes"
          phx-target={@myself}
          title="Freeze rows/cols above and left of the active cell"
          data-test-id="sheet-freeze-toggle"
        >
          <%= if @frozen_rows == 0 and @frozen_cols == 0, do: "Freeze", else: "Unfreeze" %>
        </button>

        <%!-- Number-format group ($ % , + a General/Fixed/Date/Datetime select).
              Each stamps a display-only "fmt" onto every occupied cell in the
              selection; General clears it. --%>
        <div class="sheet-fmt-group" role="group" aria-label="Number format" data-test-id="sheet-fmt-group">
          <button type="button" class="btn btn-ghost btn-sm" phx-click="set-fmt" phx-value-fmt="currency" phx-target={@myself} title="Currency ($1,234.50)" data-test-id="sheet-fmt-currency">$</button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="set-fmt" phx-value-fmt="percent" phx-target={@myself} title="Percent (25.00%)" data-test-id="sheet-fmt-percent">%</button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="set-fmt" phx-value-fmt="thousands" phx-target={@myself} title="Thousands separator (1,234)" data-test-id="sheet-fmt-thousands">,</button>
          <form phx-change="set-fmt" phx-target={@myself}>
            <select name="fmt" class="sheet-fmt-select" aria-label="Number format class" data-test-id="sheet-fmt-select">
              <option value="">General</option>
              <option value="fixed">Fixed</option>
              <option value="date">Date</option>
              <option value="datetime">Datetime</option>
            </select>
          </form>
        </div>

        <%!-- Style group: B / I toggles (aria-pressed off the active cell),
              the align trio, and a fixed bg swatch palette + clear. --%>
        <div class="sheet-style-group" role="group" aria-label="Cell style" data-test-id="sheet-style-group">
          <button type="button" class="btn btn-ghost btn-sm" phx-click="toggle-style" phx-value-k="b" phx-target={@myself} aria-pressed={to_string(Map.get(@active_s, "b") == true)} title="Bold (Cmd/Ctrl+B)" data-test-id="sheet-style-bold"><strong>B</strong></button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="toggle-style" phx-value-k="i" phx-target={@myself} aria-pressed={to_string(Map.get(@active_s, "i") == true)} title="Italic (Cmd/Ctrl+I)" data-test-id="sheet-style-italic"><em>I</em></button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="set-align" phx-value-al="left" phx-target={@myself} title="Align left" data-test-id="sheet-align-left">⯇</button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="set-align" phx-value-al="center" phx-target={@myself} title="Align center" data-test-id="sheet-align-center">≡</button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="set-align" phx-value-al="right" phx-target={@myself} title="Align right" data-test-id="sheet-align-right">⯈</button>
          <span class="sheet-bg-swatches" role="group" aria-label="Cell background">
            <button
              :for={swatch <- ~w(#fde68a #bbf7d0 #bfdbfe #fecaca #e9d5ff #e5e7eb)}
              type="button"
              class="sheet-bg-swatch"
              style={"background: #{swatch};"}
              phx-click="set-bg"
              phx-value-bg={swatch}
              phx-target={@myself}
              title={"Background " <> swatch}
              data-test-id={"sheet-bg-" <> String.trim_leading(swatch, "#")}
            >
            </button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="set-bg" phx-value-bg="" phx-target={@myself} title="Clear background" data-test-id="sheet-bg-clear">⌫</button>
          </span>
        </div>

        <%!-- Visible undo/redo — the ghost buttons a MOUSE user needs; they
              phx-click the SAME "undo"/"redo" events the keyboard fires, so
              zero new server logic. --%>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="undo" phx-target={@myself} title="Undo (Cmd/Ctrl+Z)" data-test-id="sheet-undo-btn">↶</button>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="redo" phx-target={@myself} title="Redo (Cmd/Ctrl+Shift+Z)" data-test-id="sheet-redo-btn">↷</button>
      </div>

      <%!-- role="alert" is an implicit assertive live region; because this div
            is INSERTED when @notice flips non-nil, the alert fires on insertion
            — the one pattern where a conditionally-rendered region announces. --%>
      <div :if={@notice} class="sheet-notice" role="alert" data-test-id="sheet-notice">
        <span><%= @notice %></span>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="notice-dismiss" phx-target={@myself}>
          dismiss
        </button>
      </div>

      <%!-- The polite SR status channel: ALWAYS rendered (never inside :if) so
            LiveView morphdom patches only its text and the aria-live region
            re-announces. Success/nav updates land here; per-op rejections take
            the assertive @notice above. Remote collaborator deltas are NOT
            announced here (deliberate — it would flood a screen reader). --%>
      <div class="sheet-sr-status" aria-live="polite" data-test-id="sheet-status">{@status}</div>

      <%!-- Row pager + column-clip notice. A PLAIN div (no aria-live — the
            polite @status region above speaks the range on a page-flip);
            rendered for editable AND read-only. `rows-page` is pure navigation
            (see the handler), so the reader pages without a session. When only
            the columns are clipped (single page), just the column sentence
            shows — no buttons. --%>
      <div
        :if={@row_offset > 0 or @row_page_end < @rows or @col_truncated}
        class="sheet-pager"
        data-test-id="sheet-pager"
      >
        <%= if @row_offset > 0 or @row_page_end < @rows do %>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="rows-page"
            phx-value-dir="prev"
            phx-target={@myself}
            disabled={@row_offset == 0}
            data-test-id="sheet-pager-prev"
          >Prev</button>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="rows-page"
            phx-value-dir="next"
            phx-target={@myself}
            disabled={@row_page_end >= @rows}
            data-test-id="sheet-pager-next"
          >Next</button>
          <span data-test-id="sheet-pager-text">
            Showing rows <%= @row_range.first %>–<%= @row_range.last %> of <%= @rows %><%= if @col_truncated do %> · first <%= @cols %> of <%= @used_cols %> columns<% end %>
          </span>
        <% else %>
          <span data-test-id="sheet-pager-text">
            Showing the first <%= @cols %> of <%= @used_cols %> columns
          </span>
        <% end %>
      </div>

      <%!-- ONE wrapper for both modes (id + hook flip with @editable, so a
            mode toggle still remounts the hook) and the peer layer OUTSIDE
            the if-block: an `if` block is a single tracked dynamic whose
            dependencies are everything inside it — peer assigns in there
            would make every presence frame re-render the whole grid body
            (measured ~15ms extra; see the moduledoc). --%>
      <div
        id={if @editable, do: "#{@id}-grid", else: "#{@id}-grid-view"}
        class="sheet-grid-wrap"
        phx-hook={if @editable, do: "SheetGrid"}
        tabindex="0"
        role={if @editable, do: "application"}
        aria-label="Spreadsheet grid"
        aria-describedby={@editable && "#{@id}-grid-instructions"}
        aria-activedescendant={@editable && Cells.cell_dom_id(@id, @active)}
        data-fns={@editable && Enum.join(@fn_names, " ")}
        data-row-offset={@row_offset}
      >
        <%!-- WCAG 2.1.2: the grid traps Tab (it walks the selection). This
              hidden note tells a keyboard/AT user the one-shot escape hatch —
              Escape then Tab falls through to the browser (see the hook). --%>
        <span
          :if={@editable}
          id={"#{@id}-grid-instructions"}
          class="sr-only"
          style="position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0;"
        >
          Press Escape then Tab to leave the grid; F2 or Enter to edit the cell;
          Ctrl+Alt+= inserts rows, Ctrl+Alt+- deletes.
        </span>
        <div class="sheet-scroll">
          <%= if @editable do %>
            <.sheet_table
              id={@id}
              cols={@cols}
              rows={@rows}
              row_range={@row_range}
              cells={@cells}
              spans={@spans}
              covered={@covered}
              col_widths={@col_widths}
              row_heights={@row_heights}
              frozen_cols={@frozen_cols}
              frozen_rows={if @row_offset == 0, do: @frozen_rows, else: 0}
              sel={Geometry.grid_sel(@active, @anchor, @read_only)}
              active={@active}
              editing={@editing}
              menu={@menu}
              editable={true}
              myself={@myself}
            />
          <% else %>
            <.sheet_table
              id={"#{@id}-view"}
              cols={@cols}
              rows={@rows}
              row_range={@row_range}
              cells={@cells}
              spans={@spans}
              covered={@covered}
              col_widths={@col_widths}
              row_heights={@row_heights}
              frozen_cols={@frozen_cols}
              frozen_rows={if @row_offset == 0, do: @frozen_rows, else: 0}
              sel={Geometry.grid_sel(@active, @anchor, @read_only)}
              active={Geometry.grid_cursor(@active, @read_only)}
              editing={nil}
              menu={nil}
              editable={false}
              myself={nil}
            />
          <% end %>
          <%!-- v1: the peer overlay's px geometry sums from row 1, so it is
                only correct on page 0 — render it there alone (see moduledoc). --%>
          <.peer_layer :if={@row_offset == 0} cursors={@peer_cursors} sels={@peer_sels} />
        </div>
      </div>

      <%!-- role="tablist"/"tab" wires the strip for screen readers. Roving
            tabindex is deferred — every tab stays natively tab-focusable. --%>
      <div class="sheet-tabs" data-test-id="sheet-tabs" role="tablist" aria-label="Sheet tabs">
        <%= for {t, i} <- Enum.with_index(@all_tabs) do %>
          <%= if @editable and @renaming_tab == i do %>
            <form phx-submit="tab-rename" phx-target={@myself} style="display: inline-flex;">
              <input type="hidden" name="tab" value={i} />
              <input
                name="name"
                type="text"
                value={Map.get(t, "name") || "Sheet #{i + 1}"}
                class="sheet-tab-rename-input"
                autocomplete="off"
                aria-label={"Rename #{Map.get(t, "name") || "Sheet #{i + 1}"}"}
                phx-keydown="tab-rename-cancel"
                phx-key="Escape"
                phx-blur="tab-rename-cancel"
                phx-target={@myself}
                data-test-id="sheet-tab-rename-input"
              />
            </form>
          <% else %>
            <button
              type="button"
              role="tab"
              aria-selected={to_string(i == @tab)}
              class={"sheet-tab" <> if(i == @tab, do: " is-active", else: "")}
              phx-click="tab-switch"
              phx-dblclick={@editable && "tab-rename-start"}
              phx-keydown={@editable && "tab-rename-start"}
              phx-key="F2"
              phx-value-tab={i}
              phx-target={@myself}
              data-test-id={"sheet-tab-#{i}"}
            >
              <%= Map.get(t, "name") || "Sheet #{i + 1}" %>
            </button>
          <% end %>
        <% end %>
        <%= if @editable do %>
          <button
            type="button"
            class="sheet-tab"
            phx-click="tab-move"
            phx-value-dir="left"
            phx-target={@myself}
            disabled={@tab == 0}
            aria-label="Move sheet left"
            title="Move sheet left"
            data-test-id="sheet-tab-move-left"
          >&#9664;</button>
          <button
            type="button"
            class="sheet-tab"
            phx-click="tab-move"
            phx-value-dir="right"
            phx-target={@myself}
            disabled={@tab >= length(@all_tabs) - 1}
            aria-label="Move sheet right"
            title="Move sheet right"
            data-test-id="sheet-tab-move-right"
          >&#9654;</button>
          <button
            type="button"
            class="sheet-tab"
            phx-click="tab-add"
            phx-target={@myself}
            title="Add tab"
            data-test-id="sheet-tab-add"
          >+</button>
          <button
            type="button"
            class="sheet-tab"
            phx-click="tab-duplicate"
            phx-target={@myself}
            aria-label="Duplicate the active tab"
            title="Duplicate the active tab"
            data-test-id="sheet-tab-duplicate"
          >&#10697;</button>
          <button
            type="button"
            class="sheet-tab"
            phx-click="tab-delete"
            phx-value-tab={@tab}
            phx-target={@myself}
            data-confirm="Delete this tab? Its cells are removed."
            title="Delete the active tab"
            data-test-id="sheet-tab-delete"
          >&times;</button>
        <% end %>
      </div>

      <div :if={@sel_stats} class="sheet-statsbar" data-test-id="sheet-statsbar">
        Sum: {Sheets.number_to_display(@sel_stats.sum)} · Avg: {Sheets.number_to_display(@sel_stats.avg)} · Count: {@sel_stats.count}
      </div>
    </div>
    """
  end

  @doc """
  The shared table renderer — the edit grid and the read-only View render
  the SAME markup; `editable={false}` drops every editing affordance
  (menus, resize handles, the in-cell input). Collaborator presence never
  renders here — it lives on the sibling overlay layer (`peer_layer/1`),
  so a presence frame cannot re-render the grid body (see the moduledoc).
  """
  def sheet_table(assigns) do
    ~H"""
    <table
      class="sheet-table"
      data-test-id="sheet-table"
      role="grid"
      aria-readonly={!@editable && "true"}
      aria-rowcount={@rows}
      aria-colcount={@cols}
    >
      <colgroup>
        <col style="width: 44px;" />
        <col :for={c <- 1..@cols} style={"width: #{Geometry.col_px(@col_widths, c)}px;"} />
      </colgroup>
      <thead>
        <tr>
          <th class="sheet-corner"></th>
          <th
            :for={c <- 1..@cols}
            class="sheet-colhead"
            style={Cells.col_head_style(c, @frozen_cols, @col_widths)}
            data-c={c}
          >
            <%= Geometry.col_letters(c) %>
            <%= if @editable do %>
              <button
                type="button"
                class="sheet-head-menu-btn"
                phx-click="menu-open"
                phx-value-kind="col"
                phx-value-index={c}
                phx-target={@myself}
                data-test-id={"sheet-colmenu-#{c}"}
              >&#9662;</button>
              <div :if={@menu == {:col, c}} class="sheet-menu" data-test-id="sheet-menu">
                <button type="button" phx-click="rowcol-insert" phx-value-kind="col" phx-value-at={c} phx-value-where="before" phx-target={@myself}>Insert left</button>
                <button type="button" phx-click="rowcol-insert" phx-value-kind="col" phx-value-at={c} phx-value-where="after" phx-target={@myself}>Insert right</button>
                <button type="button" phx-click="rowcol-delete" phx-value-kind="col" phx-value-at={c} phx-target={@myself}>Delete column</button>
              </div>
              <div class="sheet-rsz sheet-rsz--col" data-kind="col" data-index={c} data-px={Geometry.col_px(@col_widths, c)}></div>
            <% end %>
          </th>
        </tr>
      </thead>
      <tbody>
        <tr
          :for={r <- @row_range}
          aria-rowindex={r}
          style={"height: #{Geometry.row_px(@row_heights, r)}px;"}
        >
          <th
            class="sheet-rowhead"
            style={Cells.row_head_style(r, @frozen_rows, @row_heights)}
            data-r={r}
          >
            <%= r %>
            <%= if @editable do %>
              <button
                type="button"
                class="sheet-head-menu-btn"
                phx-click="menu-open"
                phx-value-kind="row"
                phx-value-index={r}
                phx-target={@myself}
                data-test-id={"sheet-rowmenu-#{r}"}
              >&#9662;</button>
              <div :if={@menu == {:row, r}} class="sheet-menu" data-test-id="sheet-menu">
                <button type="button" phx-click="rowcol-insert" phx-value-kind="row" phx-value-at={r} phx-value-where="before" phx-target={@myself}>Insert above</button>
                <button type="button" phx-click="rowcol-insert" phx-value-kind="row" phx-value-at={r} phx-value-where="after" phx-target={@myself}>Insert below</button>
                <button type="button" phx-click="rowcol-delete" phx-value-kind="row" phx-value-at={r} phx-target={@myself}>Delete row</button>
              </div>
              <div class="sheet-rsz sheet-rsz--row" data-kind="row" data-index={r} data-px={Geometry.row_px(@row_heights, r)}></div>
            <% end %>
          </th>
          <%= for c <- 1..@cols, not MapSet.member?(@covered, {c, r}) do %>
            <% ref = Geometry.col_letters(c) <> Integer.to_string(r) %>
            <% cell = Map.get(@cells, ref) %>
            <% span = Map.get(@spans, {c, r}) %>
            <td
              id={Cells.cell_dom_id(@id, {c, r})}
              class={Cells.cell_class(c, r, @sel, @active, cell)}
              aria-selected={Cells.aria_selected(@sel, c, r)}
              data-ref={ref}
              data-r={r}
              data-c={c}
              data-v={Cells.data_v(cell)}
              colspan={span && elem(span, 0) > 1 && elem(span, 0)}
              rowspan={span && elem(span, 1) > 1 && elem(span, 1)}
              style={Cells.cell_style(c, r, @frozen_cols, @frozen_rows, @col_widths, @row_heights, cell)}
            >
              <%= if @editable and @editing != nil and @active == {c, r} do %>
                <input
                  id={"#{@id}-cell-input"}
                  class="sheet-cell-input"
                  type="text"
                  value={@editing.prefill}
                  autocomplete="off"
                  spellcheck="false"
                  aria-label={"Edit cell " <> ref}
                  role="combobox"
                  aria-autocomplete="list"
                  aria-expanded="false"
                  data-test-id="sheet-cell-input"
                />
              <% else %>
                <span class="sheet-cell-v"><%= Cells.display(cell) %></span>
              <% end %>
            </td>
          <% end %>
        </tr>
      </tbody>
    </table>
    """
  end
end
