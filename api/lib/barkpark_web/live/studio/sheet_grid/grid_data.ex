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

  alias Barkpark.Plugins.Sheets.Core, as: Sheets
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
    offset = clamp_row_offset(socket.assigns[:row_offset] || 0, rows)
    first = offset * @max_rows + 1
    last = min(first + @max_rows - 1, rows)
    {spans, covered} = merge_maps(tab, cols, rows)

    assign(socket,
      all_tabs: all_tabs,
      cols: cols,
      rows: rows,
      used_cols: used_cols,
      used_rows: used_rows,
      # Columns past @max_cols are a notice-only clip (no horizontal paging in
      # v1): surfaced in the pager text, never silently dropped.
      col_truncated: used_cols > @max_cols,
      # HONEST a11y counts. When a sheet is clipped/paged the RENDERED window
      # (`cols`/`row_range`) is smaller than what exists, so aria-*count must
      # report the TRUE occupied bound, not the window: rows past one page
      # (`rows > @max_rows`) fall back to `used_rows`, columns past @max_cols to
      # `used_cols`. An unclipped sheet keeps the padded/floored grid dims so an
      # empty sheet still announces its editable extent.
      rows_total: if(rows > @max_rows, do: used_rows, else: rows),
      cols_total: if(used_cols > @max_cols, do: used_cols, else: cols),
      row_offset: offset,
      row_range: first..last,
      row_page_end: last,
      cells: Map.get(tab, "cells") || %{},
      spans: spans,
      covered: covered,
      col_widths: Map.get(tab, "col_widths") || %{},
      row_heights: Map.get(tab, "row_heights") || %{},
      frozen_cols: clamp_frozen(Map.get(tab, "frozen_cols"), cols),
      frozen_rows: clamp_frozen(Map.get(tab, "frozen_rows"), rows)
    )
  end

  # Clamp a requested page index into `[0, last-page]` so a forged, stale, or
  # content-shrank-underneath offset always lands on a real page — the pager
  # is pure navigation and must never fault.
  def clamp_row_offset(offset, total_rows) when is_integer(offset) do
    last_page = div(max(total_rows - 1, 0), @max_rows)

    offset |> max(0) |> min(last_page)
  end

  def clamp_row_offset(_offset, _total_rows), do: 0

  # `editable` rides the same persistence rule (it gates whole template
  # subtrees): derived on update (read_only may arrive) and on toggle-mode.
  def derive_editable(socket) do
    assign(socket, editable: socket.assigns.mode == :edit and not socket.assigns.read_only)
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
