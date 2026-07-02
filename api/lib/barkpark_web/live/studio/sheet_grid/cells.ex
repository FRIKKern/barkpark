defmodule BarkparkWeb.Studio.SheetGrid.Cells do
  @moduledoc """
  Pure cell-presentation helpers for `BarkparkWeb.Studio.SheetGrid` — the
  display string, formula-bar raw, css class list, and the inline sticky +
  `"s"` style strings the render template stamps on each `<td>`/`<th>`.
  No socket, no side effects: the facade's `~H` templates call these
  qualified (`Cells.display(...)`) so they never re-mark change-tracked
  assigns. Frozen-band px sums come from `Geometry.left_px`/`top_px`.
  """

  alias BarkparkWeb.Studio.SheetGrid.Geometry

  # Engine error markers — a cell whose computed `"v"` is one of these gets
  # the `sheet-err` marker class. Single-sourced from the engine's own
  # vocabulary (`Engine.error_values/0`) so a new code can't drift out of sync.
  @engine_errors Barkpark.Plugins.Sheets.Engine.error_values()

  def bar_value(cells, active),
    do: raw_of(Map.get(cells, Barkpark.Plugins.Sheets.Core.format_ref(active)))

  # Formula-bar value: the "=formula" for a formula cell, else the RAW
  # underlying value (never the fmt-formatted display) so an edit round-trips
  # the stored value, not "25.00%". Mirrors `display`'s pre-fmt semantics.
  def raw_of(%{"f" => f}) when is_binary(f), do: "=" <> String.trim_leading(f, "=")
  def raw_of(cell), do: raw_value(cell)

  # TSV clipboard value (`bp-sheet-grid.js` reads `data-v`): the computed raw
  # value — a formula cell exports its cached value, not "=formula", and a
  # fmt cell exports "0.25", not "25.00%", so a paste into Excel round-trips.
  def data_v(cell), do: raw_value(cell)

  defp raw_value(%{"v" => true}), do: "TRUE"
  defp raw_value(%{"v" => false}), do: "FALSE"
  defp raw_value(%{"v" => v}) when is_number(v),
    do: Barkpark.Plugins.Sheets.Core.number_to_display(v)
  defp raw_value(%{"v" => v}) when is_binary(v), do: v
  defp raw_value(_cell), do: ""

  # The VISIBLE cell text — fmt-aware. `Fmt.display/2` renders the cell's
  # `"fmt"` class ("25.00%", "$1,234.50", …); a nil fmt delegates to the
  # shared General formatter. The raw value stays in `raw_of`/`data_v`.
  #
  # The "checkbox" fmt renders a BOOLEAN cell as a glyph (nil / absent "v" =
  # unchecked). These clauses MUST sit ABOVE the bare-bool clauses below:
  # `def display(%{"v" => true})` short-circuits BEFORE consulting "fmt", so a
  # checkbox cell would otherwise render "TRUE"/"FALSE" text. The clause order
  # is pinned in `cells_test.exs`. A checkbox fmt on a NON-boolean value (a
  # number/string) falls through to the fmt-aware clauses → the General
  # formatter renders the text (Sheets semantics).
  def display(%{"fmt" => "checkbox", "v" => true}), do: "☑"
  def display(%{"fmt" => "checkbox", "v" => false}), do: "☐"
  def display(%{"fmt" => "checkbox", "v" => nil}), do: "☐"
  def display(%{"fmt" => "checkbox"} = cell) when not is_map_key(cell, "v"), do: "☐"
  def display(%{"v" => true}), do: "TRUE"
  def display(%{"v" => false}), do: "FALSE"
  def display(%{"v" => v} = cell) when is_number(v),
    do: Barkpark.Plugins.Sheets.Fmt.display(v, cell["fmt"])
  def display(%{"v" => v} = cell) when is_binary(v),
    do: Barkpark.Plugins.Sheets.Fmt.display(v, cell["fmt"])
  def display(_cell), do: ""

  # A cell whose ENTIRE value is an http(s) URL — the grid links it at display
  # time (no fmt class, no model change). The regex pins http(s) and bans
  # whitespace/quote/angle chars so an attribute-breaking payload never matches
  # ("see http://x" stays plain text); the scheme allowlist is re-checked at the
  # render seam (walk.ex `safe_url`, web `safeHref`) — this only gates the
  # affordance. Twin of walk.ex `@sheet_url_re` and web `isHttpUrl`.
  @url_re ~r/^https?:\/\/[^\s<>"']+$/i
  def link?(v) when is_binary(v), do: Regex.match?(@url_re, v)
  def link?(_v), do: false

  def cell_class(c, r, sel, active, cell, matches \\ nil) do
    classes = ["sheet-cell"]

    classes = if in_sel_rect?(sel, c, r), do: ["sheet-sel" | classes], else: classes

    classes = if {c, r} == active, do: ["sheet-active" | classes], else: classes

    # Find-in-sheet hit (Ctrl+F): only the cells in the current page window are
    # rendered, so a MapSet membership test here paints just the visible matches.
    classes =
      if matches && MapSet.member?(matches, {c, r}),
        do: ["sheet-find-hit" | classes],
        else: classes

    v = cell && Map.get(cell, "v")
    classes = if is_binary(v) and v in @engine_errors, do: ["sheet-err" | classes], else: classes

    classes =
      if cell && Map.get(cell, "stale") == true, do: ["sheet-stale" | classes], else: classes

    classes = if checkbox?(cell), do: ["sheet-checkbox" | classes], else: classes

    classes =
      if not checkbox?(cell) and link?(v), do: ["sheet-link-cell" | classes], else: classes

    Enum.join(classes, " ")
  end

  # A cell whose `"fmt"` is the display-only "checkbox" class — the grid renders
  # it as a toggleable glyph (see `display/1`) with a `role="checkbox"` span.
  def checkbox?(%{"fmt" => "checkbox"}), do: true
  def checkbox?(_cell), do: false

  # The `aria-checked` value for a checkbox cell's span — only a boolean `true`
  # reads as checked; nil / false / any other value reads as unchecked.
  def aria_checked(%{"v" => true}), do: "true"
  def aria_checked(_cell), do: "false"
  # ── find-in-sheet (Ctrl+F) ────────────────────────────────────────────────
  #
  # A pure, server-side scan of the SPARSE `cells` map. The grid body renders
  # only a 500-row DOM window (`GridData.rows_per_page`), so a client-side DOM
  # search structurally misses every off-page cell — matching MUST happen over
  # the whole map here. Case-insensitive substring against BOTH the raw stored
  # value (`raw_of` — so "=SUM" and the underlying "0.25" hit) AND the fmt
  # display (`display` — so "25.00%" hits what the user actually sees). Results
  # come back ordered row-major (`{r, c}`) so navigation reads top-to-bottom,
  # left-to-right like Excel. A blank query yields no matches.
  def find_matches(cells, query) when is_map(cells) and is_binary(query) do
    q = query |> String.trim() |> String.downcase()

    if q == "" do
      []
    else
      matches =
        for {addr, cell} <- cells,
            {:ok, {c, r}} <- [Barkpark.Plugins.Sheets.Core.parse_ref(addr)],
            cell_matches?(cell, q),
            do: {c, r}

      Enum.sort_by(matches, fn {c, r} -> {r, c} end)
    end
  end

  def find_matches(_cells, _query), do: []

  defp cell_matches?(cell, q) do
    String.contains?(String.downcase(raw_of(cell)), q) or
      String.contains?(String.downcase(display(cell)), q)
  end

  # The next/prev match relative to `active` in the row-major order, WRAPPING at
  # the ends. `dir` is `:next` | `:prev`; an empty match list yields nil. The
  # active cell itself is skipped (strict `>`/`<`) so repeated presses walk
  # every match instead of sticking on the current one.
  def next_match([], _active, _dir), do: nil

  def next_match(ordered, {ac, ar}, :next) do
    key = {ar, ac}
    Enum.find(ordered, fn {c, r} -> {r, c} > key end) || hd(ordered)
  end

  def next_match(ordered, {ac, ar}, :prev) do
    key = {ar, ac}

    ordered
    |> Enum.reverse()
    |> Enum.find(fn {c, r} -> {r, c} < key end) || List.last(ordered)
  end

  # ARIA a11y helpers. `cell_dom_id` is the stable per-cell DOM id the grid
  # stamps on every data `<td>` so `aria-activedescendant` can point at the
  # active cell; `aria_selected` shares the SAME sel-rect membership
  # predicate `cell_class` uses for its `sheet-sel` mark (nil sel → false).
  def cell_dom_id(table_id, {c, r}), do: "#{table_id}-cell-#{c}-#{r}"

  def aria_selected(sel, c, r), do: if(in_sel_rect?(sel, c, r), do: "true", else: "false")

  # Status-bar selection aggregate — Sheets shows SUM/AVG/COUNT for the
  # selected range. `rect` is `Geometry.selection_rect`'s `{c1,c2,r1,r2}`.
  # Returns nil for a single cell (nothing to aggregate) or a range holding
  # no numeric cells. Iterates the SPARSE `cells` map (never the dense rect)
  # and keeps only cells whose stored `"v"` is a number — booleans are atoms
  # and engine-error strings are binaries, so `is_number/1` excludes both.
  def sel_stats(_cells, {c1, c1, r1, r1}), do: nil

  def sel_stats(cells, {_c1, _c2, _r1, _r2} = rect) do
    nums =
      for {addr, %{"v" => v}} <- cells,
          is_number(v),
          {:ok, {c, r}} <- [Barkpark.Plugins.Sheets.Core.parse_ref(addr)],
          in_sel_rect?(rect, c, r),
          do: v

    case nums do
      [] -> nil
      _ -> %{sum: Enum.sum(nums), avg: Enum.sum(nums) / length(nums), count: length(nums)}
    end
  end

  def sel_stats(_cells, _rect), do: nil

  defp in_sel_rect?({c1, c2, r1, r2}, c, r),
    do: c >= c1 and c <= c2 and r >= r1 and r <= r2

  defp in_sel_rect?(_sel, _c, _r), do: false

  # Frozen bands pin via CSS sticky with computed px offsets; cell "s"
  # styles append last so a cell bg wins over the frozen backdrop.
  def cell_style(c, r, fc, fr, col_widths, row_heights, cell) do
    sticky =
      cond do
        c <= fc and r <= fr ->
          "position: sticky; left: #{Geometry.left_px(c, col_widths)}px; top: #{Geometry.top_px(r, row_heights)}px; z-index: 2; background: var(--bg);"

        c <= fc ->
          "position: sticky; left: #{Geometry.left_px(c, col_widths)}px; z-index: 2; background: var(--bg);"

        r <= fr ->
          "position: sticky; top: #{Geometry.top_px(r, row_heights)}px; z-index: 1; background: var(--bg);"

        true ->
          ""
      end

    case sticky <> s_style(cell) do
      "" -> nil
      style -> style
    end
  end

  defp s_style(%{"s" => %{} = s} = cell) do
    [
      if(Map.get(s, "b") == true, do: " font-weight: 600;", else: ""),
      if(Map.get(s, "i") == true, do: " font-style: italic;", else: ""),
      case Map.get(s, "bg") do
        bg when is_binary(bg) ->
          if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, bg), do: " background: #{bg};", else: ""

        _ ->
          ""
      end,
      # Explicit al always wins; only its ABSENCE falls back to the
      # value-shaped default (numbers right, booleans center — see below).
      case Map.get(s, "al") do
        al when al in ["left", "center", "right"] -> " text-align: #{al};"
        _ -> default_align(cell)
      end
    ]
    |> Enum.join()
  end

  defp s_style(cell), do: default_align(cell)

  # Spreadsheet-default alignment for cells WITHOUT an explicit s.al: numeric
  # values and number-shaped fmts (currency/percent/…/date) read right-aligned
  # like Sheets/Excel General; booleans and checkbox cells center; text emits
  # nothing and inherits the table's left. Clause order: checkbox/boolean
  # centering outranks the fmt-based right default.
  defp default_align(%{"fmt" => "checkbox"}), do: " text-align: center;"
  defp default_align(%{"v" => v}) when is_boolean(v), do: " text-align: center;"
  defp default_align(%{"v" => v}) when is_number(v), do: " text-align: right;"

  defp default_align(%{"fmt" => fmt})
       when fmt in ["currency", "percent", "thousands", "fixed", "date", "datetime"],
       do: " text-align: right;"

  defp default_align(_cell), do: ""

  def col_head_style(c, fc, col_widths) when c <= fc,
    do: "left: #{Geometry.left_px(c, col_widths)}px; z-index: 5;"

  def col_head_style(_c, _fc, _col_widths), do: nil

  def row_head_style(r, fr, row_heights) when r <= fr,
    do: "top: #{Geometry.top_px(r, row_heights)}px; z-index: 5;"

  def row_head_style(_r, _fr, _row_heights), do: nil
end
