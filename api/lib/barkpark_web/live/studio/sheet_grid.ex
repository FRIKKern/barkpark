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
      `cell_class/5`, `cell_style/8`) the render template stamps per `<td>`.
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
  (`data-ref`/`data-r`; `aria-rowindex`/`aria-colindex` are 1-based INCLUDING
  the gutter header row/column, per APG — so cell `r`/`c` render as `r+1`/`c+1`
  and merge-skipped tds keep their true index). `aria-rowcount`/`aria-colcount`
  report the TRUE occupied extent (`rows_total`/`cols_total`, +1 for the
  gutter). The axes differ: rows are fully PAGED, so `rows_total` is the whole
  logical height (`rows`) and the last page's `aria-rowindex` never exceeds
  `aria-rowcount`; columns are a NOTICE-ONLY clip (no horizontal paging), so
  `cols_total` falls back to `used_cols` and AT never hears the ≤64 rendered
  window as the whole sheet.
  v1 limitations recorded here: row-sticky frozen rows + the peer overlay
  render only on page 0 (frozen COLS pin on every page); columns past
  `@max_cols` (64) are a NOTICE-ONLY clip surfaced in the pager text (no
  horizontal paging); and a merge whose rowspan crosses a page boundary does
  NOT visually continue onto the next page — its covered cells there render as
  plain (empty) cells so column alignment holds
  (`GridData.release_boundary_covered/3`).
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

  ## THREE PROPS, THREE AXES — every host MUST pass all three

  There used to be ONE prop (`read_only`) doing three unrelated jobs, and a
  wave-42 run measured what that cost: a Studio member entitled to READ a
  sheet was served the PUBLISHED row while a colleague with write held the
  live draft session open — two people, one sheet, different numbers. The
  flag has been split along the three axes it was conflating:

    * `write_capable` — AUTHORIZATION. May this principal mutate the sheet?
      Gates the eight write heads, `Ops.send_ops/2`, and (derived, never a
      fourth prop) `@editable`, which fans the write affordances out across
      the template. DEFAULTS FALSE: a host that omits it gets a grid nobody
      can write through, which is the only safe direction to fail.

    * `live_session` — LIVENESS / CONTENT SOURCE. May this principal see
      DRAFT bytes? True: `Session.peek` backs the cold open, `{:sheets_op,…}`
      deltas apply, persist frames show, `announce_commit/2` may read the
      session. False: `@doc.content` (the published perspective) only, every
      read path sealed independently. DEFAULTS FALSE.

    * `chrome` — PRESENTATION. `:studio` (document header, editor identity,
      selection highlight, keyboard navigation) or `:reader` (the bare
      published grid at `/sheets/:slug`). Carries NO authority.

  The axes are independent ON PURPOSE. `live_session` is NOT a function of
  `chrome`: the reader's liveness is off for a SECURITY reason (a draft-backed
  session must not stream to an anonymous principal), so deriving it from
  chrome would make `BARKPARK_PUBLIC_DEMO_STUDIO` — Studio chrome on a
  principal-less socket — a permanent draft leak by design. Equally,
  `write_capable` is NOT chrome: keying the navigation heads on it would
  freeze keyboard navigation for a member entitled to use it.

  ## Why the capability must arrive as a PROP

  A `phx-target`ed event carries a component cid, and LiveView runs the
  COMPONENT socket's lifecycle for it — the parent socket's `:handle_event`
  hooks (the Studio `Caps` deny-gate among them) are never consulted. So no
  hook on the host LiveView can gate this surface; the host's write capability
  has to arrive HERE. Both hosts pass all three props: the `/sheets/:slug`
  reader passes `{false, false, :reader}`, Studio passes
  `{sheet_write_capable?(assigns), true, :studio}`
  (`grep -n 'sheet_write_capable?' lib/barkpark_web/live/studio/studio_live/components.ex`).

  ## The three shapes this component renders

  | host | write_capable | live_session | chrome |
  |---|---|---|---|
  | Studio, write-capable member | true | true | :studio |
  | Studio, write-DENIED member  | false | true | :studio |
  | `/sheets/:slug` public reader | false | false | :reader |

  The public reader gets the bare published grid: no document header, no
  formula bar, no hook, no menus, no active-cell highlight — the tab strip
  keeps ONLY its switch buttons. The guard is server-side too:
  `Ops.send_ops/2` drops every mutation without write capability, so a forged
  client event can never write through an unauthenticated mount.

  PUBLISHED-ONLY without `live_session`: content comes from `@doc.content` and
  NEVER from `Session.peek` — a live session is draft-backed, so peeking it
  would leak unpublished edits. Session deltas do NOT apply either: the
  `{:sheets_op, …}` update clause is a no-op (the reader also stops forwarding
  them and stops peeking on refetch — each read path sealed independently,
  fail closed). Such a host refreshes via the `%{published_content: …}` update
  clause when a publish lands.

  READ MODE HAS THE HOOK (wave 43, closing wave 42's one deliberate
  user-facing harm). `phx-hook="SheetGrid"` keys on `@hookable`
  (`chrome == :studio`, derived beside `@editable` in `GridData`), NOT on
  `@editable` — because the hook is the SOLE PRODUCER of selection: cell-click /
  head-click / nav / nav-edge / nav-corner / select-all have no server-rendered
  `phx-click` anywhere. Gating it on `@editable` left a write-DENIED member — and
  a fully write-capable member who flipped the View chip, since `@editable` is
  `mode == :edit and write_capable` — staring at a selection highlight frozen on
  A1 that nothing could move; the TSV copy, which reads `td.sheet-sel`, was
  downstream of that. The three navigation heads already refused only
  `chrome: :reader`, so nothing new is server-side reachable.

  What still governs writes is unchanged: `@editable` fans the write affordances
  out across the template, and `Ops.send_ops/2`'s `write_capable: false` clause
  is the last wall. The client's read-mode allowlist (`READ_MODE_EVENTS` in
  bp-sheet-grid.js, derived from the absent `data-fns`) is a UX-and-honesty
  layer on top of that wall, not the wall — with one behaviour that is its own:
  `edit-start` is the only mutation with no `send_ops` terminus, so dropping it
  client-side is what keeps a read-mode socket from broadcasting "editing A1" to
  every peer while no editor renders.

  THE `/sheets/:slug` READER GETS A DIFFERENT HOOK, NOT THIS ONE
  (`pds-w43-bl-sheetgrid-reader-half`). `Geometry.grid_sel(_, _, :reader)` is
  still `{0, 0, 0, 0}`, so no `<td>` ever carries `sheet-sel` and `SheetGrid`
  would be a silent no-op there. Main ruled on 2026-09-02: the reader gets a
  "client-only selection + copy layer in bp-sheet-grid.js for `:reader` — paints
  its own class, pushes ZERO events, reads `data-v` already on reader tds. An
  anonymous principal never round-trips selection and gains no authority."
  Reversing the chrome policy instead was REJECTED ("it widens the server
  surface for a purely local affordance"). So `phx-hook` reads
  `"SheetReaderSelect"` under `chrome: :reader` — a separate object in
  bp-sheet-grid.js holding its own anchor/active pair, painting `sheet-rsel`
  (never `sheet-sel`), with no `pushEvent` code path at all — while every
  server-side clause here (`grid_sel`, `grid_cursor`, the three navigation-head
  refusals) is unchanged.

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
  alias Barkpark.Plugins.Sheets.CondFormat
  alias Barkpark.Plugins.Sheets.Core, as: Sheets
  alias Barkpark.Plugins.Sheets.Engine
  alias Barkpark.Plugins.Sheets.Session
  alias Barkpark.Plugins.Sheets.Structure
  alias BarkparkWeb.Studio.SheetGrid.{Cells, Filter, Geometry, GridData, Ops}
  alias BarkparkWeb.Studio.StudioLive.Shared
  alias BarkparkWeb.Studio.TokensGen

  # The tokenized Studio control kit (studio-ui-premium): every popover/toolbar
  # form control below rides `bp_select`/`bp_input`/`bp_checkbox` so the sheet
  # editor carries ZERO native/unthemed controls. name=/data-test-id/aria-* pass
  # through the kit's :rest (Phoenix globals) onto the real element, so LiveView
  # form serialization and the pinning tests are unchanged.
  import BarkparkWeb.StudioComponents.Controls

  # Paste preflight bound: a fat-finger whole-column paste (Excel ships up to
  # 1M rows) is refused whole rather than ground through 1000s of serial session
  # calls. Mirrors the client PASTE_CELL_CAP and the session's 50k cell_cap.
  @paste_cell_cap 50_000

  # The conditional-format panel's default rule background — the first toolbar
  # bg swatch, so a freshly-opened form always has a valid #rrggbb selected
  # (the gate requires bg; an empty selection would reject on submit). Sourced
  # from the emitted categorical palette so it stays the first swatch verbatim.
  @cf_default_bg hd(TokensGen.sheet_cf_backgrounds())

  # Per-tab color (QL-D2). The picker offers a saturated preset strip (tab
  # colors read best more vivid than the pastel CELL-bg swatches, so the list
  # is inlined at the swatch loop like set-bg). `CondFormat.valid_bg?/1` (the ONE
  # `#rrggbb` owner, capability:sheets-bg-sanitizer) guards what the swatch/picker
  # will actually render so a legacy/junk stored color (synthesis is lenient — the
  # gate only fires on write) never lands in an inline `style` attribute. The write
  # path is the NEW `set_tab_color` session op (S-SESSION), NOT a raw content
  # patch, so every collaborator sees the same color through the single-writer
  # session.

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
       # Refs of ops THIS editor sent whose delta echo has not come back yet —
       # the session delta carries no author, so this is how the sheets_op
       # handler tells an own echo from a remote collaborator's edit when
       # deciding whether to announce an active-cell change (see send_ops/2).
       own_refs: MapSet.new(),
       # Toolbar save-status indicator (editable hosts only): nil (idle, hidden)
       # → :saving → :saved / :error, driven off the session's persist frames.
       # SEPARATE from @status (the polite live region) so a save announcement
       # never clobbers a cell-commit announcement.
       save_state: nil,
       save_saved_at: nil,
       # Find-in-sheet (Ctrl+F, find-only) state. `find_open` shows the bar in
       # the editor (Ctrl+F opens, Escape closes); the reader shows it always.
       # `find_hits` is the MapSet of matching {c,r} the render highlights —
       # persisted so a presence frame never recomputes it. Pure navigation:
       # the find handlers never touch the session (reader-safe).
       find_open: false,
       find_query: "",
       find_hits: MapSet.new(),
       menu: nil,
       # Conditional-format panel (editable hosts, CF-C stage B): nil = closed;
       # a map = open with the create/edit form prefilled. See cf-open/cf-save.
       cf_panel: nil,
       # Per-viewer FILTER view-state (SF-B, paper §3+§4). `filters` is a
       # `%{col_index => criterion}` map held ONLY on this socket — it never
       # mutates the document, sends no op, and dies with the socket (SF-D2).
       # `filter_panel` is the open funnel editor: nil, or a form map carrying
       # the column being edited (see filter-open/filter-apply).
       filters: %{},
       filter_panel: nil,
       renaming_tab: nil,
       # The tab-color picker popover (editable hosts): false = closed. It
       # colors the ACTIVE tab (@tab), so a tab switch closes it (below).
       tab_color_open: false,
       mode: :edit,
       # The three axes (see the moduledoc). The two that carry authority
       # default CLOSED — a host that forgets them writes nothing and sees no
       # draft byte. `chrome` carries none, so it defaults to this component's
       # home surface; both hosts pass all three explicitly anyway.
       write_capable: false,
       # pds-w42 — the INPUTS the parent's write predicate needs, so this
       # component can re-ask it on its own seam instead of trusting a value
       # computed at the parent's last render. `nil` (the reader host, and any
       # host that does not pass it) keeps the plain `write_capable` answer.
       write_authz: nil,
       live_session: false,
       chrome: :studio,
       user_id: nil,
       presence_topic: nil,
       presences: [],
       fn_names: fn_names(),
       fn_sigs: fn_sigs()
     )}
  end

  # The formula-function vocabulary for autocomplete (the datalist on the
  # formula bar + the in-cell dropdown), stamped once at mount and static
  # thereafter. Canonically it flows from `Engine.function_names/0` (shipped —
  # see `Barkpark.Plugins.Sheets.Engine`) so every engine function (incl.
  # wave-5/6 + the stats batch) surfaces with zero coordination. The inline
  # literal below is a DEFENSIVE fallback for hosts where the Engine module
  # isn't loaded; the `function_exported?` guard transparently prefers the
  # authoritative list.
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

  # The per-function signature index — args (each with `optional`/`variadic`)
  # + a one-line doc, keyed by NAME so the formula-UX client does an O(1)
  # lookup for signature-help + ghost-suggest. Stamped once at mount alongside
  # `fn_names` and flows canonically from `Engine.function_specs/0` (whose
  # drift test pins it 1:1 to `function_names/0`). No `function_exported?`
  # fallback like `fn_names/0` carries: the spec API and this call site landed
  # together, so the cross-slice drift window that guard covered never exists.
  defp fn_sigs do
    Map.new(Engine.function_specs(), fn %{name: name, args: args, doc: doc} ->
      {name, %{args: args, doc: doc}}
    end)
  end

  # A session delta forwarded by StudioLive's `{:sheets_op, …}` handle_info.
  # LIVENESS axis: hosts without `live_session` (the public reader) drop it —
  # session deltas carry unpublished draft edits and must never stream to a
  # principal not entitled to draft bytes. A write-DENIED Studio member IS so
  # entitled, and keeps receiving them.
  @impl true
  def update(%{sheets_op: payload}, socket) do
    if not socket.assigns.live_session do
      {:ok, socket}
    else
      # Any op delta — this editor's own OR a peer's — means the session is
      # now dirty and a persist is pending: flip the indicator to :saving.
      # Doc-level (not per-editor) by design: the whole session is unsaved.
      # Stale/duplicate frames (rev <= ours) are dropped by apply_delta —
      # judge staleness BEFORE applying so they never announce either.
      stale? = payload.rev <= socket.assigns.rev

      socket =
        socket
        |> assign(save_state: :saving)
        |> Ops.apply_delta(payload)
        |> GridData.derive_grid()

      {:ok, if(stale?, do: socket, else: announce_remote_change(socket, payload))}
    end
  end

  # A persist-outcome frame from the session (see Session.broadcast_persisted/2).
  # LIVENESS axis: a host with no live session has no save state to show — it
  # is looking at the published row, which no persist moves. A failed persist reads :error (the
  # session keeps retrying on the debounce). A success reads :saved ONLY when it
  # is not stale — same epoch (nil before the first delta) and a rev at least as
  # new as what this client has rendered; a persist that lands after the client
  # advanced past it stays :saving. Anything else leaves the indicator untouched.
  def update(%{sheets_persisted: p}, socket) do
    cond do
      not socket.assigns.live_session ->
        {:ok, socket}

      p.ok == false ->
        {:ok, assign(socket, save_state: :error)}

      p.ok and socket.assigns.epoch in [nil, p.epoch] and p.rev >= socket.assigns.rev ->
        {:ok, assign(socket, save_state: :saved, save_saved_at: p.saved_at)}

      true ->
        {:ok, socket}
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
          :write_capable,
          :write_authz,
          :live_session,
          :chrome,
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

      # THE PUBLISHED-PERSPECTIVE SWITCH. Keyed on LIVENESS, never on write
      # capability: a live session's memory is authoritative for anyone
      # entitled to draft bytes (the persisted row backs the cold open — the
      # same draft-first row the session itself loads). Without `live_session`
      # (the public reader) NEVER peek — the session is draft-backed, so its
      # memory would leak unpublished edits; content comes from the published
      # `@doc.content` only.
      content =
        if socket.assigns.live_session do
          case Session.peek(slug, assigns.dataset, doc.workspace_id) do
            {:ok, content} -> content
            {:error, :no_session} -> doc.content || %{}
          end
        else
          doc.content || %{}
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

  # A click / Space on a "checkbox"-fmt cell TOGGLES its boolean instead of
  # starting an editor: it commits the opposite value on the normal set_cell
  # path, so the carried "fmt"=>"checkbox" survives (session ops carry meta on
  # retype), undo/redo and LWW ride for free. Read-only hosts drop the commit
  # in `Ops.send_ops`, so a forged event can never mutate the reader.
  def handle_event("cell-toggle", %{"ref" => ref}, socket) do
    case Sheets.parse_ref(ref) do
      {:ok, pos} ->
        cells = Map.get(GridData.current_tab(socket), "cells") || %{}
        cell = Map.get(cells, ref) || %{}

        # FORMULA GUARD: a checkbox-fmt cell that ALSO holds a formula renders as
        # a toggle (checkbox? keys off fmt alone), but committing TRUE/FALSE rides
        # set_cell — which preserves fmt/s on retype but REPLACES the value, so the
        # "f" is dropped and the formula is silently destroyed. Refuse (mirroring
        # Google Sheets' formula-checkbox guard): move the selection, emit no op.
        if Map.has_key?(cell, "f") do
          {:noreply,
           socket
           |> assign(active: pos, anchor: nil, editing: nil, menu: nil)
           |> assign(notice: "can't toggle a checkbox that holds a formula")}
        else
          next = if Map.get(cell, "v") == true, do: "FALSE", else: "TRUE"

          socket =
            socket
            |> assign(active: pos, anchor: nil, editing: nil, menu: nil)
            |> commit(pos, next)

          {:noreply, socket}
        end

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
    active = move(socket.assigns.active, key, move_vis(socket))
    anchor = if params["shift"], do: socket.assigns.anchor || socket.assigns.active, else: nil
    {:noreply, assign(socket, active: active, anchor: anchor, editing: nil, menu: nil)}
  end

  # Ctrl/Cmd+A — select the USED range (v1; Excel's second Ctrl+A, the whole
  # sheet, is deferred). Active snaps to the window's top-left and the anchor
  # to the used range's last cell, so `selection_rect` spans the data.
  #
  # CHROME AXIS, NOT AUTHORIZATION: this mutates only @active/@anchor — no op,
  # no document byte — so it pairs with `Geometry.grid_sel/3`, whose `:reader`
  # branch suppresses the highlight this would move. Keying it on
  # `write_capable` would freeze keyboard navigation for a member entitled to
  # read the sheet.
  def handle_event("select-all", _params, %{assigns: %{chrome: :reader}} = socket),
    do: {:noreply, socket}

  def handle_event("select-all", _params, socket) do
    {cols, row_lo, row_hi} = move_bounds(socket)

    anchor = {
      socket.assigns.used_cols |> max(1) |> min(cols),
      socket.assigns.used_rows |> max(1) |> max(row_lo) |> min(row_hi)
    }

    {:noreply, assign(socket, active: {1, row_lo}, anchor: anchor, editing: nil, menu: nil)}
  end

  # Ctrl/Cmd+Arrow — Excel's data-edge jump (`Geometry.data_edge`): from a
  # filled cell, the last filled cell before the next gap; from an empty cell
  # or a run's end, the next filled cell; nothing ahead, the grid edge. Shift
  # extends the selection to the edge target (Ctrl+Shift+Arrow). The target
  # row clamps into the rendered row window — the same honest bound `move`
  # uses; paging is what crosses pages.
  # Chrome axis (see select-all): pure selection state, no op.
  def handle_event("nav-edge", _params, %{assigns: %{chrome: :reader}} = socket),
    do: {:noreply, socket}

  def handle_event("nav-edge", %{"dir" => dir} = params, socket)
      when dir in ["up", "down", "left", "right"] do
    cols = socket.assigns.cols

    {tc, tr} =
      Geometry.data_edge(
        socket.assigns.cells,
        socket.assigns.active,
        dir,
        {cols, socket.assigns.rows}
      )

    # Snap the edge target onto a VISIBLE row (SF-D8: edge-jump skips hidden
    # rows). With no filter `visible_rows` is the contiguous window, so this is
    # byte-identical to the historical `max(row_lo) |> min(row_hi)` clamp.
    active = {tc, clamp_visible(socket.assigns.visible_rows, tr)}
    anchor = if params["shift"], do: socket.assigns.anchor || socket.assigns.active, else: nil
    {:noreply, assign(socket, active: active, anchor: anchor, editing: nil, menu: nil)}
  end

  # Ctrl+Home / Ctrl+End — A1 / the used range's last cell. A plain jump rides
  # `jump_to` (which PAGES the row window so an off-page target renders — the
  # same fix name-jump/find lean on); Shift extends the selection instead,
  # clamped into the current window like nav-edge.
  # Chrome axis (see select-all): pure selection state, no op.
  def handle_event("nav-corner", _params, %{assigns: %{chrome: :reader}} = socket),
    do: {:noreply, socket}

  def handle_event("nav-corner", %{"corner" => corner} = params, socket)
      when corner in ["home", "end"] do
    {cols, row_lo, row_hi} = move_bounds(socket)

    {tc, tr} =
      case corner do
        "home" ->
          {1, 1}

        "end" ->
          {socket.assigns.used_cols |> max(1) |> min(cols), max(socket.assigns.used_rows, 1)}
      end

    if params["shift"] do
      active = {tc, tr |> max(row_lo) |> min(row_hi)}
      anchor = socket.assigns.anchor || socket.assigns.active
      {:noreply, assign(socket, active: active, anchor: anchor, editing: nil, menu: nil)}
    else
      {:noreply, jump_to(socket, {tc, tr})}
    end
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

  # The name box jumps the active cell to a typed ref. It rides `jump_to`, which
  # PAGES the row window so the target lands inside the rendered DOM — jumping to
  # A800 with only an `active` assign stranded the cursor outside the 500-row
  # window (the off-page name-jump bug). Pure navigation, reader-safe.
  def handle_event("name-jump", %{"ref" => ref}, socket) do
    case Sheets.parse_ref(ref) do
      {:ok, pos} -> {:noreply, jump_to(socket, pos)}
      :error -> {:noreply, socket}
    end
  end

  # Find-in-sheet (Ctrl+F, find-only). `find-open`/`find-close` toggle the bar
  # (the JS hook fires them on Ctrl+F / Escape); `find-next`/`find-prev` scan
  # the current tab's sparse cells and jump to the next/prev match, wrapping.
  # ALL pure navigation (never `Ops.send_ops`) so the read-only reader finds too.
  def handle_event("find-open", _params, socket) do
    {:noreply, assign(socket, find_open: true)}
  end

  def handle_event("find-close", _params, socket) do
    {:noreply,
     assign(socket, find_open: false, find_query: "", find_hits: MapSet.new(), status: "")}
  end

  def handle_event("find-next", %{"q" => q}, socket) when is_binary(q) do
    {:noreply, run_find(socket, q, :next)}
  end

  def handle_event("find-prev", %{"q" => q}, socket) when is_binary(q) do
    {:noreply, run_find(socket, q, :prev)}
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

  def handle_event("edit-commit", _params, %{assigns: %{write_capable: false}} = socket),
    do: {:noreply, socket}

  def handle_event("edit-commit", %{"value" => value} = params, socket) do
    committed = socket.assigns.active
    socket = commit(socket, committed, value)
    active = move(committed, move_key(params["move"]), move_vis(socket))

    {:noreply,
     socket
     |> announce_commit(committed)
     |> assign(editing: nil, active: active, anchor: nil)
     |> Ops.push_presence(%{editing: nil})}
  end

  def handle_event("bar-commit", _params, %{assigns: %{write_capable: false}} = socket),
    do: {:noreply, socket}

  def handle_event("bar-commit", %{"value" => value} = params, socket) do
    committed = socket.assigns.active
    socket = commit(socket, committed, value)
    active = move(committed, move_key(params["move"]), move_vis(socket))

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

    # menu: nil closes an open context menu when Clear is chosen from it (and is
    # a harmless no-op on the Delete/Backspace keyboard path).
    {:noreply, socket |> assign(menu: nil) |> send_ops(ops)}
  end

  # Fill down/right (Ctrl+D / Ctrl+R): the selection's first row (down) or
  # first column (right) is the source; every other cell in the rect copies
  # it with a per-step formula rebase. A formula source rebases its relative
  # refs ($-anchors pinned); a scalar source copies verbatim (no parse_raw
  # round-trip); a blank source CLEARS the target (Excel). Excel's single-
  # CELL Ctrl+D (copy from the row above the selection) is a v1 carve-out.
  def handle_event("fill", %{"dir" => dir}, socket) when dir in ["down", "right"] do
    {c1, c2, r1, r2} = Geometry.selection_rect(socket.assigns.active, socket.assigns.anchor)

    if any_hidden_in_span?(socket, r1, r2) do
      {:noreply, assign(socket, notice: hidden_write_notice())}
    else
      do_fill(socket, dir, {c1, c2, r1, r2})
    end
  end

  # Fill-handle drag (the .sheet-fillnub on the selection corner): the hook
  # tracks the hovered cell and pushes ONE fill-range {to} on mouseup; the
  # source rect is the server's OWN selection (authoritative — never a client-
  # sent rect). Extends DOWN or RIGHT from the rect, repeating the source
  # block cyclically with the same per-step formula rebase / meta stamp /
  # merge fence Ctrl+D/R use. A target at (or inside) the rect is a no-op —
  # the nub's own dblclick gesture composes a mousedown+mouseup first, and
  # that degenerate drag must not fill anything. Up/left fills are a v1
  # carve-out, matching the keyboard fill's down/right-only vocabulary.
  def handle_event("fill-range", _params, %{assigns: %{write_capable: false}} = socket),
    do: {:noreply, socket}

  def handle_event("fill-range", %{"to" => to_ref}, socket) do
    case Sheets.parse_ref(to_ref) do
      {:ok, target} -> {:noreply, fill_to_target(socket, target)}
      :error -> {:noreply, socket}
    end
  end

  # Fill to the data extent (double-click the nub, Excel's idiom): fill DOWN
  # from the selection to the last contiguous data row of the adjacent column
  # (left of the rect when occupied there, else right). No adjacent data, or
  # an extent not past the rect → no-op.
  def handle_event("fill-extent", _params, %{assigns: %{write_capable: false}} = socket),
    do: {:noreply, socket}

  def handle_event("fill-extent", _params, socket) do
    rect = Geometry.selection_rect(socket.assigns.active, socket.assigns.anchor)
    cells = Map.get(GridData.current_tab(socket), "cells") || %{}
    {_c1, c2, _r1, _r2} = rect

    case extent_row(cells, rect) do
      nil -> {:noreply, socket}
      row -> {:noreply, fill_to_target(socket, {c2, row})}
    end
  end

  # Autofit (double-click a header resize handle): a column sizes to its
  # longest rendered content (`Cells.autofit_col_px` — char-count heuristic,
  # clamped), riding the EXISTING set_col_width op so undo/redo and the delta
  # path come free; an empty column sends nothing. Rows never wrap, so the
  # row variant resets to the single-line default height.
  def handle_event("autofit", _params, %{assigns: %{write_capable: false}} = socket),
    do: {:noreply, socket}

  def handle_event("autofit", %{"kind" => "col", "index" => i}, socket) do
    col = to_int(i)
    cells = Map.get(GridData.current_tab(socket), "cells") || %{}

    case Cells.autofit_col_px(cells, col) do
      nil ->
        {:noreply, socket}

      px ->
        op = %{"op" => "set_col_width", "tab" => socket.assigns.tab, "col" => col, "px" => px}
        {:noreply, send_ops(socket, [op])}
    end
  end

  def handle_event("autofit", %{"kind" => "row", "index" => i}, socket) do
    op = %{"op" => "set_row_height", "tab" => socket.assigns.tab, "row" => to_int(i), "px" => 24}
    {:noreply, send_ops(socket, [op])}
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
       |> send_ops([op])
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
     |> send_ops([op])
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
    {:noreply, send_ops(socket, [op])}
  end

  # Sort the current selection A→Z / Z→A (SF-AM2). Sort is an EDIT mutation:
  # the write_capable guard clause fails closed even on a forged event, and
  # send_ops' read-only drop is the last wall (SF-AM2d). A WHOLE-COLUMN
  # selection (rows span the rendered window, the head-click shape) expands to
  # the USED DATA RECT — all occupied columns × occupied rows, r1 just below
  # the frozen head band; any OTHER selection sorts IN PLACE with r1 clamped
  # below the band. The key is the ACTIVE cell's column (Excel's sort-by-
  # active-column). All clipping is here — the caller-clips-below-the-frozen-
  # band contract (SF-D5); the op never re-clips.
  def handle_event("sort-selection", _params, %{assigns: %{write_capable: false}} = socket),
    do: {:noreply, socket}

  def handle_event("sort-selection", %{"dir" => dir}, socket)
      when dir in ["asc", "desc"] do
    {c1, c2, r1, r2} = Geometry.selection_rect(socket.assigns.active, socket.assigns.anchor)
    {_cols, row_lo, row_hi} = move_bounds(socket)
    {active_col, _active_row} = socket.assigns.active
    top = frozen_top(socket)

    socket =
      if r1 <= row_lo and r2 >= row_hi do
        # Whole-column: the used data rect, keyed by the ACTIVE column
        # (SF-AM2a). The rect WIDENS to include an active column beyond the
        # used data (a head-click on an empty rendered column): the blank key
        # ranks every row :eq, so the stable sort is the identity — a true
        # no-op (Excel semantics) instead of silently re-keying on the last
        # occupied column, which would reorder data by a column the user
        # never picked.
        uc = max(socket.assigns.used_cols, active_col)
        ur = max(socket.assigns.used_rows, 1)
        dispatch_sort(socket, 1, top, uc, ur, active_col - 1, dir)
      else
        # In place: the selection rect, r1 clamped below the frozen band, keyed
        # by the active column clamped into the rect (SF-AM2b).
        dispatch_sort(socket, c1, max(r1, top), c2, r2, clamp_col(active_col, c1, c2) - 1, dir)
      end

    {:noreply, socket}
  end

  # Column ▾ menu "Sort A→Z / Z→A" (SF-AM2, the wish's "clicking a column
  # header selects+offers to sort"). SELECTS the whole rendered column (so the
  # user sees B:B highlighted) AND dispatches the used-data-rect sort keyed by
  # that column in one action. Same triple gate + guards as sort-selection.
  def handle_event("sort-column", _params, %{assigns: %{write_capable: false}} = socket),
    do: {:noreply, socket}

  def handle_event("sort-column", %{"col" => col, "dir" => dir}, socket)
      when dir in ["asc", "desc"] do
    {cols, row_lo, row_hi} = move_bounds(socket)
    c = clamp_col(to_int(col), 1, cols)
    # Reuse head-click's whole-column {active, anchor} so the selection shows.
    socket = assign(socket, active: {c, row_lo}, anchor: {c, row_hi}, editing: nil, menu: nil)

    # Same rect-widening as sort-selection: a menu sort on an empty rendered
    # column keys on that blank column → identity → true no-op, never a
    # silent re-key onto the last occupied column.
    uc = max(socket.assigns.used_cols, c)
    ur = max(socket.assigns.used_rows, 1)
    socket = dispatch_sort(socket, 1, frozen_top(socket), uc, ur, c - 1, dir)
    {:noreply, socket}
  end

  # Structured paste (current clients): the hook parses the clipboard TSV
  # quote-aware CLIENT-side and pushes an already-split `rows` grid, so an Excel
  # cell holding an embedded newline lands as ONE cell instead of shattering
  # into phantom rows. Preflight caps rows×cols BEFORE building ops and applies
  # NOTHING on overflow (all-or-nothing) — the fat-finger whole-column guard.
  def handle_event("paste", %{"rows" => rows}, socket) when is_list(rows) do
    {c0, r0} = socket.assigns.active
    tab = socket.assigns.tab
    covered = socket.assigns.covered

    cell_count = Enum.reduce(rows, 0, fn row, acc -> acc + length(List.wrap(row)) end)

    cond do
      cell_count > @paste_cell_cap ->
        {:noreply, assign(socket, notice: paste_too_large_notice(cell_count))}

      any_hidden_in_span?(socket, r0, r0 + max(length(rows) - 1, 0)) ->
        {:noreply, assign(socket, notice: hidden_write_notice())}

      true ->
        ops =
          for {line, i} <- Enum.with_index(rows),
              {val, j} <- Enum.with_index(List.wrap(line)),
              is_binary(val),
              not MapSet.member?(covered, {c0 + j, r0 + i}) do
            ref = Sheets.format_ref({c0 + j, r0 + i})

            if val == "" do
              %{"op" => "clear_cell", "tab" => tab, "ref" => ref}
            else
              %{"op" => "set_cell", "tab" => tab, "ref" => ref, "raw" => Ops.parse_raw(val)}
            end
          end

        {:noreply, send_ops(socket, ops)}
    end
  end

  # Client preflight tripped (over the cell cap): surface the notice, apply
  # nothing — the hook already declined to ship the payload.
  def handle_event("paste-too-large", params, socket) do
    count = if is_integer(params["cells"]), do: params["cells"], else: nil
    {:noreply, assign(socket, notice: paste_too_large_notice(count))}
  end

  # TSV paste starting at the active cell — values only; per-op errors
  # (cap, bounds) come back on the apply_ops reply as the notice. Retained as
  # the plain-split fallback for OLD clients that still push `%{"tsv" => …}`;
  # not quote-aware (a quoted multi-line cell shatters — current clients avoid
  # it via the `rows` clause above).
  def handle_event("paste", %{"tsv" => tsv}, socket) when is_binary(tsv) do
    {c0, r0} = socket.assigns.active
    tab = socket.assigns.tab
    covered = socket.assigns.covered

    lines =
      case String.split(tsv, ["\r\n", "\n"]) do
        rows -> if List.last(rows) == "", do: Enum.drop(rows, -1), else: rows
      end

    if any_hidden_in_span?(socket, r0, r0 + max(length(lines) - 1, 0)) do
      {:noreply, assign(socket, notice: hidden_write_notice())}
    else
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

      {:noreply, send_ops(socket, ops)}
    end
  end

  # Text-to-columns — split every cell of a SINGLE selected column on a FIXED
  # delimiter into the adjacent columns, as one undoable batch. Rides the exact
  # set_cell/parse_raw machinery paste uses (so "1,2,3" spills real numbers) and
  # each source cell keeps its fmt via the session's retype-preserve. The
  # delimiter comes from a closed vocabulary keyed by name — NEVER a free-form
  # token off the wire. An empty / unknown token (the "Split…" placeholder) or a
  # multi-column selection is a no-op / refusal; a single cell is a valid
  # one-row split.
  def handle_event("text-to-columns", _params, %{assigns: %{write_capable: false}} = socket),
    do: {:noreply, socket}

  def handle_event("text-to-columns", %{"delim" => token}, socket) do
    delims = %{"comma" => ",", "semicolon" => ";", "space" => " ", "colon" => ":", "pipe" => "|"}

    case Map.get(delims, token) do
      nil ->
        {:noreply, socket}

      delim ->
        {c1, c2, r1, r2} = Geometry.selection_rect(socket.assigns.active, socket.assigns.anchor)

        if c1 != c2 do
          {:noreply, assign(socket, notice: "select a single column to split")}
        else
          {:noreply, split_column(socket, c1, r1, r2, delim)}
        end
    end
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

  # Right-click cell context menu (SF context-menu). The JS contextmenu hook
  # re-anchors the selection (if the click landed outside it) via the existing
  # cell-click path, then pushes this to open the floating menu at the cursor.
  # x/y are viewport coordinates — the menu renders position:fixed and the hook
  # viewport-clamps it in updated(). Rides the SAME @menu assign as the header
  # menus: the {:cell, x, y} variant renders the floating menu, and every
  # existing `menu: nil` reset (menu-close, rowcol-key, clear-selection,
  # cell-click, nav, tab-switch…) dismisses it for free.
  def handle_event("cell-menu-open", %{"x" => x, "y" => y}, socket) do
    {:noreply, assign(socket, menu: {:cell, to_int(x), to_int(y)})}
  end

  def handle_event("rowcol-insert", %{"kind" => kind, "at" => at, "where" => where}, socket) do
    at = to_int(at) + if(where == "after", do: 1, else: 0)
    op = if kind == "col", do: "insert_cols", else: "insert_rows"

    {:noreply,
     socket
     |> assign(menu: nil)
     |> send_ops([%{"op" => op, "tab" => socket.assigns.tab, "at" => at, "count" => 1}])}
  end

  def handle_event("rowcol-delete", %{"kind" => kind, "at" => at}, socket) do
    op = if kind == "col", do: "delete_cols", else: "delete_rows"

    {:noreply,
     socket
     |> assign(menu: nil)
     |> send_ops([
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
     |> send_ops([%{"op" => op, "tab" => socket.assigns.tab, "at" => at, "count" => count}])}
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

    {:noreply, send_ops(socket, [op])}
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
       # The picker targets the active tab; switching tabs closes it so it
       # never lingers pointed at a tab the user just left.
       tab_color_open: false,
       # Matches are keyed to the previous tab's cells — drop them so the
       # highlight never bleeds onto the new tab's grid.
       find_hits: MapSet.new(),
       find_query: "",
       # The filter criteria are likewise keyed to the previous tab's columns —
       # drop them so rows of the NEW tab never vanish under a filter the
       # viewer set on a different tab (per-tab view-state, SF-D2/SF-D7).
       filters: %{},
       filter_panel: nil,
       status: "Sheet #{idx + 1} of #{count}: #{tab_name(socket, idx)}"
     )
     |> GridData.derive_grid()
     |> Ops.push_presence(%{tab: idx, active: "A1", selection: nil, editing: nil})}
  end

  def handle_event("tab-add", _params, socket) do
    n = length(GridData.tabs(socket)) + 1
    {:noreply, send_ops(socket, [%{"op" => "add_tab", "name" => "Sheet #{n}"}])}
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
       |> send_ops([%{"op" => "move_tab", "from" => from, "to" => to}])}
    end
  end

  # Duplicate the active tab. The copy lands right after the source; the viewer
  # deliberately STAYS on the source (apply_delta's remap keeps @tab there —
  # auto-switching to the copy is a later UX call).
  def handle_event("tab-duplicate", _params, socket) do
    {:noreply,
     socket
     |> assign(status: "Duplicated as Copy of #{tab_name(socket, socket.assigns.tab)}")
     |> send_ops([%{"op" => "duplicate_tab", "tab" => socket.assigns.tab}])}
  end

  def handle_event("tab-rename-start", %{"tab" => idx}, socket) do
    {:noreply, assign(socket, renaming_tab: to_int(idx))}
  end

  def handle_event("tab-rename", %{"tab" => idx, "name" => name}, socket) do
    {:noreply,
     socket
     |> assign(renaming_tab: nil)
     |> send_ops([%{"op" => "rename_tab", "tab" => to_int(idx), "name" => name}])}
  end

  # Escape (or blur / click-away) abandons an in-progress inline rename.
  def handle_event("tab-rename-cancel", _params, socket) do
    {:noreply, assign(socket, renaming_tab: nil)}
  end

  def handle_event("tab-delete", %{"tab" => idx}, socket) do
    {:noreply, send_ops(socket, [%{"op" => "delete_tab", "tab" => to_int(idx)}])}
  end

  # Toggle the tab-color picker popover (editable only — the button that fires
  # this is inside the `@editable` block, so a read-only host never reaches it).
  def handle_event("tab-color-open", _params, socket) do
    {:noreply, assign(socket, tab_color_open: not socket.assigns.tab_color_open)}
  end

  # Set (or clear, on "") the ACTIVE tab's color via the NEW `set_tab_color`
  # session op (QL-D2/D3 — S-SESSION owns apply_one). The payload is the
  # byte-for-byte seam S-SESSION defines: `%{"op" => "set_tab_color", "tab" =>
  # i, "color" => "#rrggbb" | nil}` — an empty pick collapses to nil, which the
  # op treats as CLEAR (deletes the key). It is NOT a cell op (no recompute);
  # the session flushes + broadcasts a structural delta so peers see the color.
  # The picker closes on pick, mirroring the toolbar's fire-and-close controls.
  def handle_event("tab-set-color", %{"color" => color}, socket) do
    color = if color == "", do: nil, else: color

    {:noreply,
     socket
     |> assign(tab_color_open: false)
     |> send_ops([%{"op" => "set_tab_color", "tab" => socket.assigns.tab, "color" => color}])}
  end

  # ── events: per-user undo/redo (M4) ──────────────────────────────────────

  # The hook's Cmd/Ctrl+Z / Cmd/Ctrl+Shift+Z. Ops.send_ops stamps the user,
  # so the session pops THIS identity's stack; the resulting delta
  # re-renders every client like any other op.
  def handle_event("undo", _params, socket) do
    socket = send_ops(socket, [%{"op" => "undo"}])
    # A rejection (empty stack) already fired the assertive alert via @notice;
    # only announce the success on the polite channel so the two never overlap.
    status = if socket.assigns.notice == nil, do: "Undid last change", else: ""
    {:noreply, assign(socket, status: status)}
  end

  def handle_event("redo", _params, socket) do
    socket = send_ops(socket, [%{"op" => "redo"}])
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

  # ── events: conditional formatting (CF-C) ────────────────────────────────
  #
  # The whole panel is pure server-rendered LiveView (Decision CF-D1: the live
  # grid renders CF server-side; the panel does NO client evaluation). Every
  # write authors the tab's FULL rules list and dispatches ONE set_cond_format
  # session op, validated with byte-identical strictness to the CF-B gate.

  # Toggle the panel. Opening seeds a fresh create form with the range prefilled
  # from the current selection (Excel's "apply to" default).
  def handle_event("cf-open", _params, socket) do
    panel = if socket.assigns.cf_panel, do: nil, else: cf_new_form(socket)
    {:noreply, assign(socket, cf_panel: panel)}
  end

  def handle_event("cf-close", _params, socket) do
    {:noreply, assign(socket, cf_panel: nil)}
  end

  # Keep the form and the op state in sync as the user types/switches op — so
  # the "between" second value appears (and typed values survive the render).
  def handle_event("cf-form-change", params, socket) do
    {:noreply, assign(socket, cf_panel: cf_form_state(params))}
  end

  # Load an existing rule into the edit form.
  def handle_event("cf-edit", %{"id" => id}, socket) do
    panel =
      case Enum.find(socket.assigns.cf_rules, &(to_string(&1["id"]) == id)) do
        nil -> socket.assigns.cf_panel
        rule -> cf_edit_form(rule)
      end

    {:noreply, assign(socket, cf_panel: panel)}
  end

  # Delete a rule: author the list minus it and dispatch. The list re-renders
  # when the session delta lands; reset the form to a fresh create.
  def handle_event("cf-delete", %{"id" => id}, socket) do
    new_list = Enum.reject(socket.assigns.cf_rules, &(to_string(&1["id"]) == id))

    socket = cf_dispatch(socket, new_list)
    {:noreply, assign(socket, cf_panel: cf_new_form(socket))}
  end

  # Create or update a rule. Server-generated id for a new rule; the FULL list
  # is validated by the op (gate parity) — a rejection surfaces via @notice and
  # keeps the user's form, a clean apply resets to a fresh create form.
  def handle_event("cf-save", params, socket) do
    editing = cf_editing(params["editing"])
    op = params["op"] || "gt"

    rule = %{
      "id" => editing || cf_new_id(socket.assigns.cf_rules),
      "range" => String.trim(params["range"] || ""),
      "when" =>
        cf_when(
          op,
          cf_value(op, String.trim(params["value"] || "")),
          cf_value("between", String.trim(params["value2"] || ""))
        ),
      "style" => cf_style(params["bg"], cf_checked?(params["b"]), cf_checked?(params["i"]))
    }

    new_list =
      if editing do
        Enum.map(socket.assigns.cf_rules, fn r ->
          if to_string(r["id"]) == editing, do: rule, else: r
        end)
      else
        socket.assigns.cf_rules ++ [rule]
      end

    socket = cf_dispatch(socket, new_list)
    panel = if socket.assigns.notice, do: cf_form_state(params), else: cf_new_form(socket)
    {:noreply, assign(socket, cf_panel: panel)}
  end

  # ── events: per-viewer filter (SF-B, paper §3+§4) ────────────────────────
  #
  # THE ONE-WAY DOOR (SF-D2): filter is per-viewer socket view-state ONLY. NOT
  # ONE of these handlers sends an op, mutates content, persists, or broadcasts
  # — they only reshape THIS socket's `filters`/`filter_panel` assigns and re-
  # derive the grid. There is deliberately ZERO wire surface: a filter wire
  # endpoint would be a chartered regression. A collaborator on the same sheet
  # sees nothing of this viewer's filter.

  # Open (or re-open on) a column's funnel editor, prefilled from the column's
  # active criterion if it has one, else a fresh "is not empty" default.
  def handle_event("filter-open", %{"col" => col}, socket) do
    col = to_int(col)
    panel = filter_open_form(socket.assigns.filters, col)
    {:noreply, assign(socket, filter_panel: panel, menu: nil)}
  end

  def handle_event("filter-close", _params, socket) do
    {:noreply, assign(socket, filter_panel: nil)}
  end

  # Track the op as the user switches it so the funnel's value/value2 inputs
  # appear only for the ops that need them (mirrors cf-form-change).
  def handle_event("filter-form-change", params, socket) do
    {:noreply, assign(socket, filter_panel: filter_form_state(params))}
  end

  # Apply the funnel's criterion to this viewer's `filters`. Pure view-state:
  # assign + `derive_grid` (which recomputes `visible_rows`), then clamp the
  # active cell onto the nearest still-visible row (SF-D8 — a newly-applied
  # filter must never strand the cursor on a hidden row). NO op is sent.
  #
  # A VACUOUS criterion (gt/lt/between without a number, eq/contains without a
  # value) is REFUSED with an inline error, panel kept open: the CF-D5 kernel
  # would match NOTHING for it, so applying it silently blanks the viewer's
  # entire data set — the exact "data vanished, no idea why" failure the
  # fail-open clause in `Filter` exists to prevent.
  def handle_event("filter-apply", params, socket) do
    col = to_int(params["col"])
    criterion = filter_criterion(params)

    case criterion && filter_criterion_error(criterion) do
      nil ->
        # Unknown op (unreachable from the funnel's own select) — ignore.
        {:noreply, socket}

      :ok ->
        filters = Map.put(socket.assigns.filters, col, criterion)

        {:noreply,
         socket
         |> assign(filters: filters, filter_panel: nil)
         |> GridData.derive_grid()
         |> clamp_active_to_visible()}

      {:error, msg} ->
        {:noreply,
         assign(socket, filter_panel: params |> filter_form_state() |> Map.put("error", msg))}
    end
  end

  # Clear a single column's filter (from its funnel editor).
  def handle_event("filter-clear", %{"col" => col}, socket) do
    filters = Map.delete(socket.assigns.filters, to_int(col))

    {:noreply,
     socket
     |> assign(filters: filters, filter_panel: nil)
     |> GridData.derive_grid()
     |> clamp_active_to_visible()}
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

  defp paste_too_large_notice(count) when is_integer(count),
    do: "paste too large: #{count} cells exceeds the #{@paste_cell_cap}-cell limit"

  defp paste_too_large_notice(_),
    do: "paste too large: exceeds the #{@paste_cell_cap}-cell limit"

  # A fill/paste whose target span crosses a filtered-out row is REFUSED (paper
  # §4): writing into a row this viewer can't see would corrupt data invisibly.
  defp hidden_write_notice,
    do: "can't fill or paste across rows hidden by a filter — clear the filter first"

  defp commit_clickaway(socket, params) do
    socket =
      case params["commit"] do
        draft when is_binary(draft) and socket.assigns.editing != nil ->
          socket
          |> commit(socket.assigns.active, draft)
          |> Ops.push_presence(%{editing: nil})

        _ ->
          socket
      end

    case params["bar_commit"] do
      draft when is_binary(draft) ->
        socket
        |> commit(socket.assigns.active, draft)
        |> Ops.push_presence(%{editing: nil})

      _ ->
        socket
    end
  end

  # The component-local seam over `Ops.commit`/`Ops.send_ops`: every mutation
  # this module sends rides these two (never `Ops.*` directly), recording the
  # sent cell refs in @own_refs FIRST. The session's delta broadcast carries
  # no author, so this is the only way the sheets_op handler can tell the
  # echo of an OWN edit (already spoken by announce_commit) from a remote
  # collaborator's — see announce_remote_change/2, which consumes the refs.
  # Ref-less ops (structure/tabs/undo) track nothing and pass straight through.
  defp commit(socket, pos, value) do
    socket
    |> refresh_write_capable()
    |> note_own_refs([Sheets.format_ref(pos)])
    |> Ops.commit(pos, value)
  end

  defp send_ops(socket, ops) do
    refs = for %{"ref" => ref} <- ops, do: ref

    socket
    |> refresh_write_capable()
    |> note_own_refs(refs)
    |> Ops.send_ops(ops)
  end

  # pds-w42 — THE SECOND DERIVATION, AT THE INSTANT OF THE WRITE.
  #
  # `write_capable` arrives as a PROP, and a prop is only as fresh as the
  # parent's last render. A `phx-target`ed event does NOT re-render the parent
  # (that is the same property that makes the socket-level `Caps` deny-gate
  # unreachable here), so between a mid-session revocation and this event there
  # may be no render at all — re-deriving in the parent narrows that window,
  # it does not close it. This closes it: every mutation in this module rides
  # `commit/3` or `send_ops/2` (never `Ops.*` directly), and both re-ask
  # `Shared.sheet_write_capable?/1` — the SAME predicate, over freshly-read
  # membership and grant rows — before `Ops.send_ops/2`'s last wall reads the
  # assign. A revocation that halts the socket-level `save` halts this too.
  #
  # NARROWING ONLY, NEVER WIDENING: the fresh answer is ANDed with the prop, so
  # a host that never passes `write_authz` (the public `SheetsReaderLive`) and a
  # host whose prop already said `false` are byte-identical to before — no new
  # query, no new permission.
  defp refresh_write_capable(%{assigns: %{write_capable: false}} = socket), do: socket

  defp refresh_write_capable(%{assigns: %{write_authz: %{} = ctx}} = socket),
    do: assign(socket, write_capable: Shared.sheet_write_capable?(ctx))

  defp refresh_write_capable(socket), do: socket

  defp note_own_refs(socket, []), do: socket

  # AUTHORIZATION axis. A host without write capability never writes
  # (Ops.send_ops drops the ops), so tracking would only accumulate refs that
  # no echo ever consumes. NOTE for readers chasing the "presence asymmetry":
  # this is echo-suppression BOOKKEEPING, not peer visibility — a viewer's
  # cursor reaches peers through `Ops.push_presence/2`, which this axis (and
  # the old flag before it) never gated. A write-denied member is, and was,
  # visible to peers.
  defp note_own_refs(%{assigns: %{write_capable: false}} = socket, _refs), do: socket

  defp note_own_refs(socket, refs),
    do: assign(socket, own_refs: MapSet.union(socket.assigns.own_refs, MapSet.new(refs)))

  # Dispatch ONE `sort_range` op over the already-clipped rect (SF-AM2/SF-D3).
  # The rect corners are 1-based ({c1,r1} top-left, {c2,r2} bottom-right); the
  # key col is 0-based absolute (the op's contract, structure.ex). REFUSES with
  # a notice — never dispatches — when this viewer has an active filter (hidden
  # rows silently moving is the SF-D8 corruption class) or the rect has < 2
  # rows (nothing to reorder). Engine refusals (sort_merge_overlap /
  # sort_frozen_overlap) surface their message through send_ops' notice path.
  defp dispatch_sort(socket, c1, r1, c2, r2, key_col, dir) do
    cond do
      map_size(socket.assigns.filters) > 0 ->
        assign(socket, notice: "Clear the column filters before sorting")

      r2 - r1 + 1 < 2 ->
        assign(socket, notice: "Nothing to sort")

      true ->
        range = Sheets.format_ref({c1, r1}) <> ":" <> Sheets.format_ref({c2, r2})
        keys = [%{"col" => key_col, "dir" => dir}]

        op = %{
          "op" => "sort_range",
          "tab" => socket.assigns.tab,
          "range" => range,
          "keys" => keys
        }

        send_ops(socket, [op])
    end
  end

  # The first sortable row: just below the frozen head band (SF-D5's
  # EXCLUDE-BY-REFUSAL made an EXCLUDE-BY-CLIP at the caller).
  defp frozen_top(socket), do: socket.assigns.frozen_rows + 1

  # Clamp a 1-based column into [lo, hi] (both 1-based).
  defp clamp_col(c, lo, hi), do: c |> max(lo) |> min(hi)

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

    send_ops(socket, ops)
  end

  # The active cell's "s" style map (empty when the cell or its style is
  # absent) — drives B/I toggle direction and the toolbar's aria-pressed.
  defp active_style(cells, active),
    do: Map.get(Map.get(cells, Sheets.format_ref(active)) || %{}, "s") || %{}

  # ── conditional-formatting helpers (CF-C) ────────────────────────────────

  # One set_cond_format op carrying the tab's FULL new rules list — the session
  # applies it as a whole-list replace with a structural inverse for undo/redo,
  # validating with byte-identical strictness to the CF-B gate. Rides the same
  # send_ops path as every other write (user-stamped, read-only hosts drop it).
  defp cf_dispatch(socket, rules) do
    send_ops(socket, [%{"op" => "set_cond_format", "tab" => socket.assigns.tab, "rules" => rules}])
  end

  # A fresh create form: range prefilled from the current selection (Excel's
  # "apply to" default), a valid default bg so submit never trips the gate.
  defp cf_new_form(socket) do
    %{
      "editing" => "",
      "range" => cf_selection_range(socket),
      "op" => "gt",
      "value" => "",
      "value2" => "",
      "bg" => @cf_default_bg,
      "b" => false,
      "i" => false
    }
  end

  # The stored rule → the edit form's fields (values back to display strings).
  defp cf_edit_form(rule) do
    w = cf_map(rule["when"])
    style = cf_map(rule["style"])

    %{
      "editing" => to_string(rule["id"]),
      "range" => to_string(rule["range"] || ""),
      "op" => to_string(w["op"] || "gt"),
      "value" => cf_value_to_str(w["value"]),
      "value2" => cf_value_to_str(w["value2"]),
      "bg" => to_string(style["bg"] || @cf_default_bg),
      "b" => style["b"] == true,
      "i" => style["i"] == true
    }
  end

  # The live form params → the panel state (so a re-render keeps every field).
  defp cf_form_state(params) do
    %{
      "editing" => params["editing"] || "",
      "range" => params["range"] || "",
      "op" => params["op"] || "gt",
      "value" => params["value"] || "",
      "value2" => params["value2"] || "",
      "bg" => params["bg"] || @cf_default_bg,
      "b" => cf_checked?(params["b"]),
      "i" => cf_checked?(params["i"])
    }
  end

  defp cf_selection_range(socket) do
    {c1, c2, r1, r2} = Geometry.selection_rect(socket.assigns.active, socket.assigns.anchor)
    a = Sheets.format_ref({c1, r1})
    if {c1, r1} == {c2, r2}, do: a, else: a <> ":" <> Sheets.format_ref({c2, r2})
  end

  defp cf_editing(editing) when is_binary(editing) and editing != "", do: editing
  defp cf_editing(_), do: nil

  # A fresh "cf-<n>" id that is NOT already taken in this tab's list.
  # `System.unique_integer/1` restarts at low values on every BEAM boot, so a
  # bare counter can re-mint an id persisted in a PREVIOUS run — and the gate's
  # duplicate-id check would then reject the whole list with an error the user
  # can't decode. Skipping taken ids closes that (the dup check is per-tab, so
  # list-local uniqueness is sufficient).
  defp cf_new_id(rules) do
    taken = MapSet.new(for r <- rules, is_map(r), do: to_string(r["id"]))

    Stream.repeatedly(fn -> "cf-" <> Integer.to_string(System.unique_integer([:positive])) end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  # An unchecked HTML checkbox sends nothing; a checked one sends "on".
  defp cf_checked?(v), do: v in ["on", "true", true]

  # Coerce the value string to the type the op expects — the gate rejects a
  # mismatch (surfaced as a notice), so an un-coercible value passes through
  # as its string and gets a clear "must be a number" gate error.
  defp cf_value(op, str) when op in ["gt", "lt", "between"], do: cf_to_number(str)
  defp cf_value("eq", str), do: Ops.parse_raw(str)
  defp cf_value(_op, str), do: str

  defp cf_to_number(str) do
    case Integer.parse(str) do
      {i, ""} ->
        i

      _ ->
        case Float.parse(str) do
          {f, ""} -> f
          _ -> str
        end
    end
  end

  # value2 rides ONLY for between (the gate forbids it elsewhere).
  defp cf_when("between", value, value2),
    do: %{"op" => "between", "value" => value, "value2" => value2}

  defp cf_when(op, value, _value2), do: %{"op" => op, "value" => value}

  # bg required; b/i kept only when checked (literal true) — the CF-D6 grammar.
  defp cf_style(bg, b?, i?) do
    %{"bg" => if(is_binary(bg), do: bg, else: "")}
    |> cf_maybe_flag("b", b?)
    |> cf_maybe_flag("i", i?)
  end

  defp cf_maybe_flag(map, key, true), do: Map.put(map, key, true)
  defp cf_maybe_flag(map, _key, _), do: map

  # A stored rule's one-line summary for the panel list — TOTAL, like every
  # other read seam over stored cond_formats (a gate-bypassed doc must degrade
  # the panel row, never crash the LiveView render).
  defp cf_rule_summary(rule) do
    w = cf_map(rule["when"])
    range = to_string(rule["range"] || "")

    label =
      case to_string(w["op"] || "") do
        "gt" -> "> #{cf_value_to_str(w["value"])}"
        "lt" -> "< #{cf_value_to_str(w["value"])}"
        "eq" -> "= #{cf_value_to_str(w["value"])}"
        "between" -> "#{cf_value_to_str(w["value"])}–#{cf_value_to_str(w["value2"])}"
        "contains" -> "contains “#{cf_value_to_str(w["value"])}”"
        other -> other
      end

    "#{range}: #{label}"
  end

  # The rule's bg preview swatch. Stored bg is gate-validated #rrggbb, but this
  # is a render seam over RAW storage — re-validate like Cells.style_css does,
  # so a gate-bypassed value can never inject CSS into the style attribute.
  defp cf_swatch_style(rule) do
    case cf_map(rule["style"])["bg"] do
      bg when is_binary(bg) ->
        if CondFormat.valid_bg?(bg), do: "background: #{bg};", else: ""

      _ ->
        ""
    end
  end

  # Total map read for RAW stored rule sub-maps ("when"/"style") — a non-map
  # (gate-bypassed corruption) reads as empty rather than raising in Access.
  defp cf_map(%{} = m), do: m
  defp cf_map(_), do: %{}

  defp cf_value_to_str(nil), do: ""
  defp cf_value_to_str(true), do: "TRUE"
  defp cf_value_to_str(false), do: "FALSE"
  defp cf_value_to_str(v) when is_binary(v), do: v
  defp cf_value_to_str(v), do: to_string(v)

  # ── per-viewer filter helpers (SF-B) ─────────────────────────────────────

  # The ops the funnel offers. `blank`/`nonblank` are occupancy tests; the
  # five value ops ride `CondFormat.matches?/2` through `Filter` (CF-D5 matrix).
  @filter_value_ops ~w(gt lt eq between contains)

  # Open the funnel editor for `col`, prefilled from its active criterion (so
  # re-opening shows the current filter), else a fresh "is not empty" default.
  defp filter_open_form(filters, col) do
    base = %{"col" => col, "op" => "nonblank", "value" => "", "value2" => ""}

    case Map.get(filters, col) do
      %{"op" => op} = crit ->
        %{
          base
          | "op" => op,
            "value" => cf_value_to_str(Map.get(crit, "value")),
            "value2" => cf_value_to_str(Map.get(crit, "value2"))
        }

      _ ->
        base
    end
  end

  # phx-change: keep the funnel form state (so the op switch reveals value /
  # value2 inputs and typed values survive the re-render). The hidden "col"
  # field carries which column is open.
  defp filter_form_state(params) do
    %{
      "col" => to_int(params["col"]),
      "op" => params["op"] || "nonblank",
      "value" => params["value"] || "",
      "value2" => params["value2"] || ""
    }
  end

  # Build the stored criterion from the submitted funnel form. Values coerce
  # exactly like the CF panel's (`cf_value/2`: numbers for gt/lt/between, a
  # typed literal for eq, a raw string for contains) so the shared
  # `CondFormat.matches?/2` kernel evaluates them identically. An unknown op
  # yields nil (no-op) — the funnel only ever emits the known set.
  defp filter_criterion(params) do
    case params["op"] do
      op when op in ["blank", "nonblank"] ->
        %{"op" => op}

      "between" ->
        %{
          "op" => "between",
          "value" => cf_value("between", String.trim(params["value"] || "")),
          "value2" => cf_value("between", String.trim(params["value2"] || ""))
        }

      op when op in @filter_value_ops ->
        %{"op" => op, "value" => cf_value(op, String.trim(params["value"] || ""))}

      _ ->
        nil
    end
  end

  # Refuse a criterion the CF-D5 kernel can never match (see filter-apply):
  # gt/lt/between demand numbers (a non-number coerces to a string and the
  # kernel's numeric guard then matches NOTHING), eq/contains demand a value.
  # Occupancy ops are always valid. Returns :ok | {:error, msg}.
  defp filter_criterion_error(%{"op" => op} = crit) when op in ["gt", "lt", "between"] do
    ok? =
      is_number(Map.get(crit, "value")) and
        (op != "between" or is_number(Map.get(crit, "value2")))

    cond do
      ok? -> :ok
      op == "between" -> {:error, "enter numbers for min and max"}
      true -> {:error, "enter a number"}
    end
  end

  defp filter_criterion_error(%{"op" => op, "value" => v}) when op in ["eq", "contains"] do
    if v == "", do: {:error, "enter a value"}, else: :ok
  end

  defp filter_criterion_error(_), do: :ok

  # A one-line summary of a column's active criterion, for the funnel's title
  # + aria-label. TOTAL over the stored criterion shape.
  defp filter_summary(%{"op" => "blank"}), do: "is empty"
  defp filter_summary(%{"op" => "nonblank"}), do: "is not empty"
  defp filter_summary(%{"op" => "gt", "value" => v}), do: "> #{cf_value_to_str(v)}"
  defp filter_summary(%{"op" => "lt", "value" => v}), do: "< #{cf_value_to_str(v)}"
  defp filter_summary(%{"op" => "eq", "value" => v}), do: "= #{cf_value_to_str(v)}"

  defp filter_summary(%{"op" => "between", "value" => v, "value2" => v2}),
    do: "#{cf_value_to_str(v)}–#{cf_value_to_str(v2)}"

  defp filter_summary(%{"op" => "contains", "value" => v}),
    do: "contains “#{cf_value_to_str(v)}”"

  defp filter_summary(_), do: "filtered"

  # Carry the source cell's number format + style onto each filled target —
  # ALWAYS both keys (nil when the source has none) so a stale target format
  # is cleared, Excel's fill semantics.
  defp stamp_meta(op, src_cell) do
    Map.merge(op, %{"fmt" => Map.get(src_cell, "fmt"), "s" => Map.get(src_cell, "s")})
  end

  # Extend the current selection rect to a drag target — the fill-handle
  # engine behind "fill-range" and "fill-extent". DOWN wins when the target
  # is below the rect (each new row copies the source block cyclically:
  # src_r = r1 + rem(r - r1, height)); otherwise RIGHT when it is past the
  # rect's right edge. Targets/sources under a merge are fenced exactly like
  # the keyboard fill; each op rides the same rebase_formula/stamp_meta path.
  # On success the selection extends over the filled range (Excel), so the
  # nub follows the new corner. Anything else (corner/self/inside/up/left)
  # builds no targets → send_ops([]) short-circuits and nothing mutates.

  # The Ctrl+D/R fill body (extracted so the "fill" handler can refuse a
  # hidden-row span first, SF-D8). Source = the rect's first row (down) / first
  # column (right); every other cell copies it with the per-step rebase / meta
  # stamp / merge fence.
  defp do_fill(socket, dir, {c1, c2, r1, r2}) do
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

    {:noreply, send_ops(socket, ops)}
  end

  defp fill_to_target(socket, {tc, tr}) do
    {c1, c2, r1, r2} = Geometry.selection_rect(socket.assigns.active, socket.assigns.anchor)

    if any_hidden_in_span?(socket, min(r1, tr), max(r2, tr)) do
      assign(socket, notice: hidden_write_notice())
    else
      do_fill_to_target(socket, {tc, tr}, {c1, c2, r1, r2})
    end
  end

  defp do_fill_to_target(socket, {tc, tr}, {c1, c2, r1, r2}) do
    cells = Map.get(GridData.current_tab(socket), "cells") || %{}
    covered = socket.assigns.covered
    tab = socket.assigns.tab
    w = c2 - c1 + 1
    h = r2 - r1 + 1

    {targets, anchor} =
      cond do
        tr > r2 ->
          targets =
            for c <- c1..c2, r <- (r2 + 1)..tr do
              src_r = r1 + rem(r - r1, h)
              {c, r, {c, src_r}, 0, r - src_r}
            end

          {targets, {c2, tr}}

        tc > c2 ->
          targets =
            for c <- (c2 + 1)..tc, r <- r1..r2 do
              src_c = c1 + rem(c - c1, w)
              {c, r, {src_c, r}, c - src_c, 0}
            end

          {targets, {tc, r2}}

        true ->
          {[], nil}
      end

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

    socket = send_ops(socket, ops)

    case ops do
      [] -> socket
      _ -> assign(socket, active: {c1, r1}, anchor: anchor)
    end
  end

  # The fill-extent target row: the last CONTIGUOUS occupied row of the
  # adjacent column (left preferred when occupied at the rect's top row,
  # else right), walked from the rect's top. nil when no adjacent data
  # exists or the extent does not reach past the rect (nothing to fill).
  defp extent_row(cells, {c1, c2, r1, r2}) do
    adj =
      cond do
        c1 > 1 and occupied?(cells, {c1 - 1, r1}) -> c1 - 1
        occupied?(cells, {c2 + 1, r1}) -> c2 + 1
        true -> nil
      end

    case adj do
      nil ->
        nil

      col ->
        row = walk_extent(cells, col, r1)
        if row > r2, do: row
    end
  end

  defp walk_extent(cells, col, r) do
    if occupied?(cells, {col, r + 1}), do: walk_extent(cells, col, r + 1), else: r
  end

  defp occupied?(cells, pos), do: Map.has_key?(cells, Sheets.format_ref(pos))

  # Build the text-to-columns batch for the single column `col` over rows r1..r2
  # (see the handler). A row is SKIPPED (never emits) unless its source cell is
  # present, is NOT merge-covered, holds a binary "v" and NO "f" (never destroy a
  # formula), and splits into 2+ parts. The spill guard then scans every
  # destination FIRST: FAIL-CLOSED all-or-nothing — a deliberate v1 deviation
  # from Excel's confirm-overwrite dialog — if ANY target {col+j, r} is occupied,
  # merge-covered, or past the rendered column window (@cols, the same honest
  # bound head-click uses), we emit NOTHING and explain. On success the source
  # keeps part 0 (retype preserves its fmt/s) and each further NON-empty part
  # rides parse_raw. (One send_ops batch; the session's 1000-op/call cap is
  # pathological here and rides back as a notice via send_ops.)
  defp split_column(socket, col, r1, r2, delim) do
    cells = Map.get(GridData.current_tab(socket), "cells") || %{}
    covered = socket.assigns.covered
    cols = socket.assigns.cols
    tab = socket.assigns.tab

    plans =
      for r <- r1..r2,
          not MapSet.member?(covered, {col, r}),
          cell = Map.get(cells, Sheets.format_ref({col, r})),
          is_map(cell),
          not Map.has_key?(cell, "f"),
          is_binary(v = Map.get(cell, "v")),
          parts = String.split(v, delim),
          length(parts) > 1 do
        {r, parts}
      end

    cond do
      plans == [] ->
        socket

      spill_blocked?(plans, col, cols, covered, cells) ->
        assign(socket, notice: "cannot split: destination cells are not empty")

      true ->
        ops =
          for {r, parts} <- plans,
              {part, j} <- Enum.with_index(parts),
              j == 0 or part != "" do
            ref = Sheets.format_ref({col + j, r})
            %{"op" => "set_cell", "tab" => tab, "ref" => ref, "raw" => Ops.parse_raw(part)}
          end

        span = plans |> Enum.map(fn {_r, parts} -> length(parts) end) |> Enum.max()

        socket
        |> send_ops(ops)
        |> assign(status: "Split #{length(plans)} cell(s) across #{span} columns")
    end
  end

  # The all-or-nothing spill test: TRUE when ANY split would land on a target
  # that is off the rendered column window, merge-covered, or already occupied.
  # Only the spill columns (j >= 1) are checked — j == 0 overwrites the source.
  defp spill_blocked?(plans, col, cols, covered, cells) do
    Enum.any?(plans, fn {r, parts} ->
      Enum.any?(1..(length(parts) - 1)//1, fn j ->
        c = col + j

        c > cols or
          MapSet.member?(covered, {c, r}) or
          Map.has_key?(cells, Sheets.format_ref({c, r}))
      end)
    end)
  end

  # ── find + jump navigation ────────────────────────────────────────────────

  # Jump the active cell to {c, r}, PAGING the row window so the target sits
  # inside the rendered DOM. Sets `row_offset` (clamped by `derive_grid`), re-
  # runs `derive_grid`, assigns `active`, and announces the target on the polite
  # `@status` region. PURE navigation (an assign + `derive_grid`, never
  # `Ops.send_ops`), so it works identically on the read-only reader and can
  # never start a session or mutate content. This is the shared fix for the
  # off-page name-jump bug: without the page step, jumping past the 500-row
  # window left the active cell unrendered.
  defp jump_to(socket, {c, r}) do
    socket =
      socket
      |> assign(row_offset: jump_offset(socket, r), anchor: nil, editing: nil, menu: nil)
      |> GridData.derive_grid()

    range = socket.assigns.row_range
    # Snap onto a visible row so an active filter never strands the cursor on a
    # hidden (un-rendered) row (SF-D8). With no filter the target is already in
    # the contiguous window, so this returns `r` unchanged.
    r = clamp_visible(socket.assigns.visible_rows, r)

    assign(socket,
      active: {c, r},
      status:
        "#{Sheets.format_ref({c, r})} · showing rows #{range.first}–#{range.last} of #{socket.assigns.rows}"
    )
  end

  # The row_offset that pages `r` into the rendered window. With no filter the
  # window is logical, so it's the plain 500-row division. Under a filter
  # `derive_grid` pages over VISIBLE rows (SF-D8), so the offset must be the
  # target's position in the whole-height visible list — the logical division
  # would land jump/find/Ctrl+End on the wrong page of a >1-page filtered
  # sheet. A hidden target rounds to the nearest visible row at/after it, the
  # same snap `clamp_visible/2` applies once the page renders.
  defp jump_offset(socket, r) do
    filters = socket.assigns[:filters] || %{}

    if map_size(filters) == 0 do
      div(max(r - 1, 0), GridData.rows_per_page())
    else
      all_visible =
        Filter.visible_rows(
          1..socket.assigns.rows,
          filters,
          socket.assigns.cells,
          socket.assigns.used_rows,
          socket.assigns.frozen_rows
        )

      pos = Enum.find_index(all_visible, &(&1 >= r)) || max(length(all_visible) - 1, 0)
      div(pos, GridData.rows_per_page())
    end
  end

  # Run a find pass: scan the current tab's SPARSE cells, jump to the next/prev
  # match relative to `active` (wrapping), and announce the count politely. A
  # blank query clears the highlight. Pure navigation — never `Ops.send_ops`.
  defp run_find(socket, query, dir) do
    if String.trim(query) == "" do
      assign(socket, find_query: query, find_hits: MapSet.new(), status: "")
    else
      cells = Map.get(GridData.current_tab(socket), "cells") || %{}
      ordered = Cells.find_matches(cells, query)
      hits = MapSet.new(ordered)

      case Cells.next_match(ordered, socket.assigns.active, dir) do
        nil ->
          assign(socket,
            find_query: query,
            find_hits: hits,
            status: ~s(No matches for "#{query}")
          )

        pos ->
          idx = Enum.find_index(ordered, &(&1 == pos)) + 1

          socket
          |> assign(find_query: query, find_hits: hits)
          |> jump_to(pos)
          |> assign(status: ~s(Match #{idx} of #{length(ordered)} for "#{query}"))
      end
    end
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
  # LIVENESS axis, and it stays there: `committed_display/2` PEEKS the live
  # (draft) Session, so a host not entitled to draft bytes must never reach it
  # — a forged commit event would otherwise leak draft cell values through
  # @status, the one path that reads the session outside update/2. Fail closed.
  defp announce_commit(%{assigns: %{live_session: false}} = socket, _pos), do: socket

  defp announce_commit(socket, pos) do
    if socket.assigns.notice == nil do
      ref = Sheets.format_ref(pos)
      assign(socket, status: "#{ref}: #{committed_display(socket, ref)}")
    else
      assign(socket, status: "")
    end
  end

  defp committed_display(socket, ref) do
    with {:ok, content} <-
           Session.peek(
             socket.assigns.slug,
             socket.assigns.dataset,
             GridData.session_workspace_id(socket)
           ),
         tab when is_map(tab) <- Enum.at(Map.get(content, "tabs") || [], socket.assigns.tab),
         cells when is_map(cells) <- Map.get(tab, "cells") do
      Cells.display(Map.get(cells, ref))
    else
      _ -> ""
    end
  end

  # A remote collaborator's delta that rewrites THIS viewer's ACTIVE cell was
  # otherwise silent to a screen reader — the grid re-rendered but nothing
  # spoke. Announce it on the polite @status region (WCAG 4.1.3). Own echoes
  # stay quiet: announce_commit already spoke the edit, so a second frame
  # would double-speak — @own_refs (stamped in commit/send_ops) marks the
  # refs this editor sent, and each delta consumes the refs it covered.
  # Runs AFTER apply_delta, so `active` is already remapped by any structural
  # shift, and only for deltas on this viewer's current tab.
  defp announce_remote_change(socket, %{tab: tab} = payload) do
    changed = Map.get(payload, :changed) || %{}
    ref = Sheets.format_ref(socket.assigns.active)
    own? = MapSet.member?(socket.assigns.own_refs, ref)
    socket = consume_own_refs(socket, changed)

    if tab == socket.assigns.tab and Map.has_key?(changed, ref) and not own? do
      case Map.get(changed, ref) do
        nil -> assign(socket, status: "#{ref} cleared")
        cell -> assign(socket, status: "#{ref} changed to #{Cells.display(cell)}")
      end
    else
      socket
    end
  end

  # Drop every ref this delta covered from @own_refs — one delta echoes one
  # applied batch, so a consumed ref is done; a ref whose op the session
  # REJECTED never echoes and is swept here by the next covering delta.
  defp consume_own_refs(socket, changed) do
    own = socket.assigns.own_refs

    if MapSet.size(own) == 0 or changed == %{} do
      socket
    else
      assign(socket, own_refs: MapSet.difference(own, MapSet.new(Map.keys(changed))))
    end
  end

  # ── nav helpers ───────────────────────────────────────────────────────────

  # `{cols, row_lo, row_hi}` — column extent + the CURRENT page's row bounds
  # (the first/last VISIBLE row, == the window edges with no filter). Clamping
  # to these keeps a shift-extend / header selection on the current page.
  defp move_bounds(socket) do
    {socket.assigns.cols, socket.assigns.visible_first, socket.assigns.visible_last}
  end

  # `{cols, visible_rows}` — the arrow-stepping bounds. Arrows step to the next
  # VISIBLE row so filtered-out rows are skipped (SF-D8); with no filter the
  # visible list is the contiguous window, so stepping is byte-identical to the
  # old `min/max(r±1, window)` clamp.
  defp move_vis(socket), do: {socket.assigns.cols, socket.assigns.visible_rows}

  defp move(pos, nil, _bounds), do: pos

  defp move({c, r}, key, {cols, vis}) do
    case key do
      "ArrowUp" -> {c, prev_visible(vis, r)}
      "ArrowDown" -> {c, next_visible(vis, r)}
      "ArrowLeft" -> {max(c - 1, 1), r}
      "ArrowRight" -> {min(c + 1, cols), r}
      "Home" -> {1, r}
      "End" -> {cols, r}
      "PageUp" -> {c, step_visible(vis, r, -20)}
      "PageDown" -> {c, step_visible(vis, r, 20)}
      _ -> {c, r}
    end
  end

  # ── visible-row stepping (filter-aware, SF-D8) ────────────────────────────
  #
  # `vis` is the current page's ascending list of visible logical rows. Each
  # helper degenerates to the historical contiguous-window clamp when `vis`
  # is a gapless range (the no-filter path), and skips hidden rows otherwise.

  # The next visible row strictly after `r`, clamped to the last visible row.
  defp next_visible(vis, r) do
    case Enum.filter(vis, &(&1 > r)) do
      [] -> List.last(vis) || r
      [n | _] -> n
    end
  end

  # The previous visible row strictly before `r`, clamped to the first visible.
  defp prev_visible(vis, r) do
    case Enum.filter(vis, &(&1 < r)) do
      [] -> List.first(vis) || r
      less -> List.last(less)
    end
  end

  # PageUp/PageDown: jump ~20 rows, snapping to the nearest visible row inside
  # the step (never overshooting past the window), moving at least one row.
  defp step_visible(vis, r, delta) when delta > 0 do
    target = r + delta

    case Enum.filter(vis, &(&1 > r and &1 <= target)) do
      [] -> next_visible(vis, r)
      xs -> List.last(xs)
    end
  end

  defp step_visible(vis, r, delta) do
    target = r + delta

    case Enum.filter(vis, &(&1 < r and &1 >= target)) do
      [] -> prev_visible(vis, r)
      xs -> List.first(xs)
    end
  end

  # Snap a logical row onto the current page's visible rows — the nearest
  # visible row at or after `r` (clamped to the window ends). With no filter
  # `r` is already in the contiguous window so this returns `r` unchanged,
  # matching the old `max(row_lo) |> min(row_hi)` clamp exactly.
  defp clamp_visible([], r), do: r

  defp clamp_visible(vis, r) do
    first = List.first(vis)
    last = List.last(vis)

    cond do
      r <= first -> first
      r >= last -> last
      true -> Enum.find(vis, last, &(&1 >= r))
    end
  end

  # Re-anchor the active cell onto a visible row after a filter change so a
  # newly-hidden active row never strands the cursor (SF-D8). Drops the anchor
  # (a stale selection rect across now-hidden rows is meaningless).
  defp clamp_active_to_visible(socket) do
    {ac, ar} = socket.assigns.active
    assign(socket, active: {ac, clamp_visible(socket.assigns.visible_rows, ar)}, anchor: nil)
  end

  # Does the row span `r_lo..r_hi` cross a filtered-out (hidden) row? Only ever
  # true while a filter is active — the no-filter fast path returns false, so
  # every write guard below is a no-op without a filter (byte-identical). Used
  # to REFUSE a fill/paste that would write into rows the viewer cannot see
  # (paper §4 — a silent write into an invisible row corrupts data).
  defp any_hidden_in_span?(socket, r_lo, r_hi) do
    filters = socket.assigns.filters

    if not is_map(filters) or map_size(filters) == 0 or r_lo > r_hi do
      false
    else
      cells = socket.assigns.cells
      used_rows = socket.assigns.used_rows
      frozen = socket.assigns.frozen_rows

      Enum.any?(r_lo..r_hi, fn r ->
        not Filter.row_visible?(r, filters, cells, used_rows, frozen)
      end)
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

  # The tab's color IFF it is a well-formed `#rrggbb` — the render-time guard
  # that keeps a legacy/junk stored color (synthesis is lenient, so one can
  # survive on a pre-gate document) out of an inline `style` attribute. nil
  # for an absent, blank, or malformed color (the swatch/picker glyph simply
  # doesn't paint). Routes through the ONE `#rrggbb` owner so what stores is
  # what renders, `\z`-anchored (a trailing-newline color is rejected).
  defp tab_color(%{"color" => c}) when is_binary(c) do
    if CondFormat.valid_bg?(c), do: c, else: nil
  end

  defp tab_color(_tab), do: nil

  # Tints the picker-toggle glyph with the ACTIVE tab's current color, so the
  # `●` button previews what's set. nil (no inline style) when the active tab
  # is uncolored or the color is malformed.
  defp active_tab_color_style(all_tabs, tab) do
    case tab_color(Enum.at(all_tabs, tab) || %{}) do
      nil -> nil
      c -> "color: #{c};"
    end
  end

  defp to_int(i) when is_integer(i), do: i

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _rest} -> i
      :error -> 0
    end
  end

  # Inline position for the right-click context menu. x/y are viewport coords
  # (position:fixed); the JS hook re-clamps against the real menu rect on open.
  defp cell_menu_style({:cell, x, y}),
    do: "position: fixed; left: #{x}px; top: #{y}px; z-index: 20;"

  defp cell_menu_style(_), do: nil

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

    # The active cell's style drives the B/I/align buttons' aria-pressed, and
    # its number format the fmt select's selected option — render-local
    # (changes on every cursor move, feeds only the toolbar).
    active_s = if assigns.editable, do: active_style(assigns.cells, assigns.active), else: %{}

    active_fmt =
      if assigns.editable,
        do: Map.get(Map.get(assigns.cells, Sheets.format_ref(assigns.active)) || %{}, "fmt")

    assigns =
      assign(assigns,
        peer_cursors: peer_cursors,
        peer_sels: peer_sels,
        sel_stats: sel_stats,
        active_s: active_s,
        active_fmt: active_fmt
      )

    ~H"""
    <div
      id={@id}
      class={"editor-panel sheet-editor" <> if(@chrome == :reader, do: " sheet-reader", else: "")}
      data-role="content"
      data-test-id={if @chrome == :reader, do: "sheet-reader", else: "studio-sheet-editor"}
    >
      <%!-- CHROME axis: the header belongs to the Studio surface, not to write
            capability. A write-denied member is in Studio and keeps it — the
            wave-42 measurement found them staring at a headerless panel that
            called itself `sheet-reader`. --%>
      <.document_header :if={@chrome == :studio} dataset={@dataset} title={@doc.title || @slug}>
        <:status_pill>
          <span class={"badge badge-#{if @is_draft, do: "draft", else: "published"}"}>
            <%= if @is_draft, do: "draft", else: "published" %>
          </span>
        </:status_pill>
        <:actions>
          <%!-- AUTHORIZATION axis, and the header's ONE authority-bearing item.
                `toggle-mode` flips @mode, but @editable is `mode == :edit and
                write_capable`, so without the capability the toggle changes
                nothing a viewer can see: the label stays "Edit", the toolbar
                never appears, and the button is the dead affordance this split
                exists to remove (same rule as the cell context menu below).
                A member who may not write is permanently in View and has
                nothing to toggle between. --%>
          <button
            :if={@write_capable}
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

        <%!-- Sort the current selection (SF-AM2). A whole-column selection (the
              head-click shape: rows span the rendered window) expands to the
              used data rect; any other selection sorts in place — both keyed by
              the active cell's column. EDIT-ONLY, triple-gated: rendered only
              inside the @editable toolbar, a `write_capable` guard on the
              event, and send_ops' capability drop as the last wall (SF-AM2d). --%>
        <button
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="sort-selection"
          phx-value-dir="asc"
          phx-target={@myself}
          aria-label="Sort ascending"
          title="Sort the selection A→Z"
          data-test-id="sheet-sort-asc"
        >
          A→Z
        </button>
        <button
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="sort-selection"
          phx-value-dir="desc"
          phx-target={@myself}
          aria-label="Sort descending"
          title="Sort the selection Z→A"
          data-test-id="sheet-sort-desc"
        >
          Z→A
        </button>

        <%!-- Text-to-columns: a phx-change select (mirroring the number-format
              select) that splits the selected single column on a fixed delimiter
              into the adjacent columns, all-or-nothing. --%>
        <form phx-change="text-to-columns" phx-target={@myself} class="sheet-split-group">
          <.bp_select
            name="delim"
            value=""
            options={[
              {"", "Split…"},
              {"comma", "Comma"},
              {"semicolon", "Semicolon"},
              {"space", "Space"},
              {"colon", "Colon"},
              {"pipe", "Pipe"}
            ]}
            aria-label="Split text to columns"
            data-test-id="sheet-split-select"
          />
        </form>

        <%!-- Number-format group ($ % , + a General/Fixed/Date/Datetime select).
              Each stamps a display-only "fmt" onto every occupied cell in the
              selection; General clears it. The buttons' aria-pressed and the
              select's selected option mirror the ACTIVE cell's fmt so AT reads
              the current state, not just the available actions. --%>
        <div class="sheet-fmt-group" role="group" aria-label="Number format" data-test-id="sheet-fmt-group">
          <button type="button" class="btn btn-ghost btn-sm" phx-click="set-fmt" phx-value-fmt="currency" phx-target={@myself} aria-pressed={to_string(@active_fmt == "currency")} title="Currency ($1,234.50)" data-test-id="sheet-fmt-currency">$</button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="set-fmt" phx-value-fmt="percent" phx-target={@myself} aria-pressed={to_string(@active_fmt == "percent")} title="Percent (25.00%)" data-test-id="sheet-fmt-percent">%</button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="set-fmt" phx-value-fmt="thousands" phx-target={@myself} aria-pressed={to_string(@active_fmt == "thousands")} title="Thousands separator (1,234)" data-test-id="sheet-fmt-thousands">,</button>
          <form phx-change="set-fmt" phx-target={@myself}>
            <.bp_select
              name="fmt"
              value={@active_fmt}
              options={[
                {"", "General"},
                {"fixed", "Fixed"},
                {"date", "Date"},
                {"datetime", "Datetime"},
                {"checkbox", "Checkbox"}
              ]}
              aria-label="Number format class"
              data-test-id="sheet-fmt-select"
            />
          </form>
        </div>

        <%!-- Style group: B / I toggles + the align trio (aria-pressed off the
              active cell), and a fixed bg swatch palette + clear. --%>
        <div class="sheet-style-group" role="group" aria-label="Cell style" data-test-id="sheet-style-group">
          <button type="button" class="btn btn-ghost btn-sm" phx-click="toggle-style" phx-value-k="b" phx-target={@myself} aria-pressed={to_string(Map.get(@active_s, "b") == true)} title="Bold (Cmd/Ctrl+B)" data-test-id="sheet-style-bold"><strong>B</strong></button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="toggle-style" phx-value-k="i" phx-target={@myself} aria-pressed={to_string(Map.get(@active_s, "i") == true)} title="Italic (Cmd/Ctrl+I)" data-test-id="sheet-style-italic"><em>I</em></button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="set-align" phx-value-al="left" phx-target={@myself} aria-pressed={to_string(Map.get(@active_s, "al") == "left")} title="Align left" data-test-id="sheet-align-left">⯇</button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="set-align" phx-value-al="center" phx-target={@myself} aria-pressed={to_string(Map.get(@active_s, "al") == "center")} title="Align center" data-test-id="sheet-align-center">≡</button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="set-align" phx-value-al="right" phx-target={@myself} aria-pressed={to_string(Map.get(@active_s, "al") == "right")} title="Align right" data-test-id="sheet-align-right">⯈</button>
          <span class="sheet-bg-swatches" role="group" aria-label="Cell background">
            <button
              :for={swatch <- TokensGen.sheet_cf_backgrounds()}
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

        <%!-- Conditional formatting (CF-C): a pure server-rendered popover to
              author single-rule-per-range cell-value rules. NO custom JS — the
              same phx-click/phx-submit shape as every other style control. The
              rules author the tab's FULL list, dispatched as ONE set_cond_format
              session op (gate-parity validated, undo/redo via the structural
              inverse). Editable-mode only — the whole toolbar is @editable-gated,
              so read-only/View hosts never see it. --%>
        <div class="sheet-cf-group" role="group" aria-label="Conditional formatting" data-test-id="sheet-cf-group">
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="cf-open"
            phx-target={@myself}
            aria-haspopup="dialog"
            aria-expanded={to_string(@cf_panel != nil)}
            title="Conditional formatting"
            data-test-id="sheet-cf-btn"
          >Cond. format</button>

          <div
            :if={@cf_panel}
            class="sheet-popover sheet-cf-panel"
            role="dialog"
            aria-label="Conditional formatting rules"
            data-test-id="sheet-cf-panel"
          >
            <div class="sheet-cf-head">
              <span class="sheet-cf-title">Conditional formatting</span>
              <button type="button" class="btn btn-ghost btn-sm" phx-click="cf-close" phx-target={@myself} aria-label="Close conditional-format panel" data-test-id="sheet-cf-close">&times;</button>
            </div>

            <%!-- Existing rules for THIS tab (raw stored list). Honest empty state. --%>
            <ul :if={@cf_rules != []} class="sheet-cf-list" data-test-id="sheet-cf-list">
              <li :for={rule <- @cf_rules} class="sheet-cf-rule">
                <span class="sheet-cf-swatch" style={cf_swatch_style(rule)} aria-hidden="true"></span>
                <span class="sheet-cf-summary"><%= cf_rule_summary(rule) %></span>
                <button type="button" class="btn btn-ghost btn-sm" phx-click="cf-edit" phx-value-id={rule["id"]} phx-target={@myself} aria-label={"Edit rule " <> cf_rule_summary(rule)} data-test-id={"sheet-cf-edit-" <> to_string(rule["id"])}>Edit</button>
                <button type="button" class="btn btn-ghost btn-sm" phx-click="cf-delete" phx-value-id={rule["id"]} phx-target={@myself} aria-label={"Delete rule " <> cf_rule_summary(rule)} data-test-id={"sheet-cf-delete-" <> to_string(rule["id"])}>Delete</button>
              </li>
            </ul>
            <p :if={@cf_rules == []} class="sheet-cf-empty" data-test-id="sheet-cf-empty">No rules yet — add one below.</p>

            <%!-- Create / edit form. phx-change tracks the op so value2 appears
                  only for "between" and typed values survive the re-render. --%>
            <form class="sheet-cf-form" phx-submit="cf-save" phx-change="cf-form-change" phx-target={@myself} data-test-id="sheet-cf-form">
              <input type="hidden" name="editing" value={@cf_panel["editing"]} />
              <label class="sheet-cf-field">
                <span>Apply to range</span>
                <.bp_input
                  name="range"
                  value={@cf_panel["range"]}
                  placeholder="B2:B10"
                  autocomplete="off"
                  spellcheck="false"
                  data-test-id="sheet-cf-range"
                />
              </label>
              <label class="sheet-cf-field">
                <span>Format cells where the value</span>
                <.bp_select
                  name="op"
                  value={@cf_panel["op"]}
                  options={[
                    {"gt", "is greater than"},
                    {"lt", "is less than"},
                    {"eq", "is equal to"},
                    {"between", "is between"},
                    {"contains", "contains"}
                  ]}
                  data-test-id="sheet-cf-op"
                />
              </label>
              <label class="sheet-cf-field">
                <span><%= if @cf_panel["op"] == "between", do: "min", else: "value" %></span>
                <.bp_input
                  name="value"
                  value={@cf_panel["value"]}
                  autocomplete="off"
                  spellcheck="false"
                  data-test-id="sheet-cf-value"
                />
              </label>
              <label :if={@cf_panel["op"] == "between"} class="sheet-cf-field">
                <span>max</span>
                <.bp_input
                  name="value2"
                  value={@cf_panel["value2"]}
                  autocomplete="off"
                  spellcheck="false"
                  data-test-id="sheet-cf-value2"
                />
              </label>
              <div class="sheet-cf-field">
                <span>Background</span>
                <span class="sheet-bg-swatches" role="radiogroup" aria-label="Rule background color">
                  <%!-- KIT-EXEMPT (charter D14): these radios are `.sr-only` —
                        the browser never paints them; the visible affordance is
                        the custom `.sheet-bg-swatch` square with a selection ring.
                        A themed control would be invisible here, so they stay
                        native. --%>
                  <label :for={swatch <- TokensGen.sheet_cf_backgrounds()} class="sheet-cf-swatch-opt" title={"Background " <> swatch}>
                    <input type="radio" name="bg" value={swatch} checked={@cf_panel["bg"] == swatch} class="sr-only" />
                    <span class="sheet-bg-swatch" style={"background: #{swatch};"} data-test-id={"sheet-cf-bg-" <> String.trim_leading(swatch, "#")} data-selected={to_string(@cf_panel["bg"] == swatch)}></span>
                  </label>
                </span>
              </div>
              <div class="sheet-cf-field sheet-cf-flags">
                <.bp_checkbox name="b" label="Bold" checked={@cf_panel["b"]} data-test-id="sheet-cf-bold" />
                <.bp_checkbox name="i" label="Italic" checked={@cf_panel["i"]} data-test-id="sheet-cf-italic" />
              </div>
              <div class="sheet-cf-actions">
                <button type="submit" class="btn btn-primary btn-sm" data-test-id="sheet-cf-submit"><%= if @cf_panel["editing"] in [nil, ""], do: "Add rule", else: "Save rule" %></button>
              </div>
            </form>
          </div>
        </div>

        <%!-- Visible undo/redo — the ghost buttons a MOUSE user needs; they
              phx-click the SAME "undo"/"redo" events the keyboard fires, so
              zero new server logic. --%>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="undo" phx-target={@myself} aria-label="Undo last change" title="Undo (Cmd/Ctrl+Z)" data-test-id="sheet-undo-btn">↶</button>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="redo" phx-target={@myself} aria-label="Redo last undone change" title="Redo (Cmd/Ctrl+Shift+Z)" data-test-id="sheet-redo-btn">↷</button>

        <%!-- The autosave trust signal — a quiet, right-aligned status region.
              role="status" is its own polite live region, kept SEPARATE from the
              @status commit-announcement region below so a "saved" update never
              clobbers a cell-commit announcement. Hidden until the first edit. --%>
        <span
          :if={@save_state}
          role="status"
          class="sheet-save-status"
          data-test-id="sheet-save-status"
          title={if @save_state == :saved and @save_saved_at, do: DateTime.to_iso8601(@save_saved_at)}
        >
          <%= case @save_state do %>
            <% :saving -> %>Saving…
            <% :saved -> %>All changes saved · {Calendar.strftime(@save_saved_at, "%H:%M")}
            <% :error -> %>Save failed — retrying
          <% end %>
        </span>
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

      <%!-- Find-in-sheet (Ctrl+F, find-only). The match runs SERVER-side over the
            sparse cells map — the 500-row DOM window makes a client search
            structurally wrong (off-page cells never render). Shown on Ctrl+F in
            the editor (the hook fires find-open; Escape closes); ALWAYS shown to
            a viewer with NO hook to open it with — the public reader and, since
            wave 42, the write-denied member (the hook is @editable-gated, so
            they cannot fire find-open either). Enter / ↓ find forward, ↑ finds
            back; both are plain phx events, so find works without the JS hook.
            View mode's missing find bar is a pre-existing gap this slice does
            not widen: it keys on write capability, not on @editable. --%>
      <div
        :if={@find_open or not @write_capable}
        class="sheet-find"
        role="search"
        data-test-id="sheet-find"
      >
        <form class="sheet-find-form" phx-submit="find-next" phx-target={@myself}>
          <input
            name="q"
            type="text"
            class="sheet-find-input"
            value={@find_query}
            autocomplete="off"
            spellcheck="false"
            placeholder="Find in sheet"
            aria-label="Find in sheet"
            data-test-id="sheet-find-input"
          />
          <button
            type="submit"
            class="btn btn-ghost btn-sm"
            title="Next match (Enter)"
            aria-label="Find next"
            data-test-id="sheet-find-next"
          >↓</button>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="find-prev"
            phx-value-q={@find_query}
            phx-target={@myself}
            title="Previous match"
            aria-label="Find previous"
            data-test-id="sheet-find-prev"
          >↑</button>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="find-close"
            phx-target={@myself}
            title="Close find"
            aria-label="Close find"
            data-test-id="sheet-find-close"
          >&times;</button>
        </form>
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
        :if={@row_offset > 0 or @row_page_end < @rows or @col_truncated or @filter_active}
        class="sheet-pager"
        data-test-id="sheet-pager"
      >
        <%= if @row_offset > 0 or @row_page_end < @rows or @filter_active do %>
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
            disabled={not @page_next?}
            data-test-id="sheet-pager-next"
          >Next</button>
          <span data-test-id="sheet-pager-text">
            Showing rows <%= @visible_first %>–<%= @visible_last %> of <%= @rows %><%= if @filter_active do %> · <%= @filter_hidden_count %> rows hidden by filter<% end %><%= if @col_truncated do %> · first <%= @cols %> of <%= @used_cols %> columns<% end %>
          </span>
        <% else %>
          <span data-test-id="sheet-pager-text">
            Showing the first <%= @cols %> of <%= @used_cols %> columns
          </span>
        <% end %>
      </div>

      <%!-- ONE wrapper for both modes (the id still flips with @editable, so a
            mode toggle remounts the hook against the new DOM shape) and the
            peer layer OUTSIDE the if-block: an `if` block is a single tracked
            dynamic whose dependencies are everything inside it — peer assigns
            in there would make every presence frame re-render the whole grid
            body (measured ~15ms extra; see the moduledoc).

            THREE ATTRIBUTES KEY ON @hookable, NOT @editable (wave 43): the
            hook, the role, and the aria selection contract. They are the
            SELECTION axis — a `:studio` grid has a real `grid_sel` rect and the
            hook is its only producer, so a write-denied member (and anyone in
            View mode) used to sit on a highlight frozen at A1. `data-fns` /
            `data-fn-sigs` stay @editable-gated ON PURPOSE: their absence is
            exactly what the hook derives `_readOnly` from, which is what drops
            every write event client-side.

            TWO HOOKS, ONE ATTRIBUTE (wave 43 reader half). `@hookable`
            (chrome == :studio) still picks "SheetGrid", so the Studio path is
            byte-identical. `chrome: :reader` now picks "SheetReaderSelect", a
            SEPARATE and much smaller hook in bp-sheet-grid.js that owns a purely
            CLIENT-SIDE anchor/active pair, paints its own `sheet-rsel` class,
            and contains no pushEvent code path at all.

            Per main's ruling (2026-09-02 10:52Z) that is option (b): "client-
            only selection + copy layer in bp-sheet-grid.js for :reader — paints
            its own class, pushes ZERO events, reads data-v already on reader
            tds. An anonymous principal never round-trips selection and gains no
            authority. […] (a) rejected: it widens the server surface for a
            purely local affordance."

            So NOTHING server-side moves: `Geometry.grid_sel(_, _, :reader)` is
            still {0,0,0,0}, `grid_cursor(_, :reader)` is still {0,0}, and
            select-all / nav-edge / nav-corner still refuse `chrome: :reader`
            below. role / aria-describedby / aria-activedescendant stay keyed on
            @hookable too — role="application" is edit-only by an earlier a11y
            ruling (it muted AT table navigation on the reader); the reader hook
            sets aria-activedescendant from the client instead. --%>
      <div
        id={if @editable, do: "#{@id}-grid", else: "#{@id}-grid-view"}
        class="sheet-grid-wrap"
        phx-hook={
          if @hookable, do: "SheetGrid", else: if(@chrome == :reader, do: "SheetReaderSelect")
        }
        tabindex="0"
        role={if @hookable, do: "application", else: "region"}
        aria-label="Spreadsheet grid"
        aria-describedby={@hookable && "#{@id}-grid-instructions"}
        aria-activedescendant={
          @hookable && Cells.cell_dom_id(if(@editable, do: @id, else: "#{@id}-view"), @active)
        }
        data-fns={@editable && Enum.join(@fn_names, " ")}
        data-fn-sigs={@editable && Jason.encode!(@fn_sigs)}
        data-row-offset={@row_offset}
      >
        <%!-- WCAG 2.1.2: the grid traps Tab (it walks the selection). This
              hidden note tells a keyboard/AT user the one-shot escape hatch —
              Escape then Tab falls through to the browser (see the hook). The
              read-mode half of the sentence is the honest one: navigation and
              copy work, editing does not. --%>
        <span
          :if={@hookable}
          id={"#{@id}-grid-instructions"}
          class="sr-only"
          style="position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0;"
        >
          Press Escape then Tab to leave the grid.
          <%= if @editable do %>
            F2 or Enter to edit the cell; Ctrl+Alt+= inserts rows, Ctrl+Alt+- deletes.
          <% else %>
            Arrow keys move the selection and Ctrl+C copies it; this sheet is read-only.
          <% end %>
        </span>
        <div class="sheet-scroll">
          <%= if @editable do %>
            <.sheet_table
              id={@id}
              cols={@cols}
              rows={@rows}
              rows_total={@rows_total}
              cols_total={@cols_total}
              visible_rows={@visible_rows}
              cells={@cells}
              cf_styles={@cf_styles}
              spans={@spans}
              covered={@covered}
              col_widths={@col_widths}
              row_heights={@row_heights}
              frozen_cols={@frozen_cols}
              frozen_rows={if @row_offset == 0, do: @frozen_rows, else: 0}
              sel={Geometry.grid_sel(@active, @anchor, @chrome)}
              matches={@find_hits}
              active={@active}
              editing={@editing}
              menu={@menu}
              filters={@filters}
              filter_panel={@filter_panel}
              editable={true}
              myself={@myself}
            />
          <% else %>
            <.sheet_table
              id={"#{@id}-view"}
              cols={@cols}
              rows={@rows}
              rows_total={@rows_total}
              cols_total={@cols_total}
              visible_rows={@visible_rows}
              cells={@cells}
              cf_styles={@cf_styles}
              spans={@spans}
              covered={@covered}
              col_widths={@col_widths}
              row_heights={@row_heights}
              frozen_cols={@frozen_cols}
              frozen_rows={if @row_offset == 0, do: @frozen_rows, else: 0}
              sel={Geometry.grid_sel(@active, @anchor, @chrome)}
              matches={@find_hits}
              active={Geometry.grid_cursor(@active, @chrome)}
              editing={nil}
              menu={nil}
              filters={@filters}
              filter_panel={@filter_panel}
              editable={false}
              myself={@myself}
            />
          <% end %>
          <%!-- v1: the peer overlay's px geometry sums from row 1, so it is
                only correct on page 0 — render it there alone (see moduledoc).
                It is ALSO suppressed while a filter is active (SF-D8): hidden
                rows collapse the table, so a peer's row-1-summed Y no longer
                lands on the cell it names — remapping onto visible geometry is
                a wave-SF-2 refinement, suppression is the honest v1 bound. --%>
          <.peer_layer
            :if={@row_offset == 0 and not @filter_active}
            cursors={@peer_cursors}
            sels={@peer_sels}
          />
        </div>
      </div>

      <%!-- Right-click cell context menu (SF context-menu). Edit-only; the JS
            contextmenu hook sets the @menu {:cell, x, y} variant and positions
            it at the cursor (position:fixed + a viewport clamp in updated()). A
            SIBLING of the grid-wrap so the hook's root-bound click/keydown
            listeners can reach its items. Dismissal: click-away (phx-click-away)
            + Escape (the hook pushes menu-close and refocuses the grid). Every
            item reuses an EXISTING op — cut/copy/paste ride the OS clipboard
            client-side (data-menu-action, bp-sheet-grid.js), clear/insert/delete
            are the same phx-click server events the keyboard path calls. --%>
      <%!-- AUTHORIZATION axis: every item below is a mutation (clear / insert /
            delete row-col / paste). A member who cannot write must not be
            handed a menu of buttons that bounce off a guard — that is the
            dead-affordance failure the three-way split exists to avoid. --%>
      <div
        :if={@write_capable and match?({:cell, _, _}, @menu)}
        class="sheet-context-menu"
        role="menu"
        aria-label="Cell actions"
        style={cell_menu_style(@menu)}
        phx-click-away="menu-close"
        phx-target={@myself}
        data-test-id="sheet-context-menu"
      >
        <button type="button" role="menuitem" data-menu-action="cut" data-test-id="sheet-ctx-cut">Cut</button>
        <button type="button" role="menuitem" data-menu-action="copy" data-test-id="sheet-ctx-copy">Copy</button>
        <button type="button" role="menuitem" data-menu-action="paste" data-test-id="sheet-ctx-paste">Paste</button>
        <button type="button" role="menuitem" phx-click="clear-selection" phx-target={@myself} data-test-id="sheet-ctx-clear">Clear</button>
        <button type="button" role="menuitem" phx-click="rowcol-key" phx-value-kind="row" phx-value-action="insert" phx-target={@myself} data-test-id="sheet-ctx-insert-row">Insert row</button>
        <button type="button" role="menuitem" phx-click="rowcol-key" phx-value-kind="row" phx-value-action="delete" phx-target={@myself} data-test-id="sheet-ctx-delete-row">Delete row</button>
        <button type="button" role="menuitem" phx-click="rowcol-key" phx-value-kind="col" phx-value-action="insert" phx-target={@myself} data-test-id="sheet-ctx-insert-col">Insert column</button>
        <button type="button" role="menuitem" phx-click="rowcol-key" phx-value-kind="col" phx-value-action="delete" phx-target={@myself} data-test-id="sheet-ctx-delete-col">Delete column</button>
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
              <%!-- The tab-color swatch (QL-D2): a small colored dot in the
                    tab's own chrome, rendered on EVERY host (read-only readers
                    see the color; only the picker below is gated). Fully
                    inline-styled so it needs no root.html.heex CSS — the pixel
                    polish rides the parked live-browser pass. --%>
              <span
                :if={tab_color(t)}
                class="sheet-tab-swatch"
                style={"display: inline-block; width: 8px; height: 8px; border-radius: 9999px; margin-right: 5px; vertical-align: middle; background: #{tab_color(t)};"}
                data-test-id={"sheet-tab-swatch-#{i}"}
                aria-hidden="true"
              ></span>
              <%= Map.get(t, "name") || "Sheet #{i + 1}" %>
            </button>
          <% end %>
        <% end %>
        <%= if @editable do %>
          <button
            type="button"
            class="sheet-tab-action"
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
            class="sheet-tab-action"
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
            class="sheet-tab-action"
            phx-click="tab-add"
            phx-target={@myself}
            aria-label="Add tab"
            title="Add tab"
            data-test-id="sheet-tab-add"
          >+</button>
          <button
            type="button"
            class="sheet-tab-action"
            phx-click="tab-duplicate"
            phx-target={@myself}
            aria-label="Duplicate the active tab"
            title="Duplicate the active tab"
            data-test-id="sheet-tab-duplicate"
          >&#10697;</button>
          <button
            type="button"
            class="sheet-tab-action"
            phx-click="tab-delete"
            phx-value-tab={@tab}
            phx-target={@myself}
            data-confirm="Delete this tab? Its cells are removed."
            aria-label="Delete the active tab"
            title="Delete the active tab"
            data-test-id="sheet-tab-delete"
          >&times;</button>
          <%!-- Tab-color picker (QL-D2): a toggle + a preset swatch strip that
                mirrors the toolbar set-bg pattern, coloring the ACTIVE tab. The
                whole affordance is inside the `@editable` block, so a read-only
                sheet shows the swatch dot above but never the picker (the same
                gate as rename/move). --%>
          <span class="sheet-tab-color" style="position: relative; display: inline-flex; align-items: center;">
            <button
              type="button"
              class="sheet-tab-action"
              style={active_tab_color_style(@all_tabs, @tab)}
              phx-click="tab-color-open"
              phx-target={@myself}
              aria-haspopup="true"
              aria-expanded={to_string(@tab_color_open)}
              aria-label="Set this sheet's tab color"
              title="Tab color"
              data-test-id="sheet-tab-color-btn"
            >&#9679;</button>
            <span
              :if={@tab_color_open}
              class="sheet-bg-swatches"
              role="group"
              aria-label="Tab color"
              data-test-id="sheet-tab-color-picker"
            >
              <button
                :for={swatch <- TokensGen.sheet_tab_colors()}
                type="button"
                class="sheet-bg-swatch"
                style={"background: #{swatch};"}
                phx-click="tab-set-color"
                phx-value-color={swatch}
                phx-target={@myself}
                title={"Tab color " <> swatch}
                data-test-id={"sheet-tab-color-" <> String.trim_leading(swatch, "#")}
              >
              </button>
              <button type="button" class="btn btn-ghost btn-sm" phx-click="tab-set-color" phx-value-color="" phx-target={@myself} title="Clear tab color" data-test-id="sheet-tab-color-clear">⌫</button>
            </span>
          </span>
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
      aria-rowcount={@rows_total + 1}
      aria-colcount={@cols_total + 1}
    >
      <colgroup>
        <col style="width: 44px;" />
        <col :for={c <- 1..@cols} style={"width: #{Geometry.col_px(@col_widths, c)}px;"} />
      </colgroup>
      <thead>
        <tr aria-rowindex="1">
          <th class="sheet-corner" aria-colindex="1"></th>
          <th
            :for={c <- 1..@cols}
            class="sheet-colhead"
            role="columnheader"
            scope="col"
            aria-colindex={c + 1}
            style={Cells.col_head_style(c, @frozen_cols, @col_widths)}
            data-c={c}
          >
            <%= Geometry.col_letters(c) %>
            <%= if @editable do %>
              <%!-- The "▾" glyph alone is unnameable to AT (WCAG 4.1.2): the
                    trigger carries an accessible name + the menu-popup
                    contract, and aria-expanded tracks @menu. --%>
              <button
                type="button"
                class="sheet-head-menu-btn"
                phx-click="menu-open"
                phx-value-kind="col"
                phx-value-index={c}
                phx-target={@myself}
                aria-label={"Column " <> Geometry.col_letters(c) <> " menu"}
                aria-haspopup="menu"
                aria-expanded={to_string(@menu == {:col, c})}
                data-test-id={"sheet-colmenu-#{c}"}
              >&#9662;</button>
              <div
                :if={@menu == {:col, c}}
                class="sheet-menu"
                role="menu"
                aria-label={"Column " <> Geometry.col_letters(c) <> " menu"}
                data-test-id="sheet-menu"
              >
                <button type="button" role="menuitem" phx-click="rowcol-insert" phx-value-kind="col" phx-value-at={c} phx-value-where="before" phx-target={@myself}>Insert left</button>
                <button type="button" role="menuitem" phx-click="rowcol-insert" phx-value-kind="col" phx-value-at={c} phx-value-where="after" phx-target={@myself}>Insert right</button>
                <button type="button" role="menuitem" phx-click="rowcol-delete" phx-value-kind="col" phx-value-at={c} phx-target={@myself}>Delete column</button>
                <%!-- "Clicking a column header selects+offers to sort" (the wish).
                      SELECTS the column then dispatches the used-data-rect sort.
                      Sort is an EDIT mutation, so these menu items live INSIDE the
                      @editable block and NEVER render in a read-only view (SF-AM2d,
                      SF-AM4). --%>
                <button type="button" role="menuitem" phx-click="sort-column" phx-value-col={c} phx-value-dir="asc" phx-target={@myself} data-test-id={"sheet-sort-col-asc-#{c}"}>Sort A→Z</button>
                <button type="button" role="menuitem" phx-click="sort-column" phx-value-col={c} phx-value-dir="desc" phx-target={@myself} data-test-id={"sheet-sort-col-desc-#{c}"}>Sort Z→A</button>
              </div>
            <% end %>
            <%!-- Per-column FILTER funnel (SF-D9 + SF-AM4). Pure LiveView,
                  mirroring the CF panel: server-rendered HEEx + phx-click, zero
                  bp-sheet-grid.js. The funnel fills when the column carries an
                  active criterion; the popover is this viewer's per-column
                  predicate editor. Filtering is socket view-state — clicking
                  Apply sends NO op (SF-D2). The funnel is a READ affordance
                  (SF-AM4): it renders in ALL modes including the `:reader`
                  /sheets surface, OUTSIDE the @editable block above — readers can
                  filter but the sort menu items stay edit-only. --%>
            <button
              type="button"
              class={"sheet-filter-funnel" <> if(Map.has_key?(@filters, c), do: " sheet-funnel-active", else: "")}
              phx-click="filter-open"
              phx-value-col={c}
              phx-target={@myself}
              aria-haspopup="dialog"
              aria-expanded={to_string(@filter_panel != nil and @filter_panel["col"] == c)}
              aria-label={
                "Filter column " <>
                  Geometry.col_letters(c) <>
                  if(Map.has_key?(@filters, c),
                    do: " (active: " <> filter_summary(@filters[c]) <> ")",
                    else: ""
                  )
              }
              title="Filter this column"
              data-active={to_string(Map.has_key?(@filters, c))}
              data-test-id={"sheet-filter-funnel-#{c}"}
            ><svg viewBox="0 0 16 16" width="11" height="11" aria-hidden="true" focusable="false"><path d="M1.5 2.5h13L9.5 9v4.2l-3 1.4V9L1.5 2.5Z" fill="currentColor" /></svg></button>

            <div
              :if={@filter_panel && @filter_panel["col"] == c}
              class="sheet-popover sheet-filter-panel"
              role="dialog"
              aria-label={"Filter column " <> Geometry.col_letters(c)}
              phx-window-keydown="filter-close"
              phx-key="Escape"
              phx-target={@myself}
              data-test-id="sheet-filter-panel"
            >
              <div class="sheet-filter-head">
                <span class="sheet-filter-title">Filter <%= Geometry.col_letters(c) %></span>
                <button type="button" class="btn btn-ghost btn-sm" phx-click="filter-close" phx-target={@myself} aria-label="Close filter" data-test-id="sheet-filter-close">&times;</button>
              </div>
              <form class="sheet-filter-form" phx-submit="filter-apply" phx-change="filter-form-change" phx-target={@myself} data-test-id="sheet-filter-form">
                <input type="hidden" name="col" value={c} />
                <label class="sheet-filter-field">
                  <span>Show rows where</span>
                  <.bp_select
                    name="op"
                    value={@filter_panel["op"]}
                    options={[
                      {"nonblank", "is not empty"},
                      {"blank", "is empty"},
                      {"eq", "is equal to"},
                      {"gt", "is greater than"},
                      {"lt", "is less than"},
                      {"between", "is between"},
                      {"contains", "contains"}
                    ]}
                    data-test-id="sheet-filter-op"
                  />
                </label>
                <label :if={@filter_panel["op"] in ["gt", "lt", "eq", "between", "contains"]} class="sheet-filter-field">
                  <span><%= if @filter_panel["op"] == "between", do: "min", else: "value" %></span>
                  <.bp_input
                    name="value"
                    value={@filter_panel["value"]}
                    inputmode={if @filter_panel["op"] in ["gt", "lt", "between"], do: "decimal"}
                    autocomplete="off"
                    spellcheck="false"
                    data-test-id="sheet-filter-value"
                  />
                </label>
                <label :if={@filter_panel["op"] == "between"} class="sheet-filter-field">
                  <span>max</span>
                  <.bp_input
                    name="value2"
                    value={@filter_panel["value2"]}
                    inputmode="decimal"
                    autocomplete="off"
                    spellcheck="false"
                    data-test-id="sheet-filter-value2"
                  />
                </label>
                <%!-- A vacuous criterion (no number / no value) is refused with
                      the reason inline — applying it would silently hide every
                      data row (see filter-apply). Cleared on any form change. --%>
                <p :if={@filter_panel["error"]} class="sheet-filter-error" role="alert" data-test-id="sheet-filter-error"><%= @filter_panel["error"] %></p>
                <div class="sheet-filter-actions">
                  <button type="button" class="btn btn-ghost btn-sm" phx-click="filter-clear" phx-value-col={c} phx-target={@myself} data-test-id="sheet-filter-clear">Clear</button>
                  <button type="submit" class="btn btn-primary btn-sm" data-test-id="sheet-filter-apply">Apply</button>
                </div>
              </form>
            </div>
            <%!-- Column resize is an EDIT affordance — back inside @editable. --%>
            <%= if @editable do %>
              <div class="sheet-rsz sheet-rsz--col" data-kind="col" data-index={c} data-px={Geometry.col_px(@col_widths, c)}></div>
            <% end %>
          </th>
        </tr>
      </thead>
      <tbody>
        <tr
          :for={r <- @visible_rows}
          aria-rowindex={r + 1}
          style={"height: #{Geometry.row_px(@row_heights, r)}px;"}
        >
          <th
            class="sheet-rowhead"
            role="rowheader"
            scope="row"
            aria-colindex="1"
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
                aria-label={"Row #{r} menu"}
                aria-haspopup="menu"
                aria-expanded={to_string(@menu == {:row, r})}
                data-test-id={"sheet-rowmenu-#{r}"}
              >&#9662;</button>
              <div
                :if={@menu == {:row, r}}
                class="sheet-menu"
                role="menu"
                aria-label={"Row #{r} menu"}
                data-test-id="sheet-menu"
              >
                <button type="button" role="menuitem" phx-click="rowcol-insert" phx-value-kind="row" phx-value-at={r} phx-value-where="before" phx-target={@myself}>Insert above</button>
                <button type="button" role="menuitem" phx-click="rowcol-insert" phx-value-kind="row" phx-value-at={r} phx-value-where="after" phx-target={@myself}>Insert below</button>
                <button type="button" role="menuitem" phx-click="rowcol-delete" phx-value-kind="row" phx-value-at={r} phx-target={@myself}>Delete row</button>
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
              class={Cells.cell_class(c, r, @sel, @active, cell, @matches)}
              title={Cells.cell_title(cell)}
              aria-selected={Cells.aria_selected(@sel, c, r)}
              aria-colindex={c + 1}
              data-ref={ref}
              data-r={r}
              data-c={c}
              data-v={Cells.data_v(cell)}
              data-t={Cells.data_t(cell)}
              data-f={@editable && Cells.formula(cell)}
              colspan={span && elem(span, 0) > 1 && elem(span, 0)}
              rowspan={span && elem(span, 1) > 1 && elem(span, 1)}
              style={Cells.cell_style(c, r, @frozen_cols, @frozen_rows, @col_widths, @row_heights, cell, Map.get(@cf_styles, {c, r}))}
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
                <% checkbox? = Cells.checkbox?(cell) %>
                <% link? = not checkbox? and Cells.link?(cell["v"]) %>
                <%= if not @editable and link? do %>
                  <a
                    class="sheet-cell-v sheet-link"
                    href={cell["v"]}
                    target="_blank"
                    rel="noopener noreferrer nofollow"
                  ><%= Cells.display(cell) %></a>
                <% else %>
                  <span
                    class="sheet-cell-v"
                    role={checkbox? && "checkbox"}
                    aria-checked={checkbox? && Cells.aria_checked(cell)}
                    phx-click={@editable && checkbox? && "cell-toggle"}
                    phx-value-ref={@editable && checkbox? && ref}
                    phx-target={@editable && checkbox? && @myself}
                  ><%= Cells.display(cell) %></span>
                <% end %>
              <% end %>
              <%!-- The fill handle: a small draggable square on the selection
                    rect's bottom-right corner (drag → fill-range, double-click
                    → fill-extent; both handled by the JS hook). Editing
                    affordance only — the read-only grid passes sel {0,0,0,0}
                    so the predicate never matches there. --%>
              <div
                :if={@editable and Cells.fill_nub?(@sel, c, r)}
                class="sheet-fillnub"
                data-test-id="sheet-fillnub"
              >
              </div>
            </td>
          <% end %>
        </tr>
      </tbody>
    </table>
    """
  end
end
