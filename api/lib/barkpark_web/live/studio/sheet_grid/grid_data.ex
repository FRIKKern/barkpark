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
    {cols, rows, used_rows} = grid_dims(tab)
    {spans, covered} = merge_maps(tab, cols, rows)

    assign(socket,
      all_tabs: all_tabs,
      cols: cols,
      rows: rows,
      used_rows: used_rows,
      truncated: used_rows > @max_rows,
      cap_rows: @max_rows,
      cells: Map.get(tab, "cells") || %{},
      spans: spans,
      covered: covered,
      col_widths: Map.get(tab, "col_widths") || %{},
      row_heights: Map.get(tab, "row_heights") || %{},
      frozen_cols: clamp_frozen(Map.get(tab, "frozen_cols"), cols),
      frozen_rows: clamp_frozen(Map.get(tab, "frozen_rows"), rows)
    )
  end

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

  def dims(socket) do
    {cols, rows, _used} = grid_dims(current_tab(socket))
    {cols, rows}
  end

  def grid_dims(tab) do
    {mc, mr} = used_bounds(tab)
    {min(max(mc + 2, 8), @max_cols), min(max(mr + 2, 20), @max_rows), mr}
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
  def clamp_frozen(_n, _limit), do: 0
end
