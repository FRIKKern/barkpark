defmodule BarkparkWeb.Studio.SheetGrid.Filter do
  @moduledoc """
  Per-viewer row-filter predicate for `BarkparkWeb.Studio.SheetGrid` — pure,
  no socket, no I/O (slice SF-B, paper §3+§4).

  Filter is the Google Sheets "Filter views" model (arc-3 decision SF-D2): it
  is socket-assigns VIEW-STATE only. It NEVER mutates the document — no op, no
  persist, no broadcast, zero wire surface. Each viewer's criteria live on
  their own socket; the stored sheet and every collaborator are untouched.

  ## The predicate (SF-D7)

  Criteria are a `%{col_index => criterion}` map (0-based? no — absolute
  1-based grid columns, matching `Core.format_ref/1`). Each `criterion` is
  `%{"op" => op, "value" => v, "value2" => v2}` with

      op ∈ {"blank", "nonblank"} ∪ {"gt", "lt", "eq", "between", "contains"}

  The five VALUE ops delegate to `Barkpark.Plugins.Sheets.CondFormat.matches?/2`
  — the ONE eval kernel (the CF-D5 matrix, verbatim). Because that matrix has
  blanks and errors NEVER match a value op, any value criterion hides blank
  rows exactly like Excel's number filters. `blank`/`nonblank` are filter-only
  occupancy tests on the CF-D5 blank class (no cell, or `v` nil/`""`).

  A row is visible iff EVERY filtered column's criterion matches its cell
  (AND across columns). The predicate applies to DATA rows only (row ≤
  `used_rows`); rows past `used_rows` (the growth padding) and the frozen head
  band (row ≤ `frozen_rows`) are ALWAYS visible (SF-D7).

  Totality: the predicate NEVER raises. An unrecognized criterion fails OPEN
  (the row stays visible) — filter is view-state, so a criterion this module
  cannot understand must never make a viewer's data silently vanish. In
  practice criteria are only ever built by the funnel handlers with a known
  op, so the fail-open clause is unreachable defence.
  """

  alias Barkpark.Plugins.Sheets.CondFormat
  alias Barkpark.Plugins.Sheets.Core

  @value_ops ~w(gt lt eq between contains)

  @doc """
  Does one column's `criterion` match `cell` (a raw cell map or `nil`)?

    * `blank` — the CF-D5 blank class: no cell, or `v` is nil/`""`;
    * `nonblank` — the complement;
    * `gt`/`lt`/`eq`/`between`/`contains` — the CF-D5 value matrix, via the ONE
      kernel `CondFormat.matches?/2` (blanks and errors never match, so a value
      criterion hides blank rows like Excel);
    * anything else — `true` (fail open, view-state safety).
  """
  @spec matches?(term(), map() | nil) :: boolean()
  def matches?(%{"op" => "blank"}, cell), do: blank?(cell)
  def matches?(%{"op" => "nonblank"}, cell), do: not blank?(cell)

  def matches?(%{"op" => op} = criterion, cell) when op in @value_ops,
    do: CondFormat.matches?(criterion, cell)

  def matches?(_criterion, _cell), do: true

  # The CF-D5 blank class — a `nil` cell, a missing "v", or `v` nil/"".
  defp blank?(nil), do: true

  defp blank?(%{} = cell) do
    v = Map.get(cell, "v")
    is_nil(v) or v == ""
  end

  defp blank?(_), do: true

  @doc """
  Is `row` visible under `criteria`? DATA rows (row ≤ `used_rows`) run the
  predicate; the frozen head band (row ≤ `frozen_rows`) and the growth padding
  (row > `used_rows`) are ALWAYS visible; empty criteria → always visible
  (the byte-identical no-filter fast path). `cells` is the sparse A1 map.
  """
  @spec row_visible?(integer(), map(), map(), integer(), integer()) :: boolean()
  def row_visible?(row, criteria, cells, used_rows, frozen_rows)
      when is_integer(row) and is_map(criteria) and is_map(cells) do
    cond do
      map_size(criteria) == 0 -> true
      row <= frozen_rows -> true
      row > used_rows -> true
      true -> Enum.all?(criteria, fn {col, crit} -> matches?(crit, cell_at(cells, col, row)) end)
    end
  end

  def row_visible?(_row, _criteria, _cells, _used_rows, _frozen_rows), do: true

  @doc """
  Filter `rows` (a range or list of row indexes) down to the visible ones —
  the whole-height pass `GridData.derive_grid/1` pages over (SF-D8).
  """
  @spec visible_rows(Enumerable.t(), map(), map(), integer(), integer()) :: [integer()]
  def visible_rows(rows, criteria, cells, used_rows, frozen_rows) do
    Enum.filter(rows, &row_visible?(&1, criteria, cells, used_rows, frozen_rows))
  end

  defp cell_at(cells, col, row) when is_integer(col),
    do: Map.get(cells, Core.format_ref({col, row}))

  defp cell_at(_cells, _col, _row), do: nil
end
