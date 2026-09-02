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

  # Engine error markers — a cell whose computed `"v"` is one of these gets the
  # `sheet-err` marker class. Mirrored LOCALLY (no compile-time edge into the
  # Sheets plugin namespace, so an engine touch no longer forces this module to
  # recompile). The canonical owner stays `Barkpark.Plugins.Sheets.Engine.
  # error_values/0` (@canonical engine-error-vocabulary); a drift-guard test
  # (sheets_parity_test) asserts THIS mirror EQUALS that list, so a new code
  # can't silently fork.
  @engine_errors ~w(#CYCLE! #REF! #VALUE! #DIV/0! #N/A #NUM! #SPILL! #NAME?)

  # @doc false accessor — exists ONLY so the drift-guard test can assert this
  # local mirror equals `Barkpark.Plugins.Sheets.Engine.error_values/0`.
  @doc false
  def error_vocab, do: @engine_errors

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

  # The stored formula for a cell WITHOUT the leading "=", or nil for a
  # literal cell — the `data-f` td stamp's only source. Twin of `data_v`
  # (the computed value): where `data_v` carries what a paste into Excel
  # sees, `data-f` carries the rebase-able SOURCE the client formula
  # clipboard (S-CLIP) reads to carry formulas through copy/paste. Only the
  # EDITABLE grid stamps it (readers stay formula-free, like `data-fns`), so
  # the client never round-trips the server for the formula truth. A blank
  # or absent formula yields nil so LiveView omits the attribute entirely
  # (parallel to `data_t/1`'s nil-omits-the-attr contract).
  def formula(%{"f" => f}) when is_binary(f) do
    case String.trim_leading(f, "=") do
      "" -> nil
      stripped -> stripped
    end
  end

  def formula(_cell), do: nil

  # Value-type marker stamped as `data-t` on each `<td>` — "n" when the cell's
  # computed value is numeric (a plain number OR a formula whose cached "v" is
  # a number), `nil` otherwise so the attribute is simply omitted. This is the
  # server-side signal the formula-UX client reads to ghost-suggest a range
  # (`=SUM(` under a numeric column) without re-parsing the display string.
  # Deliberately STRICT — `is_number` only, never trusting a stored `"t"`
  # stamp: every mainline write path (Studio `parse_raw`, xlsx/CSV import,
  # engine write-back) stores genuine numbers, and for a ghost that COMMITS on
  # Enter a false positive (suggesting a mislabeled text cell) is worse than a
  # false negative (a legacy `{"v" => "7", "t" => "n"}` cell just not
  # suggesting — the engine still coerces it fine at eval time).
  def data_t(%{"v" => v}) when is_number(v), do: "n"
  def data_t(_cell), do: nil

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

    # `sheet-err` has TWO sources. The obvious one is a computed error value.
    # The second is a cell whose formula names a function the engine cannot
    # evaluate but which KEPT its imported value (`stale_fn`, main's ruling
    # 2026-09-02): that number is real — Excel computed it — so it keeps
    # rendering, but a plausible number the engine did not produce must never
    # hide behind the quiet stale dot. It is error-styled AND titled
    # (`cell_title/1`) with the name it could not evaluate.
    classes =
      if (is_binary(v) and v in @engine_errors) or unsupported_fn(cell),
        do: ["sheet-err" | classes],
        else: classes

    classes =
      if cell && Map.get(cell, "stale") == true, do: ["sheet-stale" | classes], else: classes

    classes = if checkbox?(cell), do: ["sheet-checkbox" | classes], else: classes

    classes =
      if not checkbox?(cell) and link?(v), do: ["sheet-link-cell" | classes], else: classes

    # Spreadsheet-default alignment marker (numbers right, booleans center) —
    # a CLASS, not an inline style, on purpose: the sheets-parity suite pins
    # the inline b/i/bg/al styles as identical across every render surface,
    # and an explicit s.al (inline text-align) outranks the class by CSS
    # precedence anyway. See default_align_class/1 below.
    classes =
      case default_align_class(cell) do
        nil -> classes
        al_class -> [al_class | classes]
      end

    Enum.join(classes, " ")
  end

  # The `title` a `<td>` carries — hover/inspect text, `nil` for an ordinary
  # cell so LiveView omits the attribute entirely. Today its ONE source is the
  # unsupported-function marker the engine writes next to a kept import value
  # (`"stale_fn" => "FOO"`): the value stays on screen, and this says why it is
  # not live. Twin of the `sheet-err` arm in `cell_class/6` — the class is the
  # loud style, this is the reason.
  def cell_title(cell) do
    case unsupported_fn(cell) do
      nil -> nil
      fname -> "not evaluated: " <> fname <> " is not supported"
    end
  end

  # The engine's `"stale_fn"` stamp — the first function name a formula used
  # that the engine does not implement — or nil for every other cell.
  defp unsupported_fn(cell) when is_map(cell) do
    case Map.get(cell, "stale_fn") do
      fname when is_binary(fname) and fname != "" -> fname
      _ -> nil
    end
  end

  defp unsupported_fn(_cell), do: nil

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
  #
  # IT KEYS ON THE SELECTION AXIS, NEVER ON EDITABILITY (wave 43). The old
  # arity-4 form took `editable` and returned nil for every not-editable grid,
  # on the reasoning that such a grid "has no selection at all" — which was
  # false for exactly the population this surface was hurting: a Studio grid in
  # View mode, or a write-DENIED member, gets a real `Geometry.grid_sel/3` rect
  # and paints `sheet-sel`, so a keyboard-navigable selection was silent to
  # assistive tech. The axis is now read off `sel` itself: the reader's
  # degenerate `{0, 0, 0, 0}` (grid_sel/3's `:reader` clause — off the 1-based
  # grid, no cell can ever match) is the ONE shape with genuinely no selection,
  # and only it returns nil so LiveView omits the attribute entirely.
  def cell_dom_id(table_id, {c, r}), do: "#{table_id}-cell-#{c}-#{r}"

  def aria_selected({0, 0, 0, 0}, _c, _r), do: nil

  def aria_selected(sel, c, r),
    do: if(in_sel_rect?(sel, c, r), do: "true", else: "false")

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

  # The fill-handle NUB renders on the selection rect's bottom-right corner td
  # (Excel/Sheets). Same rect shape `cell_class` consumes; the read-only grid
  # passes {0,0,0,0} (off the 1-based grid), so no cell ever matches there.
  def fill_nub?({_c1, c2, _r1, r2}, c, r), do: c == c2 and r == r2
  def fill_nub?(_sel, _c, _r), do: false

  # Max-content width for a column (double-click a header resize handle):
  # scan the SPARSE cells map for the column's occupied cells and derive a px
  # width from the longest DISPLAY string (fmt-aware — "$1,234.50" is what the
  # user sees) via a per-char heuristic (~7px at the grid's 12px font) plus
  # cell padding, clamped to sane bounds. nil when the column holds nothing —
  # the caller sends no op. Rows never wrap, so the row twin is a constant
  # reset to the single-line default (24px) at the call site.
  @autofit_char_px 7
  @autofit_pad_px 16
  @autofit_min_px 40
  @autofit_max_px 600
  def autofit_col_px(cells, col) when is_map(cells) and is_integer(col) do
    chars =
      for {addr, cell} <- cells,
          {:ok, {^col, _r}} <- [Barkpark.Plugins.Sheets.Core.parse_ref(addr)],
          do: String.length(display(cell))

    case chars do
      [] ->
        nil

      _ ->
        (Enum.max(chars) * @autofit_char_px + @autofit_pad_px)
        |> max(@autofit_min_px)
        |> min(@autofit_max_px)
    end
  end

  # Frozen bands pin via CSS sticky with computed px offsets; cell "s" styles
  # (and any conditional-format style) append LAST so a cell bg wins over the
  # frozen backdrop. `cf` is the precomputed conditional-format style map for
  # THIS cell (or nil) — `GridData.derive_grid/1` builds it from the tab's
  # `cond_formats` via the ONE CondFormat kernel (CF-D1, no forked eval). Per
  # CF-D3 the CF style wins the keys it sets (bg, and b/i when present); the
  # manual "s" keeps every other key (al). A nil `cf` (the no-rules default)
  # is BYTE-IDENTICAL to the historical manual-only path.
  def cell_style(c, r, fc, fr, col_widths, row_heights, cell, cf \\ nil) do
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

    case sticky <> s_style(cell, cf) do
      "" -> nil
      style -> style
    end
  end

  # No CF for this cell → the historical manual-"s"-only path, byte-identical.
  defp s_style(cell, nil), do: s_style(cell)

  # CF present → compose the manual "s" UNDER the CF style (CF-D3: CF wins the
  # keys it sets) through the ONE kernel, then emit the shared vocabulary.
  defp s_style(cell, cf) when is_map(cf) do
    manual =
      case cell do
        %{"s" => %{} = s} -> s
        _ -> nil
      end

    style_css(Barkpark.Plugins.Sheets.CondFormat.compose(manual, cf))
  end

  defp s_style(%{"s" => %{} = s}), do: style_css(s)
  defp s_style(_cell), do: ""

  # Emit the b/i/bg/al inline-style vocabulary from a (manual OR CF-composed)
  # style map — bg is re-validated against #rrggbb at the render seam, so a
  # malformed value never reaches a style attribute.
  defp style_css(s) do
    [
      if(Map.get(s, "b") == true, do: " font-weight: 600;", else: ""),
      if(Map.get(s, "i") == true, do: " font-style: italic;", else: ""),
      case Map.get(s, "bg") do
        bg when is_binary(bg) ->
          if Barkpark.Plugins.Sheets.CondFormat.valid_bg?(bg), do: " background: #{bg};", else: ""

        _ ->
          ""
      end,
      case Map.get(s, "al") do
        al when al in ["left", "center", "right"] ->
          " text-align: #{al};"

        _ ->
          ""
      end
    ]
    |> Enum.join()
  end

  # Spreadsheet-default alignment class for cells WITHOUT an explicit s.al:
  # numeric values and number-shaped fmts (currency/percent/…/datetime) read
  # right-aligned like Sheets/Excel General; booleans and checkbox cells
  # center; text gets no class and inherits the table's left. An explicit
  # s.al suppresses the class (first clause) — and would beat it anyway,
  # since s_style emits it as an inline style. Clause order matters:
  # explicit-al > checkbox/boolean centering > the numeric right default.
  defp default_align_class(%{"s" => %{"al" => al}})
       when al in ["left", "center", "right"],
       do: nil

  defp default_align_class(%{"fmt" => "checkbox"}), do: "sheet-al-center"
  defp default_align_class(%{"v" => v}) when is_boolean(v), do: "sheet-al-center"
  defp default_align_class(%{"v" => v}) when is_number(v), do: "sheet-al-right"

  defp default_align_class(%{"fmt" => fmt})
       when fmt in ["currency", "percent", "thousands", "fixed", "date", "datetime"],
       do: "sheet-al-right"

  defp default_align_class(_cell), do: nil

  def col_head_style(c, fc, col_widths) when c <= fc,
    do: "left: #{Geometry.left_px(c, col_widths)}px; z-index: 5;"

  def col_head_style(_c, _fc, _col_widths), do: nil

  def row_head_style(r, fr, row_heights) when r <= fr,
    do: "top: #{Geometry.top_px(r, row_heights)}px; z-index: 5;"

  def row_head_style(_r, _fr, _row_heights), do: nil
end
