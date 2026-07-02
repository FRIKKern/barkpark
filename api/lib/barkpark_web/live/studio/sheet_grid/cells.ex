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
  # the `sheet-err` marker class.
  @engine_errors ["#VALUE!", "#DIV/0!", "#REF!", "#CYCLE!"]

  def bar_value(cells, active),
    do: raw_of(Map.get(cells, Barkpark.Plugins.Sheets.Core.format_ref(active)))

  def raw_of(%{"f" => f}) when is_binary(f), do: "=" <> String.trim_leading(f, "=")
  def raw_of(cell), do: display(cell)

  def display(%{"v" => true}), do: "TRUE"
  def display(%{"v" => false}), do: "FALSE"
  def display(%{"v" => v}) when is_number(v),
    do: Barkpark.Plugins.Sheets.Core.number_to_display(v)
  def display(%{"v" => v}) when is_binary(v), do: v
  def display(_cell), do: ""

  def cell_class(c, r, sel, active, cell) do
    classes = ["sheet-cell"]

    classes = if in_sel_rect?(sel, c, r), do: ["sheet-sel" | classes], else: classes

    classes = if {c, r} == active, do: ["sheet-active" | classes], else: classes

    v = cell && Map.get(cell, "v")
    classes = if is_binary(v) and v in @engine_errors, do: ["sheet-err" | classes], else: classes

    classes =
      if cell && Map.get(cell, "stale") == true, do: ["sheet-stale" | classes], else: classes

    Enum.join(classes, " ")
  end

  # ARIA a11y helpers. `cell_dom_id` is the stable per-cell DOM id the grid
  # stamps on every data `<td>` so `aria-activedescendant` can point at the
  # active cell; `aria_selected` shares the SAME sel-rect membership
  # predicate `cell_class` uses for its `sheet-sel` mark (nil sel → false).
  def cell_dom_id(table_id, {c, r}), do: "#{table_id}-cell-#{c}-#{r}"

  def aria_selected(sel, c, r), do: if(in_sel_rect?(sel, c, r), do: "true", else: "false")

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

  defp s_style(%{"s" => %{} = s}) do
    [
      if(Map.get(s, "b") == true, do: " font-weight: 600;", else: ""),
      if(Map.get(s, "i") == true, do: " font-style: italic;", else: ""),
      case Map.get(s, "bg") do
        bg when is_binary(bg) ->
          if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, bg), do: " background: #{bg};", else: ""

        _ ->
          ""
      end,
      case Map.get(s, "al") do
        al when al in ["left", "center", "right"] -> " text-align: #{al};"
        _ -> ""
      end
    ]
    |> Enum.join()
  end

  defp s_style(_cell), do: ""

  def col_head_style(c, fc, col_widths) when c <= fc,
    do: "left: #{Geometry.left_px(c, col_widths)}px; z-index: 5;"

  def col_head_style(_c, _fc, _col_widths), do: nil

  def row_head_style(r, fr, row_heights) when r <= fr,
    do: "top: #{Geometry.top_px(r, row_heights)}px; z-index: 5;"

  def row_head_style(_r, _fr, _row_heights), do: nil
end
