defmodule BarkparkWeb.Studio.SheetGrid.GridData do
  @moduledoc """
  Grid + tab derivation for `BarkparkWeb.Studio.SheetGrid` — the
  change-tracking contract (`derive_grid/1`, `derive_editable/1`) plus the
  pure tab/dimension helpers it leans on. `derive_grid/1` persists every
  grid assign on the socket so a presence frame marks none of them changed
  (the moduledoc on the facade explains why render-local assigns defeat the
  tracking). Socket-taking functions take `socket` as the explicit first
  arg; the rest are pure over plain content/tab maps.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Barkpark.Plugins.Sheets.CondFormat
  alias Barkpark.Plugins.Sheets.Core, as: Sheets
  alias BarkparkWeb.Studio.SheetGrid.Filter
  alias BarkparkWeb.Studio.SheetGrid.Geometry

  # Render bounds (full virtualization is future work) + layout constants.
  # `@max_rows` is the ROWS-PER-PAGE window size, not a hard clip: a sheet
  # taller than one page is reachable through `row_offset` paging (the pager
  # in the facade), so published rows past 500 are never unreachable. Columns
  # past `@max_cols` stay a notice-only clip, surfaced in the pager text.
  @max_rows 500
  @max_cols 64

  # ── derived assigns (the change-tracking contract) ────────────────────────
  #
  # Everything the grid BODY renders from is derived HERE — on content/tab
  # changes — and persisted on the socket, never computed in render/1.
  # Persisted assigns get Phoenix's equality-based change tracking, so an
  # update that does NOT touch the grid (a presence frame, ~10/s per moving
  # peer) marks none of these changed and the 500-row table diff is skipped
  # wholesale. Assigns computed in render/1 are local to that call: they
  # re-mark as changed on EVERY render and silently defeat the tracking
  # (measured: full-grid re-render per presence frame — see the moduledoc).
  # Call sites: both update/2 clauses (mount, deltas/refetch) and the
  # tab-switch handler — the only places content or the active tab change.
  def derive_grid(socket) do
    all_tabs = Map.get(socket.assigns.content || %{}, "tabs") || []
    tab = Enum.at(all_tabs, socket.assigns.tab) || %{"name" => "Sheet 1", "cells" => %{}}
    {used_cols, used_rows} = used_bounds(tab)
    cols = min(max(used_cols + 2, 8), @max_cols)
    # `rows` is the FULL logical row height (no @max_rows clip) — the total the
    # grid a11y (`aria-rowcount`), geometry and paging math all read. Only the
    # BODY iterates the `row_range` window; the pager walks `row_offset` across
    # the pages, so a tall sheet is fully reachable.
    rows = max(used_rows + 2, 20)
    cells = Map.get(tab, "cells") || %{}
    frozen_rows = clamp_frozen(Map.get(tab, "frozen_rows"), rows)
    frozen_cols = clamp_frozen(Map.get(tab, "frozen_cols"), cols)

    # Per-viewer filter view-state (SF-D2/SF-D7/SF-D8). `filters` is a
    # `%{col => criterion}` map on THIS socket — never on the document. Empty
    # (the no-filter default) makes `paginate/7` the byte-identical historical
    # logical-paging path; a live filter pages over the VISIBLE rows so a
    # heavily-filtered sheet still fills the 500-row window (paper §4).
    filters = socket.assigns[:filters] || %{}
    filter_active = is_map(filters) and map_size(filters) > 0

    %{
      offset: offset,
      first: first,
      last: last,
      visible_rows: visible_rows,
      visible_first: visible_first,
      visible_last: visible_last,
      page_end: page_end,
      page_next?: page_next?,
      hidden_count: hidden_count
    } =
      paginate(
        filter_active,
        socket.assigns[:row_offset] || 0,
        rows,
        filters,
        cells,
        used_rows,
        frozen_rows
      )

    {spans, covered} = merge_maps(tab, cols, rows)
    # Conditional-formatting styles for the LIVE grid (CF-C stage A). Parse the
    # tab's `cond_formats` once through the ONE kernel, then precompute a
    # {c, r} -> CF style map over the OCCUPIED cells only (CF-D8: blank cells
    # never match per CF-D5, so occupied-only is complete AND a hostile huge
    # range costs nothing). Derived HERE with the rest of the grid body so a
    # presence frame never re-evaluates rules (the change-tracking contract).
    rules = CondFormat.parse_rules(Map.get(tab, "cond_formats"))
    cf_styles = cf_styles(rules, cells)
    # Page-boundary merge repair: a rowspan anchored ABOVE this window would
    # leave its covered rows a <td> short here (the spanning anchor renders on
    # the prior page), and HTML slot-filling then shifts every cell right of the
    # merge left, under the wrong column header. Free those in-window covered
    # cells so they render as plain (empty) cells and alignment holds.
    covered = release_boundary_covered(spans, covered, first)

    assign(socket,
      all_tabs: all_tabs,
      cols: cols,
      rows: rows,
      used_cols: used_cols,
      used_rows: used_rows,
      # Columns past @max_cols are a notice-only clip (no horizontal paging in
      # v1): surfaced in the pager text, never silently dropped.
      col_truncated: used_cols > @max_cols,
      # HONEST a11y counts, one per axis — and the axes are NOT symmetric.
      # Rows are fully PAGED (never clipped): the pager walks `row_offset` until
      # the last window reaches `rows`, so every logical row (incl. the two
      # navigable padding rows) is rendered across pages. The honest total is
      # therefore `rows` itself — an earlier `used_rows` fallback UNDER-counted
      # (dropped the padding AND ignored that paging renders past @max_rows), so
      # the last page's `aria-rowindex` exceeded `aria-rowcount`. Columns, by
      # contrast, are a notice-only CLIP at @max_cols (no horizontal paging), so
      # `cols_total` must fall back to `used_cols` to report what the rendered
      # window (≤ @max_cols) cannot.
      rows_total: rows,
      cols_total: if(used_cols > @max_cols, do: used_cols, else: cols),
      row_offset: offset,
      row_range: first..last,
      row_page_end: page_end,
      # The rows the grid BODY iterates (SF-D8) — the current page's VISIBLE
      # row indexes (LOGICAL, ascending). With no filter this is exactly
      # `Enum.to_list(first..last)`, so the rendered body is byte-identical.
      visible_rows: visible_rows,
      # Pager display + move/nav bounds: the first/last LOGICAL row shown on
      # this page (== first/last with no filter).
      visible_first: visible_first,
      visible_last: visible_last,
      # Is a next page reachable? (== `row_page_end < rows` with no filter, so
      # the pager's Next button renders identically.)
      page_next?: page_next?,
      filter_active: filter_active,
      # DATA rows this viewer's filter hid (0 with no filter) — the pager text.
      filter_hidden_count: hidden_count,
      cells: cells,
      spans: spans,
      covered: covered,
      col_widths: Map.get(tab, "col_widths") || %{},
      row_heights: Map.get(tab, "row_heights") || %{},
      frozen_cols: frozen_cols,
      frozen_rows: frozen_rows,
      # {c, r} -> composed CF style, consumed by the grid body's `cell_style`.
      cf_styles: cf_styles,
      # The tab's RAW stored rules (with ids), for the toolbar CF panel's list
      # + edit form — the panel authors the full list the session op replaces.
      # Always a list so the panel's :for never faults on a malformed (non-list)
      # stored value the gate would reject anyway.
      cf_rules: cf_rules_list(Map.get(tab, "cond_formats"))
    )
  end

  # ── row paging (filter-aware, SF-D8) ─────────────────────────────────────
  #
  # NO FILTER — the historical logical window, BYTE-IDENTICAL to pre-SF-B:
  # `offset*500+1 .. min(+499, rows)`, `visible_rows` = that contiguous range
  # as a list (the body's `:for` renders identical `<tr>`s), no hidden rows.
  defp paginate(false, requested, rows, _filters, _cells, _used_rows, _frozen_rows) do
    offset = clamp_row_offset(requested, rows)
    first = offset * @max_rows + 1
    last = min(first + @max_rows - 1, rows)

    %{
      offset: offset,
      first: first,
      last: last,
      visible_rows: Enum.to_list(first..last),
      visible_first: first,
      visible_last: last,
      page_end: last,
      page_next?: last < rows,
      hidden_count: 0
    }
  end

  # FILTER ACTIVE — page over the VISIBLE rows so the 500-row window always
  # fills with visible rows (paper §4: a heavily-filtered sheet still fills the
  # viewport). The whole-height visible list is computed once; `offset` indexes
  # PAGES of it. The list is never empty — growth-padding rows (row > used_rows)
  # are always visible — so `List.first/last` are safe.
  defp paginate(true, requested, rows, filters, cells, used_rows, frozen_rows) do
    all_visible = Filter.visible_rows(1..rows, filters, cells, used_rows, frozen_rows)
    visible_count = length(all_visible)
    last_page = div(max(visible_count - 1, 0), @max_rows)
    offset = requested |> max(0) |> min(last_page)
    page = Enum.slice(all_visible, offset * @max_rows, @max_rows)
    visible_first = List.first(page) || 1
    visible_last = List.last(page) || visible_first

    %{
      offset: offset,
      first: visible_first,
      last: visible_last,
      visible_rows: page,
      visible_first: visible_first,
      visible_last: visible_last,
      page_end: visible_last,
      page_next?: (offset + 1) * @max_rows < visible_count,
      hidden_count: rows - visible_count
    }
  end

  # Precompute the {c, r} -> CF style map for the live grid over the OCCUPIED
  # cells ∩ rule ranges (CF-D8). `CondFormat.style_for/3` supplies the FIRST
  # matching rule's style (CF-D4); a cell no rule matches earns no entry. Empty
  # rules short-circuits to an empty map (the byte-identical no-CF default).
  def cf_styles([], _cells), do: %{}

  def cf_styles(rules, cells) when is_list(rules) and is_map(cells) do
    for {addr, cell} <- cells,
        {:ok, {c, r}} <- [Sheets.parse_ref(addr)],
        style = CondFormat.style_for(rules, {c, r}, cell),
        not is_nil(style),
        into: %{} do
      {{c, r}, style}
    end
  end

  def cf_styles(_rules, _cells), do: %{}

  # Map entries only: the panel reads rule["id"]/["when"]/["style"] per row,
  # and Access RAISES on a non-map entry (e.g. a bare string in a gate-bypassed
  # doc) — the same corruption class the non-list clause below absorbs. The
  # panel must degrade like every other read seam over raw storage, not crash
  # the LiveView render.
  defp cf_rules_list(rules) when is_list(rules), do: Enum.filter(rules, &is_map/1)
  defp cf_rules_list(_), do: []

  # Clamp a requested page index into `[0, last-page]` so a forged, stale, or
  # content-shrank-underneath offset always lands on a real page — the pager
  # is pure navigation and must never fault.
  def clamp_row_offset(offset, total_rows) when is_integer(offset) do
    last_page = div(max(total_rows - 1, 0), @max_rows)

    offset |> max(0) |> min(last_page)
  end

  def clamp_row_offset(_offset, _total_rows), do: 0

  # The rows-per-page window size (`@max_rows`), exposed so a caller that needs
  # to PAGE a target row into view — `jump_to`, name-jump, find — derives the
  # same page index the pager and `clamp_row_offset` use, never a drifting
  # magic number.
  def rows_per_page, do: @max_rows

  # `editable` rides the same persistence rule (it gates whole template
  # subtrees): derived on update (`write_capable` may arrive) and on
  # toggle-mode. It stays a DERIVED assign and is NOT a fourth prop — it fans
  # out to ~36 sites in sheet_grid.ex, so re-keying it here is what keeps a
  # write-denied member from being handed a UI of dead buttons.
  # `hookable` is the SELECTION/NAVIGATION axis, and it is NOT `editable`
  # (wave 43). It keys on CHROME alone, exactly like `Geometry.grid_sel/3`: a
  # `:studio` grid gets a real selection rect, so it must also get the client
  # hook — the hook is the SOLE producer of selection (cell-click / head-click /
  # nav / nav-edge / nav-corner / select-all have no server-rendered phx-click
  # anywhere). Keying hook attachment on `editable` froze the selection on A1 for
  # BOTH populations `editable` excludes: a write-DENIED member, and a fully
  # write-capable member who flipped the View chip. The three nav heads already
  # refuse only `chrome: :reader`, so this adds no server surface; every write
  # stays governed by `editable` and, last of all, by `Ops.send_ops/2`.
  def derive_editable(socket) do
    assign(socket,
      editable: socket.assigns.mode == :edit and socket.assigns.write_capable,
      hookable: socket.assigns.chrome == :studio
    )
  end

  @doc """
  The workspace the live Sheets session for this grid is keyed under — the
  MOUNTED ROW's own `workspace_id` (task-f0c064a406e8d363).

  `Barkpark.Plugins.Sheets.Session` keys its registry by
  `{dataset, workspace_id, published-id}` and scopes its document read to that
  workspace, so every `Session.peek/3` and `Session.apply_ops/5` from this
  component MUST name the same tenant or it addresses a different (usually
  absent) session. It is the same value `Session.topic/3` and
  `Session.presence_topic/3` already key on (`StudioLive.Shared`'s
  `ensure_sheet_subscription/2` passes `doc.workspace_id`), so the delta topic
  and the session process agree by construction.

  Nil-safe: a socket without a `:doc` assign, or a legacy row with no
  workspace, yields `nil` — the unscoped session key, byte-identical to the
  pre-fix behaviour. ONE seam, so a new call site cannot quietly hand the
  session a different tenant than the topic.
  """
  @spec session_workspace_id(Phoenix.LiveView.Socket.t() | map()) :: String.t() | nil
  def session_workspace_id(%{assigns: assigns}), do: session_workspace_id(assigns)

  def session_workspace_id(assigns) when is_map(assigns) do
    case Map.get(assigns, :doc) do
      %{workspace_id: ws} -> ws
      _ -> nil
    end
  end

  # ── grid geometry ────────────────────────────────────────────────────────

  def tabs(socket), do: Map.get(socket.assigns.content || %{}, "tabs") || []

  def current_tab(socket),
    do: Enum.at(tabs(socket), socket.assigns.tab) || %{"name" => "Sheet 1", "cells" => %{}}

  def cell_at(socket, pos) do
    cells = Map.get(current_tab(socket), "cells") || %{}
    Map.get(cells, Sheets.format_ref(pos))
  end

  def used_bounds(tab) do
    cell_bounds =
      Enum.reduce(Map.get(tab, "cells") || %{}, {0, 0}, fn {addr, _cell}, {mc, mr} ->
        case Sheets.parse_ref(addr) do
          {:ok, {c, r}} -> {max(mc, c), max(mr, r)}
          :error -> {mc, mr}
        end
      end)

    Enum.reduce(Map.get(tab, "merges") || [], cell_bounds, fn m, {mc, mr} ->
      case Geometry.parse_range(m) do
        {:ok, {_c1, _r1, c2, r2}} -> {max(mc, c2), max(mr, r2)}
        :error -> {mc, mr}
      end
    end)
  end

  # `{anchor-spans, covered-cells}` for colspan/rowspan rendering, clipped
  # to the rendered bounds; degenerate (single-cell) merges drop.
  def merge_maps(tab, cols, rows) do
    Enum.reduce(Map.get(tab, "merges") || [], {%{}, MapSet.new()}, fn m, {spans, covered} = acc ->
      case Geometry.parse_range(m) do
        {:ok, {c1, r1, c2, r2}} when c1 <= cols and r1 <= rows ->
          c2 = min(c2, cols)
          r2 = min(r2, rows)

          if c2 > c1 or r2 > r1 do
            covered =
              for c <- c1..c2, r <- r1..r2, {c, r} != {c1, r1}, into: covered, do: {c, r}

            {Map.put(spans, {c1, r1}, {c2 - c1 + 1, r2 - r1 + 1}), covered}
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  # Release the covered cells a page-crossing rowspan leaves in THIS window.
  # `merge_maps/3` marks covered over the FULL logical grid, but the BODY only
  # iterates `first..last` and emits the spanning anchor <td> at {c1, r1}. When
  # a rowspan starts ABOVE the window (r1 < first) yet reaches into it, that
  # anchor is on a prior page — so the covered rows here would render one <td>
  # short and slot-fill left under the wrong header. Delete those in-window
  # covered cells so they render as plain (empty-by-merge-invariant) cells;
  # column alignment is restored, the merge simply does not visually continue
  # across the page break (a v1 bound, like frozen_rows forced to 0 on pages
  # > 0). Page 0 (first == 1) has no span with r1 < 1, so it is untouched; a
  # rowspan anchored INSIDE the window that overruns `last` is browser-clamped
  # at table end and needs no repair.
  defp release_boundary_covered(spans, covered, first) do
    Enum.reduce(spans, covered, fn {{c1, r1}, {w, h}}, cov ->
      if r1 < first and r1 + h - 1 >= first do
        for c <- c1..(c1 + w - 1), r <- first..(r1 + h - 1), reduce: cov do
          acc -> MapSet.delete(acc, {c, r})
        end
      else
        cov
      end
    end)
  end

  def clamp_frozen(n, limit) when is_integer(n) and n > 0, do: min(n, limit)

  # Schema/raw-API sheets may persist the frozen band as a STRING ("2") — the
  # document editor and importers do. Every other reader (Core.frozen_rows,
  # XlsxExport, Structure.frozen_count) Integer.parses it, so match their
  # coercion here or Studio alone would hide a real freeze and the toggle,
  # reading 0, would overwrite the stored band.
  def clamp_frozen(s, limit) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> min(n, limit)
      _ -> 0
    end
  end

  def clamp_frozen(_n, _limit), do: 0
end
