defmodule Barkpark.Plugins.Sheets.Engine do
  @moduledoc """
  The Sheets formula engine — recomputes cached `"v"` values for every
  formula cell of a sheet document's content, AHEAD of snapshot synthesis
  (`Barkpark.Plugins.Sheets.Core.snapshot_for/2`). `Barkpark.Content` calls `recompute/1`
  on every `"sheet"` save, so HTTP mutations persist computed values and the
  write-through snapshots project them into embeds with zero renderer
  changes. Pure functions: no Repo, no I/O — except `TODAY`/`NOW`, which
  read the wall clock and are therefore volatile-as-of-last-save (they
  recompute only when the sheet is saved, not on every read).

  ## Canonical formula form

  A formula cell carries `"f"` as a string WITHOUT a leading `"="` — that is
  the canonical stored form (matching what xlsx readers emit). A single
  leading `"="` is tolerated on read and stripped before parsing, so
  user-typed `"=SUM(A1:B2)"` and stored `"SUM(A1:B2)"` are equivalent. The
  engine never rewrites `"f"`.

  ## Grammar

  Numbers (`42`, `1.5`, `.5`), strings (`"..."`, with `""` escaping an
  embedded quote), booleans (`TRUE`/`FALSE`, case-insensitive), cell refs
  (`A1`; `$A$1` is treated as `A1`), ranges (`A1:B5`, corners normalized),
  arithmetic `+ - * / ^`, unary minus, comparison `= <> < <= > >=`, string
  concat `&`, parentheses, and function calls. Precedence follows Excel:
  unary minus binds tighter than `^` (`-2^2` is `4`), `^` is left-associative
  (`2^3^2` is `64`), then `* /`, then `+ -`, then `&`, then comparisons.
  Refs resolve within the cell's OWN tab — cross-tab references are out of
  scope (no `Tab!A1` syntax; `!` fails the grammar, yielding `#REF!`). The
  grid is bounded at column XFD (16,384) and row 1,048,576 (the Excel
  limits); a ref beyond either bound is `#REF!`.

  ## Functions

  `SUM`, `AVG` (alias `AVERAGE`), `MIN`, `MAX`, `COUNT` (numbers only),
  `COUNTA` (non-empty), `IF`, `ROUND`, `ABS` — case-insensitive. Aggregates
  flatten ranges; inside a range only numbers participate (strings, booleans
  and dates are skipped; an error value propagates). A direct scalar argument
  to a strict aggregate must be a number (blank is skipped, anything else is
  `#VALUE!`). `COUNT`/`COUNTA` never propagate errors: `COUNT` counts
  numbers, `COUNTA` counts every non-empty value (errors included). `IF`
  evaluates its condition first and only the chosen branch (`IF(TRUE,1,1/0)`
  is `1`), with a numeric condition coerced (`0` falsy) and a missing else
  branch defaulting to `FALSE`. `ROUND` rounds half away from zero and
  accepts negative digit counts. A known function called with the wrong
  arity is `#VALUE!`.

  Beyond that core, the library also covers:

    * Logic — `AND`, `OR` (1+ args), `NOT`, `IFERROR`. `AND`/`OR` coerce
      each argument through the same truthiness rule as `IF` (numbers via
      `!= 0`, blanks falsy); a range argument flattens and keeps only its
      numbers/booleans (text is skipped, per Excel); an error argument
      propagates and zero coercible values is `#VALUE!`. `IFERROR(x, y)`
      returns `x` unless it is an error, in which case it returns `y`.
    * Info — `ISBLANK`, `ISNUMBER`, `ISTEXT`, `ISLOGICAL`, `ISERROR`,
      `ISERR` (errors except `#N/A`) and `ISNA`. Each classifies its one
      argument into a boolean and NEVER propagates its error.
    * Branching — `CHOOSE(k, …)` (out-of-range `k` is `#VALUE!`),
      `SWITCH(expr, val, res, …, [default])` (case-insensitive text match,
      no match + no default is `#N/A`) and `IFS(cond, res, …)` (even arity,
      none true is `#N/A`). All are lazy like `IF`: only the selected
      result AST evaluates.
    * Math — `ROUNDUP`/`ROUNDDOWN` mirror `ROUND` (negative digit counts
      too) but round away from / toward zero, and `INT` floors to an
      integer (`INT(-1.5)` is `-2`).
    * Text — `LEN`, `TRIM` (collapses internal space runs), `UPPER`,
      `LOWER`, `LEFT`/`RIGHT` (count defaults to 1), `MID` (1-based),
      `CONCATENATE` and `TEXTJOIN` (delimiter + ignore-empty flag). Also
      `EXACT` (the one case-SENSITIVE compare), `FIND` (case-sensitive) and
      `SEARCH` (case-insensitive + `*`/`?` wildcards) — both 1-based, a miss
      is `#VALUE!`; `SUBSTITUTE(text, old, new, [nth])`, `REPLACE` (1-based
      splice), `REPT` (capped at 32,767 chars), `PROPER`, and `VALUE`
      (numeric text, trailing `%` scales by 1/100). Scalars coerce through
      the `&` operator's text rule; a range argument is `#VALUE!` except in
      `TEXTJOIN`, which flattens it.
    * Dates — `DATE(y, m, d)` (an impossible date is `#VALUE!`), `YEAR`,
      `MONTH`, `DAY` (of a date/datetime cell), and the volatile `TODAY`
      (no args) and `NOW` (no args).
    * Conditional aggregates — `COUNTIF`, `SUMIF`, `AVERAGEIF` with the Excel
      criteria mini-language: a leading comparator (`>=` `<=` `<>` `=` `>` `<`;
      a bare value means `=`), numeric-looking text re-parsed against numeric
      criteria, `*`/`?` wildcards (`~` escapes them), case-insensitive text,
      blank-cell rules (blank never matches `>=0`), and a sum/average range
      required to match the criteria range's shape. The plural
      `COUNTIFS`/`SUMIFS`/`AVERAGEIFS` AND-combine one-or-more
      criteria-range/criteria pairs of identical shape (for `SUMIFS`/`AVERAGEIFS`
      the sum range comes FIRST, before the pairs); a shape mismatch is `#VALUE!`
      and `AVERAGEIFS` over zero numeric matches is `#DIV/0!`.
    * Lookup — `VLOOKUP`, `MATCH`, `INDEX`. Text matching is
      case-insensitive and cross-type never matches; blank cells are SKIPPED
      (as Excel does). Exact modes scan in ascending position order;
      approximate modes (`VLOOKUP` with a truthy/omitted 4th arg, `MATCH`
      type `1`/`-1`) assume the lookup vector is sorted ascending/descending
      the way Excel does and return the nearest neighbor. `MATCH` positions
      are coordinate-derived, so blank gaps still count toward the position.
    * Statistics — `MEDIAN`, `SMALL`/`LARGE` (kth smallest/largest),
      `PERCENTILE`/`QUARTILE` (linear interpolation between order statistics),
      `MODE` (most frequent value; `#N/A` when nothing repeats, ties broken by
      earliest first occurrence), `RANK` (`1 +` strictly-better count, order arg
      `0`/omitted → descending), `VAR`/`STDEV` (sample, `n−1`) and
      `VARP`/`STDEVP` (population, `n`). A domain miss — empty input or `k` out
      of range — is `#NUM!`; the variance floors (`VAR`/`STDEV` below two
      values, `VARP`/`STDEVP` below one) are `#DIV/0!`.

  ## Dynamic arrays (array-in / scalar-out, no spill)

  `UNIQUE`, `SORT`, `FILTER`, `SEQUENCE` and the Google-Sheets cheap win
  `COUNTUNIQUE` produce an *intermediate* array that an OUTER function
  consumes — the composed everyday forms `SUM(UNIQUE(A1:A9))`,
  `COUNTA(FILTER(A1:A9, B1:B9))`, `TEXTJOIN(",", 1, SORT(A1:A5))`. There is NO
  spill: one value per cell is preserved, the array is never persisted, and
  because an array function's dependencies are its LITERAL range args (already
  collected by the dependency walk), the topological graph is unchanged — a
  cell reading `SUM(UNIQUE(A1:A3))` recomputes when `A2` changes exactly as a
  plain range would.

    * `UNIQUE(range)` — the range's non-blank values in coordinate order,
      duplicates dropped keeping first occurrence.
    * `SORT(range, [order])` — `order` `-1` sorts descending, anything else
      (default) ascending; numbers sort before text before booleans. (This is
      a 1-D simplification of Excel's `SORT(array, sort_index, sort_order)`:
      the flattened vector has a single sort key, so the second arg is the
      ORDER, not a column index.)
    * `FILTER(range, include)` — keeps each `range` value whose positionally
      aligned `include` value is truthy (numbers via `!= 0`, `TRUE`; blank and
      text are falsy). `range` and `include` must flatten to the same length,
      else `#VALUE!`.
    * `SEQUENCE(rows, [cols], [start], [step])` — pure generation, row-major;
      `start`/`step` default to `1`. A non-positive dimension is `#VALUE!` and
      `rows*cols` beyond the array cap is `#NUM!`.
    * `COUNTUNIQUE(args…)` — the count of distinct non-blank values across its
      arguments (ranges, arrays and scalars).

  Blanks inside the array are dropped exactly as an aggregate drops blank
  range cells; an error value anywhere in the source propagates, as it does
  from a range. Consumed by every aggregate (`SUM`/`COUNTA`/…), by `AND`/`OR`,
  and by `TEXTJOIN` with the same flatten rules those apply to a range today.

  **Implicit intersection.** An array used where a single value is expected —
  a top-level `=UNIQUE(A1:A5)` alone in a cell, or an arm of arithmetic — is
  reduced to its top-left element (Excel's legacy `@` semantics), since the
  engine does not spill.

      iex> cells = %{"A1" => %{"v" => 2}, "A2" => %{"v" => 2}, "A3" => %{"v" => 5},
      ...>   "B1" => %{"f" => "SUM(UNIQUE(A1:A3))"}}
      iex> content = %{"tabs" => [%{"cells" => cells}]}
      iex> Barkpark.Plugins.Sheets.Engine.recompute(content)
      ...> |> get_in(["tabs", Access.at(0), "cells", "B1", "v"])
      7

      iex> cells = %{"A1" => %{"v" => 10}, "A2" => %{"v" => 20}, "A3" => %{"v" => 30},
      ...>   "B1" => %{"v" => true}, "B2" => %{"v" => false}, "B3" => %{"v" => true},
      ...>   "C1" => %{"f" => "COUNTA(FILTER(A1:A3, B1:B3))"}}
      iex> content = %{"tabs" => [%{"cells" => cells}]}
      iex> Barkpark.Plugins.Sheets.Engine.recompute(content)
      ...> |> get_in(["tabs", Access.at(0), "cells", "C1", "v"])
      2

      iex> cells = %{"A1" => %{"v" => 3}, "A2" => %{"v" => 1}, "A3" => %{"v" => 2},
      ...>   "B1" => %{"f" => ~s|TEXTJOIN(",", 1, SORT(A1:A3))|}}
      iex> content = %{"tabs" => [%{"cells" => cells}]}
      iex> Barkpark.Plugins.Sheets.Engine.recompute(content)
      ...> |> get_in(["tabs", Access.at(0), "cells", "B1", "v"])
      "1,2,3"

      iex> cells = %{"A1" => %{"v" => 7}, "A2" => %{"v" => 7}, "A3" => %{"v" => 9},
      ...>   "B1" => %{"f" => "UNIQUE(A1:A3)"}}
      iex> content = %{"tabs" => [%{"cells" => cells}]}
      iex> Barkpark.Plugins.Sheets.Engine.recompute(content)
      ...> |> get_in(["tabs", Access.at(0), "cells", "B1", "v"])
      7

      iex> cells = %{"A1" => %{"v" => 4}, "A2" => %{"f" => "1/0"}, "A3" => %{"v" => 6},
      ...>   "B1" => %{"f" => "SUM(UNIQUE(A1:A3))"}}
      iex> content = %{"tabs" => [%{"cells" => cells}]}
      iex> Barkpark.Plugins.Sheets.Engine.recompute(content)
      ...> |> get_in(["tabs", Access.at(0), "cells", "B1", "v"])
      "#DIV/0!"

      iex> cells = %{"A1" => %{"v" => 5}, "A3" => %{"v" => 5}, "A4" => %{"v" => 8},
      ...>   "B1" => %{"f" => "COUNTUNIQUE(A1:A4)"}}
      iex> content = %{"tabs" => [%{"cells" => cells}]}
      iex> Barkpark.Plugins.Sheets.Engine.recompute(content)
      ...> |> get_in(["tabs", Access.at(0), "cells", "B1", "v"])
      2

  ## Errors, cycles, stale

  Six error values, written with `"t" => "e"`:

    * `#CYCLE!` — every formula on a reference cycle, and every formula that
      (transitively) depends on one. Dependencies are collected from the full
      AST, both `IF` branches included.
    * `#REF!` — a formula outside the grammar (parse/lex failure, a bare
      identifier, cross-tab syntax) or a ref beyond the grid bounds.
    * `#VALUE!` — type mismatch (`"abc"+1`), a range used as a scalar, or a bad
      condition/arity.
    * `#DIV/0!` — division by zero (also `0^negative`, and `AVG` of nothing).
    * `#N/A` — a lookup found nothing (`NA()`; MATCH/VLOOKUP misses; `MODE`
      with no repeat; `RANK` of an absent value).
    * `#NUM!` — a numeric argument outside a function's domain: `(-8)^0.5`, a
      float-overflowing arithmetic result (`1e308*1e308`), `SMALL(A1:A2,0)`, a
      `PERCENTILE` fraction outside `0..1`, or an order statistic over no
      numbers.

  Errors propagate through references: a formula reading a cell whose value
  is an error yields that error. A literal cell whose `"v"` is one of the
  six error strings (or whose `"t"` is `"e"`) propagates the same way.

  A call to an UNKNOWN function never errors: the cell keeps its existing
  `"v"`/`"t"` untouched and gains `"stale" => true` (xlsx-import
  compatibility — the imported cached value keeps rendering). Dependents
  read that cached value. Any decisive recompute — a computed value or a
  computed error — clears the flag.

  ## Values

  Ints stay ints when the result is exact (`6/3` is `2`, `7/2` is `3.5`);
  any float operand keeps the result a float. Blank/empty refs coerce to `0`
  in arithmetic and to `""` in concat, are skipped by aggregates, and a bare
  ref to a blank cell yields `0`. Cells with `"t"` `"date"`/`"datetime"`
  hold ISO-8601 strings: date + number advances by (whole) days, date - date
  is a number of days, anything else with a date is `#VALUE!`. String
  comparison is case-insensitive; `=`/`<>` across mismatched types are
  `FALSE`/`TRUE` and ordering across mismatched types is `#VALUE!`.

  Computed results are written back as `"v"` with `"t"` set to `"n"`, `"s"`,
  `"b"`, `"e"`, `"date"` or `"datetime"`.

  ## Complexity

  One topological pass (Kahn) over the formula-dependency graph — O(cells +
  edges), no per-cell rescans. Range dependencies intersect the formula set
  instead of expanding the rectangle; range evaluation iterates
  min(rectangle, occupied cells).

  ## Examples

      iex> content = %{"tabs" => [%{"cells" => %{
      ...>   "A1" => %{"v" => 2}, "A2" => %{"v" => 3},
      ...>   "A3" => %{"f" => "SUM(A1:A2)"}}}]}
      iex> Barkpark.Plugins.Sheets.Engine.recompute(content)
      ...> |> get_in(["tabs", Access.at(0), "cells", "A3"])
      %{"f" => "SUM(A1:A2)", "t" => "n", "v" => 5}

      iex> content = %{"tabs" => [%{"cells" => %{"A1" => %{"f" => "=A1+1", "v" => 0}}}]}
      iex> Barkpark.Plugins.Sheets.Engine.recompute(content)
      ...> |> get_in(["tabs", Access.at(0), "cells", "A1", "v"])
      "#CYCLE!"

  `SPARKLINE(range)` scales a numeric series onto the 8-level block-bar ramp
  `▁▂▃▄▅▆▇█` — a plain display string that every surface renders for free. Text
  and blank cells are skipped like the aggregates; an error in the range
  propagates; an all-equal series is a flat mid-bar row; an empty range is `""`.

      iex> content = %{"tabs" => [%{"cells" => %{
      ...>   "A1" => %{"v" => 1}, "A2" => %{"v" => 5}, "A3" => %{"v" => 9},
      ...>   "A4" => %{"f" => "=SPARKLINE(A1:A3)"}}}]}
      iex> Barkpark.Plugins.Sheets.Engine.recompute(content)
      ...> |> get_in(["tabs", Access.at(0), "cells", "A4"])
      %{"f" => "=SPARKLINE(A1:A3)", "t" => "s", "v" => "▁▅█"}

      iex> content = %{"tabs" => [%{"cells" => %{
      ...>   "A1" => %{"v" => 1}, "A3" => %{"v" => 9},
      ...>   "B1" => %{"f" => "=SPARKLINE(A1:A3)"}}}]}
      iex> Barkpark.Plugins.Sheets.Engine.recompute(content)
      ...> |> get_in(["tabs", Access.at(0), "cells", "B1", "v"])
      "▁█"

      iex> content = %{"tabs" => [%{"cells" => %{
      ...>   "A1" => %{"f" => "=1/0"}, "A2" => %{"v" => 5},
      ...>   "B1" => %{"f" => "=SPARKLINE(A1:A2)"}}}]}
      iex> Barkpark.Plugins.Sheets.Engine.recompute(content)
      ...> |> get_in(["tabs", Access.at(0), "cells", "B1"])
      %{"f" => "=SPARKLINE(A1:A2)", "t" => "e", "v" => "#DIV/0!"}

      iex> content = %{"tabs" => [%{"cells" => %{
      ...>   "A1" => %{"v" => 3}, "A2" => %{"v" => 3},
      ...>   "B1" => %{"f" => "=SPARKLINE(A1:A2)"}}}]}
      iex> Barkpark.Plugins.Sheets.Engine.recompute(content)
      ...> |> get_in(["tabs", Access.at(0), "cells", "B1", "v"])
      "▄▄"

      iex> content = %{"tabs" => [%{"cells" => %{
      ...>   "A1" => %{"f" => "=SPARKLINE(B1:B2)"}}}]}
      iex> Barkpark.Plugins.Sheets.Engine.recompute(content)
      ...> |> get_in(["tabs", Access.at(0), "cells", "A1", "v"])
      ""
  """

  alias Barkpark.Plugins.Sheets.Core, as: Sheets

  # Excel grid bounds: column XFD, row 1_048_576.
  @max_col 16_384
  @max_row 1_048_576

  # Guard on pure array generation (SEQUENCE): a rows*cols request beyond this
  # is #NUM!, so a fat-fingered SEQUENCE(1000000) can't materialise a runaway
  # intermediate list.
  @array_cap 100_000

  @functions ~w(SUM AVG AVERAGE MIN MAX COUNT COUNTA IF ROUND ABS
                AND OR NOT IFERROR ROUNDUP ROUNDDOWN INT
                LEN TRIM UPPER LOWER LEFT RIGHT MID CONCATENATE TEXTJOIN
                EXACT FIND SEARCH SUBSTITUTE REPLACE REPT PROPER VALUE
                ISBLANK ISNUMBER ISTEXT ISLOGICAL ISERROR ISERR ISNA
                CHOOSE SWITCH IFS
                DATE YEAR MONTH DAY TODAY NOW
                NA COUNTIF SUMIF AVERAGEIF
                VLOOKUP MATCH INDEX
                COUNTIFS SUMIFS AVERAGEIFS
                MEDIAN SMALL LARGE PERCENTILE QUARTILE
                MODE RANK VAR STDEV VARP STDEVP SPARKLINE
                UNIQUE SORT FILTER SEQUENCE COUNTUNIQUE)
  @aggregates ~w(SUM AVG AVERAGE MIN MAX COUNT COUNTA)
  @cmp_ops [:eq, :ne, :lt, :le, :gt, :ge]
  @error_values ~w(#CYCLE! #REF! #VALUE! #DIV/0! #N/A #NUM!)

  # 2^1024 — the first magnitude past the float64 range (max double < 2^1024).
  # An integer this big or bigger cannot survive `/`/`*` coercion to float
  # without raising ArithmeticError, so it is canonicalised to #NUM! at the
  # output boundary (a domain/range overflow, matching the 2^1024 power case).
  @float_overflow_int Integer.pow(2, 1024)

  # SPARKLINE's 8-level block-bar ramp (▁▂▃▄▅▆▇█). A flat / all-equal series
  # renders at the mid bar (@sparkline_mid, index 3 = ▄).
  @sparkline_ramp ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  @sparkline_mid Enum.at(@sparkline_ramp, 3)

  @doc """
  The sorted list of every function name the parser recognises (the formula
  whitelist). Surfaces — autocomplete, capabilities — read this instead of
  duplicating the list. No dedup: aliases like `AVG`/`AVERAGE` both appear.
  """
  @spec function_names() :: [String.t()]
  def function_names, do: Enum.sort(@functions)

  @doc """
  The engine's error vocabulary — every `"#…!"` string a computed cell can
  hold. Surfaces that mark error cells (Studio's `sheet-err` class, the web
  grid, PortableDoc's html render) read THIS single list instead of hand-
  copying it, so a new code (e.g. `#NUM!`) lights up every surface at once.
  """
  # @canonical capability:engine-error-vocabulary aka:error-codes,#NUM!,#DIV/0!,sheet-err,error_values
  @spec error_values() :: [String.t()]
  def error_values, do: @error_values

  @doc """
  Recompute every formula cell's `"v"` across all tabs of a sheet document's
  content map. Total: malformed/missing tabs or cells pass through untouched,
  non-formula cells are never modified, and content without a `"tabs"` list
  is returned as-is.
  """
  @spec recompute(term()) :: term()
  def recompute(%{"tabs" => tabs} = content) when is_list(tabs) do
    Map.put(content, "tabs", Enum.map(tabs, &recompute_tab/1))
  end

  def recompute(content), do: content

  defp recompute_tab(%{"cells" => cells} = tab) when is_map(cells) and map_size(cells) > 0 do
    Map.put(tab, "cells", recompute_cells(cells))
  end

  defp recompute_tab(tab), do: tab

  # ── recompute pipeline ──────────────────────────────────────────────────────

  defp recompute_cells(cells) do
    entries =
      for {addr, cell} <- cells, is_map(cell), reduce: [] do
        acc ->
          case Sheets.parse_ref(addr) do
            {:ok, pos} -> [{addr, pos, cell} | acc]
            :error -> acc
          end
      end

    occupied = MapSet.new(entries, fn {_addr, pos, _cell} -> pos end)
    values = Map.new(entries, fn {_addr, pos, cell} -> {pos, literal_value(cell)} end)

    parsed =
      for {addr, pos, %{"f" => f}} <- entries, is_binary(f), into: %{} do
        {pos, {addr, parse_formula(f)}}
      end

    if parsed == %{} do
      cells
    else
      node_asts =
        for {pos, {_addr, {:ok, ast, points, ranges}}} <- parsed, into: %{} do
          {pos, {ast, points, ranges}}
        end

      node_set = node_asts |> Map.keys() |> MapSet.new()
      {in_deg, out_edges} = build_graph(node_asts, node_set)

      computed0 =
        for {pos, {_addr, :invalid}} <- parsed, into: %{}, do: {pos, err(:ref)}

      base = %{values: values, occupied: occupied}
      queue = for {pos, 0} <- in_deg, do: pos
      {computed, in_deg} = topo(queue, computed0, in_deg, out_edges, node_asts, base)

      # Kahn leftovers sit on a cycle or depend on one — both get #CYCLE!.
      computed =
        Enum.reduce(in_deg, computed, fn
          {pos, d}, acc when d > 0 -> Map.put(acc, pos, err(:cycle))
          _other, acc -> acc
        end)

      write_back(cells, parsed, computed)
    end
  end

  defp build_graph(node_asts, node_set) do
    Enum.reduce(node_asts, {%{}, %{}}, fn {pos, {_ast, points, ranges}}, {in_deg, out} ->
      deps =
        points
        |> Enum.filter(&MapSet.member?(node_set, &1))
        |> Kernel.++(range_node_deps(ranges, node_set))
        |> Enum.uniq()

      in_deg = Map.put(in_deg, pos, length(deps))
      out = Enum.reduce(deps, out, fn dep, o -> Map.update(o, dep, [pos], &[pos | &1]) end)
      {in_deg, out}
    end)
  end

  # Range deps intersect the FORMULA set (bounded by formula count), never
  # the rectangle — a SUM over a million-cell range stays cheap.
  defp range_node_deps(ranges, node_set) do
    Enum.flat_map(ranges, fn {{c1, r1}, {c2, r2}} ->
      Enum.filter(node_set, fn {c, r} -> c >= c1 and c <= c2 and r >= r1 and r <= r2 end)
    end)
  end

  defp topo([], computed, in_deg, _out, _node_asts, _base), do: {computed, in_deg}

  defp topo([pos | rest], computed, in_deg, out, node_asts, base) do
    {ast, _points, _ranges} = Map.fetch!(node_asts, pos)
    ctx = %{computed: computed, values: base.values, occupied: base.occupied}
    computed = Map.put(computed, pos, eval(ast, ctx))

    {ready, in_deg} =
      out
      |> Map.get(pos, [])
      |> Enum.reduce({[], in_deg}, fn dep, {ready, ind} ->
        ind = Map.update!(ind, dep, &(&1 - 1))
        if ind[dep] == 0, do: {[dep | ready], ind}, else: {ready, ind}
      end)

    topo(ready ++ rest, computed, in_deg, out, node_asts, base)
  end

  defp write_back(cells, parsed, computed) do
    Enum.reduce(parsed, cells, fn {pos, {addr, result}}, acc ->
      case result do
        :stale ->
          Map.update!(acc, addr, &Map.put(&1, "stale", true))

        _decisive ->
          Map.update!(acc, addr, &write_value(&1, Map.fetch!(computed, pos)))
      end
    end)
  end

  defp write_value(cell, value) do
    {v, t} = output(value)

    cell
    |> Map.put("v", v)
    |> Map.put("t", t)
    |> Map.delete("stale")
  end

  # A top-level array result implicitly intersects to its top-left element.
  defp output({:array, rows}), do: output(array_top_left(rows))
  defp output({:error, code}), do: {code, "e"}
  defp output(%Date{} = d), do: {Date.to_iso8601(d), "date"}
  defp output(%DateTime{} = dt), do: {DateTime.to_iso8601(dt), "datetime"}
  defp output(%NaiveDateTime{} = ndt), do: {NaiveDateTime.to_iso8601(ndt), "datetime"}
  # An integer past the float64 range would raise the moment any downstream
  # `/`/`*` coerces it to float — canonicalise it to #NUM! at the boundary so a
  # stored/derived bignum can never crash a later recompute or a display path.
  defp output(v) when is_integer(v) and abs(v) >= @float_overflow_int, do: output({:error, "#NUM!"})
  defp output(n) when is_number(n), do: {n, "n"}
  defp output(b) when is_boolean(b), do: {b, "b"}
  defp output(s) when is_binary(s), do: {s, "s"}
  defp output(:blank), do: {0, "n"}

  # ── literal cell values ─────────────────────────────────────────────────────

  defp literal_value(cell) do
    v = Map.get(cell, "v")
    t = Map.get(cell, "t")

    cond do
      is_binary(v) and t in ["date", "datetime"] -> parse_temporal(v) || v
      is_binary(v) and (t == "e" or v in @error_values) -> {:error, v}
      is_number(v) -> v
      is_boolean(v) -> v
      v == "" -> :blank
      is_binary(v) and t in ["n", "number"] -> parse_number(v) || v
      is_binary(v) -> v
      true -> :blank
    end
  end

  defp parse_temporal(s) do
    case Date.from_iso8601(s) do
      {:ok, d} ->
        d

      _ ->
        case DateTime.from_iso8601(s) do
          {:ok, dt, _offset} ->
            dt

          _ ->
            case NaiveDateTime.from_iso8601(s) do
              {:ok, ndt} -> ndt
              _ -> nil
            end
        end
    end
  end

  defp parse_number(s) do
    case Integer.parse(s) do
      {n, ""} ->
        n

      _ ->
        # Float.parse RAISES ArgumentError on a mantissa that overflows float64
        # (e.g. a literal of 400+ nines) — degrade to nil so callers fall back.
        try do
          case Float.parse(s) do
            {f, ""} -> f
            _ -> nil
          end
        rescue
          ArgumentError -> nil
        end
    end
  end

  # ── parsing ─────────────────────────────────────────────────────────────────
  #
  # parse_formula/1 → {:ok, ast, points, ranges} | :stale | :invalid

  defp parse_formula(f) do
    src =
      case String.trim(f) do
        "=" <> rest -> rest
        other -> other
      end

    with {:ok, tokens} <- tokenize(src, []),
         {:ok, ast} <- parse(tokens) do
      {points, ranges, fns} = walk(ast, {[], [], []})

      if Enum.all?(fns, &(&1 in @functions)) do
        {:ok, ast, points, ranges}
      else
        :stale
      end
    else
      _ -> :invalid
    end
  end

  defp walk({:ref, pos}, {ps, rs, fs}), do: {[pos | ps], rs, fs}
  defp walk({:range, p1, p2}, {ps, rs, fs}), do: {ps, [{p1, p2} | rs], fs}
  defp walk({:neg, x}, acc), do: walk(x, acc)
  defp walk({:binop, _op, l, r}, acc), do: walk(r, walk(l, acc))

  defp walk({:call, name, args}, {ps, rs, fs}) do
    Enum.reduce(args, {ps, rs, [name | fs]}, &walk/2)
  end

  defp walk(_literal, acc), do: acc

  # ── tokenizer ───────────────────────────────────────────────────────────────

  defp tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\r, ?\n],
    do: tokenize(rest, acc)

  defp tokenize(<<">=", rest::binary>>, acc), do: tokenize(rest, [{:op, :ge} | acc])
  defp tokenize(<<"<=", rest::binary>>, acc), do: tokenize(rest, [{:op, :le} | acc])
  defp tokenize(<<"<>", rest::binary>>, acc), do: tokenize(rest, [{:op, :ne} | acc])
  defp tokenize(<<"=", rest::binary>>, acc), do: tokenize(rest, [{:op, :eq} | acc])
  defp tokenize(<<"<", rest::binary>>, acc), do: tokenize(rest, [{:op, :lt} | acc])
  defp tokenize(<<">", rest::binary>>, acc), do: tokenize(rest, [{:op, :gt} | acc])
  defp tokenize(<<"+", rest::binary>>, acc), do: tokenize(rest, [{:op, :add} | acc])
  defp tokenize(<<"-", rest::binary>>, acc), do: tokenize(rest, [{:op, :sub} | acc])
  defp tokenize(<<"*", rest::binary>>, acc), do: tokenize(rest, [{:op, :mul} | acc])
  defp tokenize(<<"/", rest::binary>>, acc), do: tokenize(rest, [{:op, :div} | acc])
  defp tokenize(<<"^", rest::binary>>, acc), do: tokenize(rest, [{:op, :pow} | acc])
  defp tokenize(<<"&", rest::binary>>, acc), do: tokenize(rest, [{:op, :concat} | acc])
  defp tokenize(<<"(", rest::binary>>, acc), do: tokenize(rest, [:lparen | acc])
  defp tokenize(<<")", rest::binary>>, acc), do: tokenize(rest, [:rparen | acc])
  defp tokenize(<<",", rest::binary>>, acc), do: tokenize(rest, [:comma | acc])
  defp tokenize(<<":", rest::binary>>, acc), do: tokenize(rest, [:colon | acc])

  defp tokenize(<<?", rest::binary>>, acc) do
    case lex_string(rest, "") do
      {:ok, token, rest2} -> tokenize(rest2, [token | acc])
      :error -> :error
    end
  end

  defp tokenize(<<c, _::binary>> = bin, acc) when c in ?0..?9 do
    case lex_number(bin) do
      {:ok, token, rest} -> tokenize(rest, [token | acc])
      :error -> :error
    end
  end

  defp tokenize(<<?., c, _::binary>> = bin, acc) when c in ?0..?9 do
    case lex_number(bin) do
      {:ok, token, rest} -> tokenize(rest, [token | acc])
      :error -> :error
    end
  end

  defp tokenize(<<c, _::binary>> = bin, acc)
       when c in ?a..?z or c in ?A..?Z or c == ?_ or c == ?$ do
    case lex_word(bin) do
      {:ok, token, rest} -> tokenize(rest, [token | acc])
      :error -> :error
    end
  end

  defp tokenize(_bin, _acc), do: :error

  defp lex_string(<<?", ?", rest::binary>>, acc), do: lex_string(rest, acc <> "\"")
  defp lex_string(<<?", rest::binary>>, acc), do: {:ok, {:str, acc}, rest}
  defp lex_string(<<c::utf8, rest::binary>>, acc), do: lex_string(rest, acc <> <<c::utf8>>)
  defp lex_string(<<>>, _acc), do: :error

  defp lex_number(bin) do
    {int, rest} = take_digits(bin, "")

    case rest do
      <<?., rest2::binary>> ->
        case take_digits(rest2, "") do
          {"", _} ->
            :error

          {frac, rest3} ->
            try do
              {:ok, {:num, String.to_float(zero_pad(int) <> "." <> frac)}, rest3}
            rescue
              # A literal that overflows float range raises; fail closed so the
              # cell degrades to #REF! instead of crashing recompute.
              ArgumentError -> :error
            end
        end

      _ when int != "" ->
        {:ok, {:num, String.to_integer(int)}, rest}

      _ ->
        :error
    end
  end

  defp zero_pad(""), do: "0"
  defp zero_pad(digits), do: digits

  defp take_digits(<<c, rest::binary>>, acc) when c in ?0..?9,
    do: take_digits(rest, <<acc::binary, c>>)

  defp take_digits(bin, acc), do: {acc, bin}

  defp lex_word(bin) do
    {word, rest} = take_word(bin, "")
    classify_word(word, rest)
  end

  defp take_word(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ or c == ?$,
       do: take_word(rest, <<acc::binary, c>>)

  defp take_word(bin, acc), do: {acc, bin}

  # A word followed by `(` is a function name even when it also looks like a
  # ref (`LOG10(`); otherwise ref-shaped words are refs and TRUE/FALSE are
  # boolean literals. Anything else fails the grammar.
  defp classify_word(word, rest) do
    up = String.upcase(word)

    cond do
      function_name?(word) and next_is_lparen?(rest) -> {:ok, {:ident, up}, rest}
      ref_like?(word) -> ref_token(word, rest)
      up in ["TRUE", "FALSE"] -> {:ok, {:bool, up == "TRUE"}, rest}
      function_name?(word) -> {:ok, {:ident, up}, rest}
      true -> :error
    end
  end

  defp function_name?(word), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, word)
  defp ref_like?(word), do: Regex.match?(~r/^\$?[A-Za-z]+\$?[0-9]+$/, word)

  defp next_is_lparen?(<<?\s, rest::binary>>), do: next_is_lparen?(rest)
  defp next_is_lparen?(<<?(, _::binary>>), do: true
  defp next_is_lparen?(_), do: false

  defp ref_token(word, rest) do
    case Sheets.parse_ref(String.replace(word, "$", "")) do
      {:ok, {col, row}} when col <= @max_col and row <= @max_row ->
        {:ok, {:ref, {col, row}}, rest}

      _ ->
        :error
    end
  end

  # ── parser (precedence climbing) ────────────────────────────────────────────
  #
  # cmp > concat > add/sub > mul/div > pow > unary > primary, Excel-style:
  # unary minus binds tighter than ^, ^ is left-associative.

  defp parse(tokens) do
    case parse_cmp(tokens) do
      {:ok, ast, []} -> {:ok, ast}
      _ -> :error
    end
  end

  defp parse_cmp(tokens) do
    case parse_concat(tokens) do
      {:ok, left, rest} -> cmp_tail(left, rest)
      :error -> :error
    end
  end

  defp cmp_tail(left, [{:op, op} | rest]) when op in @cmp_ops do
    case parse_concat(rest) do
      {:ok, right, rest2} -> cmp_tail({:binop, op, left, right}, rest2)
      :error -> :error
    end
  end

  defp cmp_tail(left, rest), do: {:ok, left, rest}

  defp parse_concat(tokens) do
    case parse_add(tokens) do
      {:ok, left, rest} -> concat_tail(left, rest)
      :error -> :error
    end
  end

  defp concat_tail(left, [{:op, :concat} | rest]) do
    case parse_add(rest) do
      {:ok, right, rest2} -> concat_tail({:binop, :concat, left, right}, rest2)
      :error -> :error
    end
  end

  defp concat_tail(left, rest), do: {:ok, left, rest}

  defp parse_add(tokens) do
    case parse_mul(tokens) do
      {:ok, left, rest} -> add_tail(left, rest)
      :error -> :error
    end
  end

  defp add_tail(left, [{:op, op} | rest]) when op in [:add, :sub] do
    case parse_mul(rest) do
      {:ok, right, rest2} -> add_tail({:binop, op, left, right}, rest2)
      :error -> :error
    end
  end

  defp add_tail(left, rest), do: {:ok, left, rest}

  defp parse_mul(tokens) do
    case parse_pow(tokens) do
      {:ok, left, rest} -> mul_tail(left, rest)
      :error -> :error
    end
  end

  defp mul_tail(left, [{:op, op} | rest]) when op in [:mul, :div] do
    case parse_pow(rest) do
      {:ok, right, rest2} -> mul_tail({:binop, op, left, right}, rest2)
      :error -> :error
    end
  end

  defp mul_tail(left, rest), do: {:ok, left, rest}

  defp parse_pow(tokens) do
    case parse_unary(tokens) do
      {:ok, left, rest} -> pow_tail(left, rest)
      :error -> :error
    end
  end

  defp pow_tail(left, [{:op, :pow} | rest]) do
    case parse_unary(rest) do
      {:ok, right, rest2} -> pow_tail({:binop, :pow, left, right}, rest2)
      :error -> :error
    end
  end

  defp pow_tail(left, rest), do: {:ok, left, rest}

  defp parse_unary([{:op, :sub} | rest]) do
    case parse_unary(rest) do
      {:ok, x, rest2} -> {:ok, {:neg, x}, rest2}
      :error -> :error
    end
  end

  defp parse_unary([{:op, :add} | rest]), do: parse_unary(rest)
  defp parse_unary(tokens), do: parse_primary(tokens)

  defp parse_primary([{:num, n} | rest]), do: {:ok, {:num, n}, rest}
  defp parse_primary([{:str, s} | rest]), do: {:ok, {:str, s}, rest}
  defp parse_primary([{:bool, b} | rest]), do: {:ok, {:bool, b}, rest}

  defp parse_primary([{:ref, {c1, r1}}, :colon, {:ref, {c2, r2}} | rest]) do
    {:ok, {:range, {min(c1, c2), min(r1, r2)}, {max(c1, c2), max(r1, r2)}}, rest}
  end

  defp parse_primary([{:ref, pos} | rest]), do: {:ok, {:ref, pos}, rest}
  defp parse_primary([{:ident, name}, :lparen | rest]), do: parse_call(name, rest)

  defp parse_primary([:lparen | rest]) do
    case parse_cmp(rest) do
      {:ok, x, [:rparen | rest2]} -> {:ok, x, rest2}
      _ -> :error
    end
  end

  defp parse_primary(_tokens), do: :error

  defp parse_call(name, [:rparen | rest]), do: {:ok, {:call, name, []}, rest}

  defp parse_call(name, tokens) do
    case parse_args(tokens, []) do
      {:ok, args, rest} -> {:ok, {:call, name, args}, rest}
      :error -> :error
    end
  end

  defp parse_args(tokens, acc) do
    case parse_cmp(tokens) do
      {:ok, arg, [:comma | rest]} -> parse_args(rest, [arg | acc])
      {:ok, arg, [:rparen | rest]} -> {:ok, Enum.reverse([arg | acc]), rest}
      _ -> :error
    end
  end

  # ── evaluation ──────────────────────────────────────────────────────────────

  defp eval({:num, n}, _ctx), do: n
  defp eval({:str, s}, _ctx), do: s
  defp eval({:bool, b}, _ctx), do: b
  defp eval({:ref, pos}, ctx), do: cell_at(pos, ctx)
  # A range is not a scalar; only aggregate arguments flatten ranges.
  defp eval({:range, _p1, _p2}, _ctx), do: err(:value)

  defp eval({:neg, x}, ctx) do
    case eval_number(x, ctx) do
      {:error, _} = e -> e
      n -> -n
    end
  end

  defp eval({:binop, op, l, r}, ctx) do
    # An array operand implicitly intersects to its top-left before the op.
    case scalarize(eval(l, ctx)) do
      {:error, _} = e ->
        e

      lv ->
        case scalarize(eval(r, ctx)) do
          {:error, _} = e -> e
          rv -> apply_op(op, lv, rv)
        end
    end
  end

  defp eval({:call, name, args}, ctx), do: call(name, args, ctx)

  defp cell_at(pos, ctx) do
    case Map.fetch(ctx.computed, pos) do
      {:ok, v} -> v
      :error -> Map.get(ctx.values, pos, :blank)
    end
  end

  defp eval_number(ast, ctx) do
    case scalarize(eval(ast, ctx)) do
      {:error, _} = e -> e
      :blank -> 0
      n when is_number(n) -> n
      _ -> err(:value)
    end
  end

  # ── operators ───────────────────────────────────────────────────────────────

  defp apply_op(op, a, b) when op in [:add, :sub, :mul, :div, :pow], do: arith(op, a, b)
  defp apply_op(:concat, a, b), do: to_text(a) <> to_text(b)
  defp apply_op(op, a, b) when op in @cmp_ops, do: compare(op, a, b)

  defp arith(:add, a, b) do
    cond do
      temporal?(a) and number_like?(b) -> advance(a, num(b))
      number_like?(a) and temporal?(b) -> advance(b, num(a))
      number_like?(a) and number_like?(b) -> safe_arith(fn -> num(a) + num(b) end)
      true -> err(:value)
    end
  end

  defp arith(:sub, a, b) do
    cond do
      temporal?(a) and temporal?(b) -> day_diff(a, b)
      temporal?(a) and number_like?(b) -> advance(a, -num(b))
      number_like?(a) and number_like?(b) -> safe_arith(fn -> num(a) - num(b) end)
      true -> err(:value)
    end
  end

  defp arith(:mul, a, b) do
    if number_like?(a) and number_like?(b),
      do: safe_arith(fn -> num(a) * num(b) end),
      else: err(:value)
  end

  defp arith(:div, a, b) do
    cond do
      not (number_like?(a) and number_like?(b)) -> err(:value)
      num(b) == 0 -> err(:div0)
      true -> divide(num(a), num(b))
    end
  end

  defp arith(:pow, a, b) do
    if number_like?(a) and number_like?(b), do: power(num(a), num(b)), else: err(:value)
  end

  defp divide(a, b) when is_integer(a) and is_integer(b) do
    # An exact quotient stays an integer; otherwise float-divide — but a bignum
    # numerator (e.g. an odd-sum MEDIAN pair, 2^1023 + (2^1023 + 1)) overflows
    # the double range in that coercion and raises, so it goes through
    # safe_arith too (a range overflow is #NUM!, not a crash).
    if rem(a, b) == 0, do: div(a, b), else: safe_arith(fn -> a / b end)
  end

  # Float division of a huge (e.g. imported) bignum can overflow the double
  # range and raise ArithmeticError; keep recompute total — a range overflow
  # is #NUM!, not a crash. (The power/2 guard above stops formulas producing
  # such a bignum; this backstops an imported one.)
  defp divide(a, b), do: safe_arith(fn -> a / b end)

  # Integer.pow only when the RESULT provably fits the float64 range — a
  # bounded exponent alone is not enough: `99^200` (exponent 200) still
  # materialises a ~400-digit bignum that then blows up float division
  # (`99^200/7` raised ArithmeticError in an UNWRAPPED divide, crashing the
  # per-sheet Session for every collaborator). Excel tops out at ~1.8e308, so
  # anything larger is #NUM!. `b * log2(|a|) < 1024` is the cheap fits-in-a-
  # double test; it can't live in a guard (log2 isn't guard-safe), so the
  # magnitude route is a cond in the body.
  defp power(a, b) when is_integer(a) and is_integer(b) and b >= 0 do
    cond do
      a in [-1, 0, 1] -> Integer.pow(a, b)
      b <= 1024 and b * :math.log2(abs(a)) < 1024 -> Integer.pow(a, b)
      true -> power_float(a, b)
    end
  end

  defp power(a, b), do: power_float(a, b)

  defp power_float(a, b) do
    if a == 0 and b < 0 do
      err(:div0)
    else
      try do
        :math.pow(a, b)
      rescue
        # A numeric domain error (e.g. `(-8)^0.5`) or a result that overflows
        # the double range is #NUM!, not #VALUE! — the argument outran the
        # function's domain, it wasn't the wrong TYPE.
        ArithmeticError -> err(:num)
      end
    end
  end

  defp number_like?(v), do: is_number(v) or v == :blank

  # Float +/-/* can overflow the double range (e.g. 1.0e308 * 1.0e308) and raise
  # ArithmeticError; keep recompute total by turning that into a #NUM! cell (a
  # domain/range overflow, not a type error).
  defp safe_arith(fun) do
    try do
      fun.()
    rescue
      ArithmeticError -> err(:num)
    end
  end

  defp num(v) when is_number(v), do: v
  defp num(:blank), do: 0

  defp temporal?(%Date{}), do: true
  defp temporal?(%DateTime{}), do: true
  defp temporal?(%NaiveDateTime{}), do: true
  defp temporal?(_), do: false

  # Date/time arithmetic tops out at the Excel year-9999 range; a huge offset
  # (e.g. `A1 + 10^15` on a date cell) made Date.add churn for MINUTES,
  # freezing the Session for every collaborator with nothing to rescue it.
  # Reject an out-of-range day offset up front as #NUM!. 3_000_000 days is
  # ~8200 years — comfortably past any real sheet date, well short of a hang.
  @max_date_days 3_000_000
  defp advance(_t, n) when is_number(n) and abs(n) > @max_date_days, do: err(:num)
  defp advance(%Date{} = d, n), do: Date.add(d, trunc(n))
  defp advance(%DateTime{} = dt, n), do: DateTime.add(dt, round(n * 86_400), :second)
  defp advance(%NaiveDateTime{} = ndt, n), do: NaiveDateTime.add(ndt, round(n * 86_400), :second)

  defp day_diff(%Date{} = a, %Date{} = b), do: Date.diff(a, b)
  defp day_diff(%DateTime{} = a, %DateTime{} = b), do: seconds_to_days(DateTime.diff(a, b))

  defp day_diff(%NaiveDateTime{} = a, %NaiveDateTime{} = b),
    do: seconds_to_days(NaiveDateTime.diff(a, b))

  defp day_diff(_a, _b), do: err(:value)

  defp seconds_to_days(s) when rem(s, 86_400) == 0, do: div(s, 86_400)
  defp seconds_to_days(s), do: s / 86_400

  defp to_text(:blank), do: ""
  defp to_text(s) when is_binary(s), do: s
  defp to_text(n) when is_integer(n), do: Integer.to_string(n)
  defp to_text(f) when is_float(f), do: Float.to_string(f)
  defp to_text(true), do: "TRUE"
  defp to_text(false), do: "FALSE"
  defp to_text(%Date{} = d), do: Date.to_iso8601(d)
  defp to_text(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_text(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)

  defp compare(op, a, b) do
    case order(a, b) do
      :mismatch ->
        case op do
          :eq -> false
          :ne -> true
          _ -> err(:value)
        end

      ord ->
        case op do
          :eq -> ord == :eq
          :ne -> ord != :eq
          :lt -> ord == :lt
          :le -> ord != :gt
          :gt -> ord == :gt
          :ge -> ord != :lt
        end
    end
  end

  defp order(a, b) do
    a2 = unblank_against(a, b)
    b2 = unblank_against(b, a)

    cond do
      is_number(a2) and is_number(b2) ->
        scalar_order(a2, b2)

      is_binary(a2) and is_binary(b2) ->
        scalar_order(String.downcase(a2), String.downcase(b2))

      is_boolean(a2) and is_boolean(b2) ->
        scalar_order(bool_rank(a2), bool_rank(b2))

      match?(%Date{}, a2) and match?(%Date{}, b2) ->
        Date.compare(a2, b2)

      match?(%DateTime{}, a2) and match?(%DateTime{}, b2) ->
        DateTime.compare(a2, b2)

      match?(%NaiveDateTime{}, a2) and match?(%NaiveDateTime{}, b2) ->
        NaiveDateTime.compare(a2, b2)

      a2 == :blank and b2 == :blank ->
        :eq

      true ->
        :mismatch
    end
  end

  defp unblank_against(:blank, other) when is_number(other), do: 0
  defp unblank_against(:blank, other) when is_binary(other), do: ""
  defp unblank_against(:blank, other) when is_boolean(other), do: false
  defp unblank_against(v, _other), do: v

  defp scalar_order(a, b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  defp bool_rank(false), do: 0
  defp bool_rank(true), do: 1

  # ── functions ───────────────────────────────────────────────────────────────

  defp call("IF", [cond_ast | branches], ctx) when length(branches) in [1, 2] do
    case eval(cond_ast, ctx) do
      {:error, _} = e ->
        e

      v ->
        case truthy(v) do
          :error ->
            err(:value)

          {:ok, true} ->
            eval(hd(branches), ctx)

          {:ok, false} ->
            case branches do
              [_then, else_ast] -> eval(else_ast, ctx)
              [_then] -> false
            end
        end
    end
  end

  defp call("ROUND", [x], ctx), do: call("ROUND", [x, {:num, 0}], ctx)

  defp call("ROUND", [x, d], ctx) do
    case {eval_number(x, ctx), eval_number(d, ctx)} do
      {{:error, _} = e, _} -> e
      {_, {:error, _} = e} -> e
      {n, digits} -> fn_round(n, trunc(digits))
    end
  end

  defp call("ABS", [x], ctx) do
    case eval_number(x, ctx) do
      {:error, _} = e -> e
      n -> abs(n)
    end
  end

  # ── logic ─────────────────────────────────────────────────────────────

  defp call(name, args, ctx) when name in ["AND", "OR"] and args != [] do
    case collect_bools(args, ctx, []) do
      {:error, _} = e -> e
      [] -> err(:value)
      bools -> if name == "AND", do: Enum.all?(bools), else: Enum.any?(bools)
    end
  end

  defp call("NOT", [x], ctx) do
    case eval(x, ctx) do
      {:error, _} = e ->
        e

      v ->
        case truthy(v) do
          {:ok, b} -> not b
          :error -> err(:value)
        end
    end
  end

  defp call("IFERROR", [x, fallback], ctx) do
    case eval(x, ctx) do
      {:error, _} -> eval(fallback, ctx)
      v -> v
    end
  end

  # ── math ──────────────────────────────────────────────────────────────

  defp call("ROUNDUP", [x], ctx), do: call("ROUNDUP", [x, {:num, 0}], ctx)

  defp call("ROUNDUP", [x, d], ctx) do
    case {eval_number(x, ctx), eval_number(d, ctx)} do
      {{:error, _} = e, _} -> e
      {_, {:error, _} = e} -> e
      {n, digits} -> fn_roundup(n, trunc(digits))
    end
  end

  defp call("ROUNDDOWN", [x], ctx), do: call("ROUNDDOWN", [x, {:num, 0}], ctx)

  defp call("ROUNDDOWN", [x, d], ctx) do
    case {eval_number(x, ctx), eval_number(d, ctx)} do
      {{:error, _} = e, _} -> e
      {_, {:error, _} = e} -> e
      {n, digits} -> fn_rounddown(n, trunc(digits))
    end
  end

  defp call("INT", [x], ctx) do
    case eval_number(x, ctx) do
      {:error, _} = e -> e
      n -> trunc(:math.floor(n))
    end
  end

  # ── text ──────────────────────────────────────────────────────────────

  defp call("LEN", [s], ctx) do
    case eval_text(s, ctx) do
      {:error, _} = e -> e
      txt -> String.length(txt)
    end
  end

  defp call("TRIM", [s], ctx) do
    case eval_text(s, ctx) do
      {:error, _} = e -> e
      txt -> txt |> String.trim() |> String.replace(~r/ +/, " ")
    end
  end

  defp call("UPPER", [s], ctx) do
    case eval_text(s, ctx) do
      {:error, _} = e -> e
      txt -> String.upcase(txt)
    end
  end

  defp call("LOWER", [s], ctx) do
    case eval_text(s, ctx) do
      {:error, _} = e -> e
      txt -> String.downcase(txt)
    end
  end

  defp call("LEFT", [s], ctx), do: call("LEFT", [s, {:num, 1}], ctx)

  defp call("LEFT", [s, n], ctx) do
    with txt when is_binary(txt) <- eval_text(s, ctx),
         cnt when is_number(cnt) <- eval_number(n, ctx) do
      cnt = trunc(cnt)
      if cnt < 0, do: err(:value), else: String.slice(txt, 0, cnt)
    else
      {:error, _} = e -> e
    end
  end

  defp call("RIGHT", [s], ctx), do: call("RIGHT", [s, {:num, 1}], ctx)

  defp call("RIGHT", [s, n], ctx) do
    with txt when is_binary(txt) <- eval_text(s, ctx),
         cnt when is_number(cnt) <- eval_number(n, ctx) do
      cnt = trunc(cnt)

      if cnt < 0 do
        err(:value)
      else
        len = String.length(txt)
        String.slice(txt, max(len - cnt, 0), cnt)
      end
    else
      {:error, _} = e -> e
    end
  end

  defp call("MID", [s, start, len], ctx) do
    with txt when is_binary(txt) <- eval_text(s, ctx),
         st when is_number(st) <- eval_number(start, ctx),
         ln when is_number(ln) <- eval_number(len, ctx) do
      st = trunc(st)
      ln = trunc(ln)
      if st < 1 or ln < 0, do: err(:value), else: String.slice(txt, st - 1, ln) || ""
    else
      {:error, _} = e -> e
    end
  end

  defp call("CONCATENATE", args, ctx) when args != [] do
    Enum.reduce_while(args, "", fn arg, acc ->
      case eval_text(arg, ctx) do
        {:error, _} = e -> {:halt, e}
        txt -> {:cont, acc <> txt}
      end
    end)
  end

  defp call("TEXTJOIN", [delim_ast, ignore_ast | rest], ctx) when rest != [] do
    with delim when is_binary(delim) <- eval_text(delim_ast, ctx),
         {:ok, ignore?} <- textjoin_ignore(ignore_ast, ctx),
         {:ok, parts} <- textjoin_parts(rest, ctx, []) do
      parts = if ignore?, do: Enum.reject(parts, &(&1 == "")), else: parts
      Enum.join(parts, delim)
    else
      {:error, _} = e -> e
    end
  end

  # EXACT is the one case-SENSITIVE text comparison (all other text ops fold case).
  defp call("EXACT", [a, b], ctx) do
    with sa when is_binary(sa) <- eval_text(a, ctx),
         sb when is_binary(sb) <- eval_text(b, ctx) do
      sa == sb
    else
      {:error, _} = e -> e
    end
  end

  defp call("FIND", [needle, hay], ctx), do: call("FIND", [needle, hay, {:num, 1}], ctx)

  # FIND is case-SENSITIVE, no wildcards; the 1-based grapheme position of the
  # first `needle` at or after `start`, else #VALUE!.
  defp call("FIND", [needle_ast, hay_ast, start_ast], ctx) do
    with nd when is_binary(nd) <- eval_text(needle_ast, ctx),
         hy when is_binary(hy) <- eval_text(hay_ast, ctx),
         st when is_number(st) <- eval_number(start_ast, ctx) do
      find_at(nd, hy, trunc(st))
    else
      {:error, _} = e -> e
    end
  end

  defp call("SEARCH", [needle, hay], ctx), do: call("SEARCH", [needle, hay, {:num, 1}], ctx)

  # SEARCH mirrors FIND but is case-INSENSITIVE and honours `*`/`?` wildcards,
  # so `needle` compiles to the UNANCHORED wildcard regex.
  defp call("SEARCH", [needle_ast, hay_ast, start_ast], ctx) do
    with nd when is_binary(nd) <- eval_text(needle_ast, ctx),
         hy when is_binary(hy) <- eval_text(hay_ast, ctx),
         st when is_number(st) <- eval_number(start_ast, ctx) do
      search_at(nd, hy, trunc(st))
    else
      {:error, _} = e -> e
    end
  end

  defp call("SUBSTITUTE", [text, old, new], ctx) do
    with t when is_binary(t) <- eval_text(text, ctx),
         o when is_binary(o) <- eval_text(old, ctx),
         nw when is_binary(nw) <- eval_text(new, ctx) do
      if o == "", do: t, else: String.replace(t, o, nw)
    else
      {:error, _} = e -> e
    end
  end

  # A 4th arg replaces ONLY the nth occurrence (1-based); n < 1 is #VALUE!, and
  # an empty `old` leaves the text unchanged (Excel).
  defp call("SUBSTITUTE", [text, old, new, inst], ctx) do
    with t when is_binary(t) <- eval_text(text, ctx),
         o when is_binary(o) <- eval_text(old, ctx),
         nw when is_binary(nw) <- eval_text(new, ctx),
         i when is_number(i) <- eval_number(inst, ctx) do
      n = trunc(i)

      cond do
        n < 1 -> err(:value)
        o == "" -> t
        true -> substitute_nth(t, o, nw, n)
      end
    else
      {:error, _} = e -> e
    end
  end

  # REPLACE splices `count` graphemes at 1-based `start` with `new`.
  defp call("REPLACE", [old, start, count, new], ctx) do
    with o when is_binary(o) <- eval_text(old, ctx),
         st when is_number(st) <- eval_number(start, ctx),
         cnt when is_number(cnt) <- eval_number(count, ctx),
         nw when is_binary(nw) <- eval_text(new, ctx) do
      s = trunc(st)
      c = trunc(cnt)

      if s < 1 or c < 0 do
        err(:value)
      else
        String.slice(o, 0, s - 1) <> nw <> String.slice(o, s - 1 + c, String.length(o))
      end
    else
      {:error, _} = e -> e
    end
  end

  # REPT caps the result at the Excel cell-text limit (32,767) so a huge count
  # can't materialise a runaway binary and recompute stays total.
  defp call("REPT", [text, n], ctx) do
    with t when is_binary(t) <- eval_text(text, ctx),
         cnt when is_number(cnt) <- eval_number(n, ctx) do
      times = trunc(cnt)

      cond do
        times < 0 -> err(:value)
        String.length(t) * times > 32_767 -> err(:value)
        true -> String.duplicate(t, times)
      end
    else
      {:error, _} = e -> e
    end
  end

  # PROPER capitalises each run of letters (first up, rest down).
  defp call("PROPER", [s], ctx) do
    case eval_text(s, ctx) do
      {:error, _} = e -> e
      txt -> Regex.replace(~r/\p{L}+/u, txt, &String.capitalize/1)
    end
  end

  # VALUE parses numeric text; a trailing `%` scales by 1/100. Unparseable is
  # #VALUE! (never propagates a nil).
  defp call("VALUE", [s], ctx) do
    case eval_text(s, ctx) do
      {:error, _} = e -> e
      txt -> parse_value(String.trim(txt))
    end
  end

  # ── info (IS* predicates) ─────────────────────────────────────────────
  #
  # Each returns a BOOLEAN and never propagates the argument's error — the
  # whole point is to classify it (same non-propagating shape as IFERROR).

  defp call("ISBLANK", [arg], ctx), do: eval(arg, ctx) == :blank
  defp call("ISNUMBER", [arg], ctx), do: is_number(eval(arg, ctx))
  defp call("ISTEXT", [arg], ctx), do: is_binary(eval(arg, ctx))
  defp call("ISLOGICAL", [arg], ctx), do: is_boolean(eval(arg, ctx))
  defp call("ISNA", [arg], ctx), do: match?({:error, "#N/A"}, eval(arg, ctx))
  defp call("ISERROR", [arg], ctx), do: match?({:error, _}, eval(arg, ctx))

  # ISERR is ISERROR minus #N/A.
  defp call("ISERR", [arg], ctx) do
    case eval(arg, ctx) do
      {:error, "#N/A"} -> false
      {:error, _} -> true
      _ -> false
    end
  end

  # ── branching (CHOOSE / SWITCH / IFS) ─────────────────────────────────
  #
  # Lazy like IF: the selector/conditions evaluate, but only the CHOSEN result
  # AST does (`CHOOSE(1, 5, 1/0)` is 5).

  defp call("CHOOSE", [k_ast | choices], ctx) when choices != [] do
    case eval_number(k_ast, ctx) do
      {:error, _} = e ->
        e

      k_n ->
        k = trunc(k_n)
        if k < 1 or k > length(choices), do: err(:value), else: eval(Enum.at(choices, k - 1), ctx)
    end
  end

  defp call("SWITCH", [expr_ast | rest], ctx) when rest != [] do
    case eval(expr_ast, ctx) do
      {:error, _} = e -> e
      v -> switch_match(v, rest, ctx)
    end
  end

  defp call("IFS", args, ctx) when args != [] do
    if rem(length(args), 2) == 0, do: ifs_walk(args, ctx), else: err(:value)
  end

  # ── dates ─────────────────────────────────────────────────────────────

  defp call("DATE", [y, m, d], ctx) do
    with yy when is_number(yy) <- eval_number(y, ctx),
         mm when is_number(mm) <- eval_number(m, ctx),
         dd when is_number(dd) <- eval_number(d, ctx) do
      case Date.new(trunc(yy), trunc(mm), trunc(dd)) do
        {:ok, date} -> date
        _ -> err(:value)
      end
    else
      {:error, _} = e -> e
    end
  end

  defp call("YEAR", [x], ctx), do: date_field(x, ctx, :year)
  defp call("MONTH", [x], ctx), do: date_field(x, ctx, :month)
  defp call("DAY", [x], ctx), do: date_field(x, ctx, :day)

  defp call("TODAY", [], _ctx), do: Date.utc_today()
  defp call("NOW", [], _ctx), do: DateTime.utc_now()

  defp call("NA", [], _ctx), do: err(:na)

  # ── conditional aggregates ────────────────────────────────────────────
  #
  # COUNTIF/SUMIF/AVERAGEIF + the Excel criteria mini-language. The criteria
  # scalar is parsed ONCE per call (any wildcard regex compiled once, never
  # per cell) and matched against every candidate cell.

  defp call("COUNTIF", [range_ast, crit_ast], ctx) do
    with {:ok, p1, p2} <- as_range(range_ast),
         {:ok, spec} <- eval_criteria(crit_ast, ctx) do
      occ = occupied_positions(p1, p2, ctx)
      n = Enum.count(occ, &crit_match?(cell_at(&1, ctx), spec))
      # Occupied-but-blank (v == "") cells are counted in the occ scan above;
      # never-written cells are counted here — the two sets are disjoint.
      unoccupied = rect_area(p1, p2) - length(occ)
      extra = if crit_match?(:blank, spec) and unoccupied > 0, do: unoccupied, else: 0
      n + extra
    else
      {:error, _} = e -> e
      :error -> err(:value)
    end
  end

  defp call("SUMIF", [range_ast, crit_ast], ctx),
    do: call("SUMIF", [range_ast, crit_ast, range_ast], ctx)

  defp call("SUMIF", [range_ast, crit_ast, sum_ast], ctx) do
    case sumif_values(range_ast, crit_ast, sum_ast, ctx) do
      {:error, _} = e -> e
      :error -> err(:value)
      {:ok, vals} -> Enum.sum(vals)
    end
  end

  defp call("AVERAGEIF", [range_ast, crit_ast], ctx),
    do: call("AVERAGEIF", [range_ast, crit_ast, range_ast], ctx)

  defp call("AVERAGEIF", [range_ast, crit_ast, sum_ast], ctx) do
    case sumif_values(range_ast, crit_ast, sum_ast, ctx) do
      {:error, _} = e -> e
      :error -> err(:value)
      {:ok, []} -> err(:div0)
      {:ok, vals} -> divide(Enum.sum(vals), length(vals))
    end
  end

  # ── plural conditional aggregates (COUNTIFS / SUMIFS / AVERAGEIFS) ─────────
  #
  # One-or-more {criteria-range, criteria} pairs AND-combined: a position
  # counts only when EVERY pair's cell matches its criterion. All criteria
  # rects (and, for SUMIFS/AVERAGEIFS, the sum rect) must share one shape —
  # matching is done in shape-relative OFFSET space so disjoint occupancy
  # across the ranges still lines up. Blank semantics ride free: an offset that
  # no range occupies reads `:blank` via cell_at's default, so it participates
  # exactly when every criterion matches blank.

  defp call("COUNTIFS", args, ctx) when args != [] and rem(length(args), 2) == 0 do
    case criteria_pairs(args, ctx) do
      {:error, _} = e ->
        e

      :error ->
        err(:value)

      {:ok, pairs} ->
        {union, matched} = countifs_offsets(pairs, ctx)
        {p1, p2, _spec} = hd(pairs)

        all_blank_extra =
          if all_blank_match?(pairs),
            do: rect_area(p1, p2) - MapSet.size(union),
            else: 0

        length(matched) + all_blank_extra
    end
  end

  # SUMIFS/AVERAGEIFS: the sum range is FIRST (reverse of SUMIF, where it is
  # last) — a classic Excel trap.
  defp call("SUMIFS", [sum_ast | crit_args], ctx)
       when crit_args != [] and rem(length(crit_args), 2) == 0 do
    case sumifs_values(sum_ast, crit_args, ctx) do
      {:error, _} = e -> e
      :error -> err(:value)
      {:ok, vals} -> Enum.sum(vals)
    end
  end

  defp call("AVERAGEIFS", [sum_ast | crit_args], ctx)
       when crit_args != [] and rem(length(crit_args), 2) == 0 do
    case sumifs_values(sum_ast, crit_args, ctx) do
      {:error, _} = e -> e
      :error -> err(:value)
      {:ok, []} -> err(:div0)
      {:ok, vals} -> divide(Enum.sum(vals), length(vals))
    end
  end

  # ── lookup (VLOOKUP / MATCH / INDEX) ──────────────────────────────────────
  #
  # Blank cells are SKIPPED (Excel does the same); text matching is
  # case-insensitive; cross-type comparisons never match. Exact modes scan in
  # ascending position order; approximate modes assume a sorted lookup vector
  # and return the nearest neighbour. Range args are already topo-tracked by
  # walk/2 + range_node_deps, so no dependency-graph work is needed here.

  defp call("VLOOKUP", [val_ast, range_ast, col_ast | rest], ctx)
       when rest == [] or length(rest) == 1 do
    case eval(val_ast, ctx) do
      {:error, _} = e ->
        e

      val ->
        with {:ok, {c1, r1}, {c2, r2}} <- as_range(range_ast),
             col_n when is_number(col_n) <- eval_number(col_ast, ctx),
             flag when is_boolean(flag) <- vlookup_range_flag(rest, ctx) do
          n = trunc(col_n)

          cond do
            n < 1 -> err(:value)
            c1 + n - 1 > c2 -> err(:ref)
            true -> do_vlookup(val, c1, r1, r2, n, flag, ctx)
          end
        else
          :error -> err(:value)
          {:error, _} = e -> e
        end
    end
  end

  defp call("MATCH", [val_ast, range_ast | rest], ctx)
       when rest == [] or length(rest) == 1 do
    case eval(val_ast, ctx) do
      {:error, _} = e ->
        e

      val ->
        with {:ok, {c1, r1}, {c2, r2}} <- as_range(range_ast),
             mt when is_integer(mt) <- match_type(rest, ctx) do
          cond do
            c1 == c2 -> do_match(val, mt, column_cells(c1, r1, r2, ctx), r1)
            r1 == r2 -> do_match(val, mt, row_cells(r1, c1, c2, ctx), c1)
            # A 2D range is #N/A in Excel.
            true -> err(:na)
          end
        else
          :error -> err(:value)
          {:error, _} = e -> e
        end
    end
  end

  defp call("INDEX", [range_ast | idx_asts], ctx) when length(idx_asts) in [1, 2] do
    case as_range(range_ast) do
      :error ->
        err(:value)

      {:ok, {c1, r1}, {c2, r2}} ->
        case idx_asts do
          [idx_ast] -> index_one(c1, r1, c2, r2, idx_ast, ctx)
          [row_ast, col_ast] -> index_two(c1, r1, c2, r2, row_ast, col_ast, ctx)
        end
    end
  end

  # ── statistics ────────────────────────────────────────────────────────
  #
  # Order statistics (MEDIAN/SMALL/LARGE/PERCENTILE/QUARTILE) sort the flattened
  # numbers; the spread family (MODE/RANK/VAR/STDEV/VARP/STDEVP) does not. Every
  # domain miss (empty input, k out of range) is #NUM!; the variance floors are
  # #DIV/0!. Not in @aggregates — these own their arg-handling here.

  defp call("MEDIAN", args, ctx) when args != [] do
    case sorted_numbers(args, ctx) do
      {:error, _} = e ->
        e

      {:ok, []} ->
        err(:num)

      {:ok, nums} ->
        n = length(nums)
        mid = div(n, 2)

        if rem(n, 2) == 1 do
          Enum.at(nums, mid)
        else
          # divide/2 keeps an even-count median exact when the pair sums even.
          divide(Enum.at(nums, mid - 1) + Enum.at(nums, mid), 2)
        end
    end
  end

  defp call("SMALL", [array_ast, k_ast], ctx), do: order_stat(:small, array_ast, k_ast, ctx)
  defp call("LARGE", [array_ast, k_ast], ctx), do: order_stat(:large, array_ast, k_ast, ctx)

  defp call("PERCENTILE", [array_ast, k_ast], ctx) do
    case eval_number(k_ast, ctx) do
      {:error, _} = e -> e
      k_n -> percentile_of([array_ast], k_n, ctx)
    end
  end

  defp call("QUARTILE", [array_ast, q_ast], ctx) do
    case eval_number(q_ast, ctx) do
      {:error, _} = e ->
        e

      q_n ->
        q = trunc(q_n)
        if q < 0 or q > 4, do: err(:num), else: percentile_of([array_ast], q / 4, ctx)
    end
  end

  defp call("MODE", args, ctx) when args != [] do
    case ordered_numbers(args, ctx) do
      {:error, _} = e -> e
      {:ok, nums} -> mode_of(nums)
    end
  end

  defp call("RANK", [x_ast, ref_ast], ctx), do: call("RANK", [x_ast, ref_ast, {:num, 0}], ctx)

  defp call("RANK", [x_ast, ref_ast, order_ast], ctx) do
    # eval_number maps a text x to #VALUE! and a blank x to 0; either flows out
    # via the else clause below (a missing x becomes #N/A once we scan `nums`).
    with x when is_number(x) <- eval_number(x_ast, ctx),
         ord_n when is_number(ord_n) <- eval_number(order_ast, ctx),
         {:ok, nums} <- collect_agg_items([ref_ast], ctx, true, []) do
      if Enum.any?(nums, &(&1 == x)) do
        desc? = trunc(ord_n) == 0
        better = Enum.count(nums, fn v -> if desc?, do: v > x, else: v < x end)
        better + 1
      else
        err(:na)
      end
    else
      {:error, _} = e -> e
    end
  end

  defp call(name, args, ctx) when name in ["VAR", "STDEV"] and args != [],
    do: stdev_or_var(name, args, ctx, :sample)

  defp call(name, args, ctx) when name in ["VARP", "STDEVP"] and args != [],
    do: stdev_or_var(name, args, ctx, :pop)

  defp call(name, args, ctx) when name in @aggregates do
    strict? = name not in ["COUNT", "COUNTA"]

    case collect_agg_items(args, ctx, strict?, []) do
      {:error, _} = e -> e
      {:ok, items} -> aggregate(name, items)
    end
  end

  # SPARKLINE(range | scalar) -> a unicode block-bar string (`▁▂▃▄▅▆▇█` scaled
  # over min..max). Reads numeric cells in reading order (row-major), skipping
  # blanks and text exactly like the aggregates; any error in the range
  # propagates Excel-style. Empty range -> ""; an all-equal series -> a flat
  # mid-bar row; a scalar arg is a 1-cell series. The result is a plain binary,
  # so `output/1` types it "s" and it rides every surface as a display string.
  defp call("SPARKLINE", [arg], ctx) do
    case sparkline_series(arg, ctx) do
      {:error, _} = e -> e
      nums -> sparkline_bars(nums)
    end
  end

  # ── dynamic arrays (array-in / scalar-out; no spill) ────────────────────────
  #
  # Each produces the internal {:array, rows} value — a rows-major list of
  # single-element rows, never persisted. An OUTER aggregate/AND/OR/TEXTJOIN
  # flattens it; a scalar context (top-level cell, arithmetic) implicitly
  # intersects to the top-left element. Blanks are dropped and an error in the
  # source propagates, exactly as from a range.

  defp call("UNIQUE", [ast], ctx) do
    case flat_values(ast, ctx) do
      {:error, _} = e -> e
      {:ok, vals} -> {:array, vals |> Enum.uniq() |> Enum.map(&[&1])}
    end
  end

  defp call("SORT", [ast], ctx), do: call("SORT", [ast, {:num, 1}], ctx)

  defp call("SORT", [ast, order_ast], ctx) do
    with {:ok, vals} <- flat_values(ast, ctx),
         ord when is_number(ord) <- eval_number(order_ast, ctx) do
      dir = if ord < 0, do: :desc, else: :asc
      {:array, vals |> Enum.sort_by(&sort_key/1, dir) |> Enum.map(&[&1])}
    else
      {:error, _} = e -> e
      _ -> err(:value)
    end
  end

  defp call("FILTER", [data_ast, cond_ast], ctx) do
    data = array_vector(data_ast, ctx)
    mask = array_vector(cond_ast, ctx)

    cond do
      e = Enum.find(data ++ mask, &match?({:error, _}, &1)) ->
        e

      data == [] or length(data) != length(mask) ->
        err(:value)

      true ->
        kept =
          data
          |> Enum.zip(mask)
          |> Enum.filter(fn {_d, c} -> truthy(c) == {:ok, true} end)
          |> Enum.map(&elem(&1, 0))

        {:array, Enum.map(kept, &[&1])}
    end
  end

  defp call("SEQUENCE", args, ctx) when length(args) in 1..4 do
    [rows_ast | rest] = args

    with r when is_number(r) <- eval_number(rows_ast, ctx),
         c when is_number(c) <- seq_arg(rest, 0, 1, ctx),
         s when is_number(s) <- seq_arg(rest, 1, 1, ctx),
         st when is_number(st) <- seq_arg(rest, 2, 1, ctx) do
      nr = trunc(r)
      nc = trunc(c)

      cond do
        nr < 1 or nc < 1 ->
          err(:value)

        nr * nc > @array_cap ->
          err(:num)

        true ->
          {:array, for(i <- 0..(nr - 1), do: for(j <- 0..(nc - 1), do: s + (i * nc + j) * st))}
      end
    else
      {:error, _} = e -> e
      _ -> err(:value)
    end
  end

  defp call("COUNTUNIQUE", args, ctx) when args != [] do
    Enum.reduce_while(args, [], fn ast, acc ->
      case flat_values(ast, ctx) do
        {:error, _} = e -> {:halt, e}
        {:ok, vals} -> {:cont, acc ++ vals}
      end
    end)
    |> case do
      {:error, _} = e -> e
      list -> list |> Enum.uniq() |> length()
    end
  end

  # Known function, wrong arity (and the unreachable unknown-name fallthrough).
  defp call(_name, _args, _ctx), do: err(:value)

  defp truthy(b) when is_boolean(b), do: {:ok, b}
  defp truthy(n) when is_number(n), do: {:ok, n != 0}
  defp truthy(:blank), do: {:ok, false}
  defp truthy(_v), do: :error

  # Half away from zero (Excel/Erlang convention); n <= 0 keeps ints exact.
  defp fn_round(x, n) when n >= 0 and is_integer(x), do: x
  defp fn_round(x, 0), do: round(x)

  defp fn_round(x, n) when n > 0 do
    # Cap the scale exponent: rounding a representable float beyond ~300 decimals
    # is a no-op, so a huge n need not build a giant bignum.
    p = Integer.pow(10, min(n, 300))
    safe_arith(fn -> round(x * p) / p end)
  end

  defp fn_round(x, n) do
    p = Integer.pow(10, min(-n, 300))
    safe_arith(fn -> round(x / p) * p end)
  end

  # ROUNDUP mirrors fn_round but rounds away from zero at the scaled precision.
  defp fn_roundup(x, n) when n >= 0 and is_integer(x), do: x
  defp fn_roundup(x, 0), do: ceil_away(x)

  defp fn_roundup(x, n) when n > 0 do
    p = Integer.pow(10, min(n, 300))
    safe_arith(fn -> ceil_away(x * p) / p end)
  end

  defp fn_roundup(x, n) do
    p = Integer.pow(10, min(-n, 300))
    safe_arith(fn -> ceil_away(x / p) * p end)
  end

  # ROUNDDOWN mirrors fn_round but rounds toward zero at the scaled precision.
  defp fn_rounddown(x, n) when n >= 0 and is_integer(x), do: x
  defp fn_rounddown(x, 0), do: trunc_toward(x)

  defp fn_rounddown(x, n) when n > 0 do
    p = Integer.pow(10, min(n, 300))
    safe_arith(fn -> trunc_toward(x * p) / p end)
  end

  defp fn_rounddown(x, n) do
    p = Integer.pow(10, min(-n, 300))
    safe_arith(fn -> trunc_toward(x / p) * p end)
  end

  defp ceil_away(x) when x >= 0, do: trunc(:math.ceil(x))
  defp ceil_away(x), do: trunc(:math.floor(x))

  defp trunc_toward(x) when x >= 0, do: trunc(:math.floor(x))
  defp trunc_toward(x), do: trunc(:math.ceil(x))

  # AND/OR argument coercion: numbers/booleans in a range flatten (text
  # skipped, per Excel), scalars go through truthy/1, an error propagates.
  defp collect_bools([], _ctx, acc), do: Enum.reverse(acc)

  defp collect_bools([{:range, p1, p2} | rest], ctx, acc) do
    vals = range_values(p1, p2, ctx)

    case Enum.find(vals, &match?({:error, _}, &1)) do
      {:error, _} = e ->
        e

      nil ->
        bools = for v <- vals, is_number(v) or is_boolean(v), do: elem(truthy(v), 1)
        collect_bools(rest, ctx, Enum.reverse(bools) ++ acc)
    end
  end

  defp collect_bools([arg | rest], ctx, acc) do
    case eval(arg, ctx) do
      {:error, _} = e ->
        e

      # A nested dynamic array flattens like a range: numbers/booleans keep,
      # text skips, an inner error propagates.
      {:array, rows} ->
        vals = array_flatten(rows)

        case Enum.find(vals, &match?({:error, _}, &1)) do
          {:error, _} = e ->
            e

          nil ->
            bools = for v <- vals, is_number(v) or is_boolean(v), do: elem(truthy(v), 1)
            collect_bools(rest, ctx, Enum.reverse(bools) ++ acc)
        end

      v ->
        case truthy(v) do
          {:ok, b} -> collect_bools(rest, ctx, [b | acc])
          :error -> err(:value)
        end
    end
  end

  # Scalar text coercion via the & operator's rule; an error propagates and a
  # range (which evals to #VALUE!) falls out as an error unless the caller
  # flattens it first. A dynamic array implicitly intersects to its top-left.
  defp eval_text(ast, ctx) do
    case scalarize(eval(ast, ctx)) do
      {:error, _} = e -> e
      v -> to_text(v)
    end
  end

  defp textjoin_ignore(ast, ctx) do
    case eval(ast, ctx) do
      {:error, _} = e ->
        e

      v ->
        case truthy(v) do
          {:ok, b} -> {:ok, b}
          :error -> err(:value)
        end
    end
  end

  defp textjoin_parts([], _ctx, acc), do: {:ok, Enum.reverse(acc)}

  defp textjoin_parts([{:range, p1, p2} | rest], ctx, acc) do
    vals = range_values(p1, p2, ctx)

    case Enum.find(vals, &match?({:error, _}, &1)) do
      {:error, _} = e ->
        e

      nil ->
        texts = Enum.map(vals, &to_text/1)
        textjoin_parts(rest, ctx, Enum.reverse(texts) ++ acc)
    end
  end

  defp textjoin_parts([arg | rest], ctx, acc) do
    case eval(arg, ctx) do
      {:error, _} = e ->
        e

      # A nested dynamic array flattens like a range: every (non-blank) value
      # becomes a part, an inner error propagates.
      {:array, rows} ->
        vals = array_flatten(rows)

        case Enum.find(vals, &match?({:error, _}, &1)) do
          {:error, _} = e ->
            e

          nil ->
            texts = Enum.map(vals, &to_text/1)
            textjoin_parts(rest, ctx, Enum.reverse(texts) ++ acc)
        end

      v ->
        textjoin_parts(rest, ctx, [to_text(v) | acc])
    end
  end

  defp date_field(ast, ctx, field) do
    case eval(ast, ctx) do
      {:error, _} = e -> e
      %Date{} = d -> Map.fetch!(d, field)
      %DateTime{} = dt -> Map.fetch!(dt, field)
      %NaiveDateTime{} = ndt -> Map.fetch!(ndt, field)
      _ -> err(:value)
    end
  end

  defp collect_agg_items([], _ctx, _strict?, acc), do: {:ok, acc}

  defp collect_agg_items([{:range, p1, p2} | rest], ctx, strict?, acc) do
    vals = range_values(p1, p2, ctx)

    if strict? do
      case Enum.find(vals, &match?({:error, _}, &1)) do
        {:error, _} = e -> e
        nil -> collect_agg_items(rest, ctx, strict?, Enum.filter(vals, &is_number/1) ++ acc)
      end
    else
      collect_agg_items(rest, ctx, strict?, vals ++ acc)
    end
  end

  defp collect_agg_items([arg | rest], ctx, strict?, acc) do
    case eval(arg, ctx) do
      {:error, _} = e when strict? -> e
      {:error, _} = e -> collect_agg_items(rest, ctx, strict?, [e | acc])
      # A nested dynamic array flattens with the SAME rules a range gets: a
      # strict aggregate keeps only numbers and propagates an inner error, a
      # lenient one (COUNT/COUNTA) keeps every non-blank value.
      {:array, rows} -> collect_array_agg(array_flatten(rows), rest, ctx, strict?, acc)
      :blank -> collect_agg_items(rest, ctx, strict?, acc)
      n when is_number(n) -> collect_agg_items(rest, ctx, strict?, [n | acc])
      _other when strict? -> err(:value)
      other -> collect_agg_items(rest, ctx, strict?, [other | acc])
    end
  end

  defp collect_array_agg(vals, rest, ctx, true = strict?, acc) do
    case Enum.find(vals, &match?({:error, _}, &1)) do
      {:error, _} = e -> e
      nil -> collect_agg_items(rest, ctx, strict?, Enum.filter(vals, &is_number/1) ++ acc)
    end
  end

  defp collect_array_agg(vals, rest, ctx, false = strict?, acc) do
    collect_agg_items(rest, ctx, strict?, vals ++ acc)
  end

  defp range_values(p1, p2, ctx) do
    occupied_positions(p1, p2, ctx)
    |> Enum.map(&cell_at(&1, ctx))
    |> Enum.reject(&(&1 == :blank))
  end

  # SPARKLINE's numeric series in reading order (row-major: sorted by {row,col}),
  # blanks/text skipped like the aggregates. An error anywhere in a range
  # short-circuits to that error (returned as an `{:error, _}` tuple); otherwise
  # a bare list of numbers is returned. A scalar arg is a 1-cell series (a blank
  # scalar -> []); a non-numeric scalar is #VALUE! like a strict aggregate.
  defp sparkline_series({:range, p1, p2}, ctx) do
    cells = Enum.map(occupied_positions(p1, p2, ctx), fn pos -> {pos, cell_at(pos, ctx)} end)

    case Enum.find(cells, fn {_pos, v} -> match?({:error, _}, v) end) do
      {_pos, {:error, _} = e} ->
        e

      nil ->
        cells
        |> Enum.filter(fn {_pos, v} -> is_number(v) end)
        |> Enum.sort_by(fn {{c, r}, _v} -> {r, c} end)
        |> Enum.map(fn {_pos, v} -> v end)
    end
  end

  defp sparkline_series(arg, ctx) do
    case eval(arg, ctx) do
      {:error, _} = e -> e
      # A dynamic array (SORT/UNIQUE/FILTER) feeds SPARKLINE the same way a
      # range does — keep only numbers and propagate an inner error — but the
      # array's stored order is authoritative (SORT already sorted it), so it is
      # NOT re-sorted the way a raw range's reading order is.
      {:array, rows} -> sparkline_from_array(array_flatten(rows))
      :blank -> []
      n when is_number(n) -> [n]
      _ -> err(:value)
    end
  end

  defp sparkline_from_array(flat) do
    case Enum.find(flat, &match?({:error, _}, &1)) do
      {:error, _} = e -> e
      nil -> Enum.filter(flat, &is_number/1)
    end
  end

  # Map a numeric series onto the 8-level block-bar ramp. Empty -> ""; an
  # all-equal (min == max) series -> a flat mid-bar row (one @sparkline_mid per
  # value, no divide-by-zero); otherwise each value scales linearly onto ▁..█.
  defp sparkline_bars([]), do: ""

  defp sparkline_bars(nums) do
    lo = Enum.min(nums)
    hi = Enum.max(nums)

    if lo == hi do
      String.duplicate(@sparkline_mid, length(nums))
    else
      span = hi - lo
      top = length(@sparkline_ramp) - 1

      # A bignum value/span coerces past float64 in `(v - lo) / span` and
      # raises — fall back to #NUM! (propagated by the SPARKLINE caller).
      safe_arith(fn ->
        nums
        |> Enum.map(fn v -> Enum.at(@sparkline_ramp, round((v - lo) / span * top)) end)
        |> Enum.join()
      end)
    end
  end

  # ── dynamic-array helpers ───────────────────────────────────────────────────

  # Materialise an argument to a flat list of non-blank values for the
  # order-insensitive producers (UNIQUE/SORT/COUNTUNIQUE), propagating any
  # error the same way a range does.
  defp flat_values(ast, ctx) do
    vals = raw_flat(ast, ctx)

    case Enum.find(vals, &match?({:error, _}, &1)) do
      {:error, _} = e -> e
      nil -> {:ok, Enum.reject(vals, &(&1 == :blank))}
    end
  end

  defp raw_flat({:range, p1, p2}, ctx), do: List.flatten(range_grid(p1, p2, ctx))
  defp raw_flat({:ref, pos}, ctx), do: [cell_at(pos, ctx)]

  defp raw_flat(ast, ctx) do
    case eval(ast, ctx) do
      {:array, rows} -> List.flatten(rows)
      :blank -> []
      other -> [other]
    end
  end

  # Like raw_flat but KEEPS blanks (as the :blank sentinel) so FILTER can align
  # a data vector against its include vector by position.
  defp array_vector({:range, p1, p2}, ctx), do: List.flatten(range_grid(p1, p2, ctx))
  defp array_vector({:ref, pos}, ctx), do: [cell_at(pos, ctx)]

  defp array_vector(ast, ctx) do
    case eval(ast, ctx) do
      {:array, rows} -> List.flatten(rows)
      other -> [other]
    end
  end

  # Flatten an intermediate {:array, rows} for a consumer (aggregate/AND/OR/
  # TEXTJOIN), dropping blanks exactly as those drop blank range cells.
  defp array_flatten(rows), do: rows |> List.flatten() |> Enum.reject(&(&1 == :blank))

  # A dense coordinate-ordered read of a range, clamped to the occupied
  # bounding box inside the literal rectangle so blank tails don't force a
  # million-cell walk; unwritten interior cells come back as :blank. Row-major
  # list of rows.
  defp range_grid(p1, p2, ctx) do
    case occupied_positions(p1, p2, ctx) do
      [] ->
        []

      positions ->
        {cmin, cmax} = positions |> Enum.map(&elem(&1, 0)) |> Enum.min_max()
        {rmin, rmax} = positions |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
        for r <- rmin..rmax, do: for(c <- cmin..cmax, do: cell_at({c, r}, ctx))
    end
  end

  # Total sort order for SORT: numbers, then text (case-folded), then booleans,
  # then anything else — mirroring Excel's type grouping.
  defp sort_key(n) when is_number(n), do: {0, n}
  defp sort_key(s) when is_binary(s), do: {1, String.downcase(s)}
  defp sort_key(b) when is_boolean(b), do: {2, bool_rank(b)}
  defp sort_key(other), do: {3, other}

  # SEQUENCE's optional cols/start/step, each defaulting when absent.
  defp seq_arg(rest, idx, default, ctx) do
    case Enum.at(rest, idx) do
      nil -> default
      ast -> eval_number(ast, ctx)
    end
  end

  # Implicit intersection: an array in a scalar context collapses to its
  # top-left element (Excel's legacy `@`); any other value passes through.
  defp scalarize({:array, rows}), do: array_top_left(rows)
  defp scalarize(v), do: v

  defp array_top_left([[v | _] | _]), do: v
  defp array_top_left(_), do: :blank

  # Occupied cell positions inside a rectangle — iterate min(rectangle,
  # occupied set), never the full (possibly million-cell) area.
  defp occupied_positions({c1, r1}, {c2, r2}, ctx) do
    area = (c2 - c1 + 1) * (r2 - r1 + 1)

    if area <= MapSet.size(ctx.occupied) do
      for c <- c1..c2, r <- r1..r2, MapSet.member?(ctx.occupied, {c, r}), do: {c, r}
    else
      Enum.filter(ctx.occupied, fn {c, r} -> c >= c1 and c <= c2 and r >= r1 and r <= r2 end)
    end
  end

  defp rect_area({c1, r1}, {c2, r2}), do: (c2 - c1 + 1) * (r2 - r1 + 1)

  # A range or single-ref AST node as a rectangle; anything else is not a
  # range (the caller maps it to #VALUE!).
  defp as_range({:range, p1, p2}), do: {:ok, p1, p2}
  defp as_range({:ref, pos}), do: {:ok, pos, pos}
  defp as_range(_other), do: :error

  # ── lookup helpers ──────────────────────────────────────────────────────
  #
  # Occupied, non-blank cells of a single column/row, as {coordinate, value}
  # sorted ascending by position. occupied_positions never expands a
  # million-cell rectangle; blank (never-written or "") cells are dropped so
  # position walks match Excel's skip-blanks behaviour.
  defp column_cells(col, r1, r2, ctx) do
    line_cells(occupied_positions({col, r1}, {col, r2}, ctx), fn {_c, r} -> r end, ctx)
  end

  defp row_cells(row, c1, c2, ctx) do
    line_cells(occupied_positions({c1, row}, {c2, row}, ctx), fn {c, _r} -> c end, ctx)
  end

  defp line_cells(positions, coord_of, ctx) do
    positions
    |> Enum.map(fn pos -> {coord_of.(pos), cell_at(pos, ctx)} end)
    |> Enum.reject(fn {_coord, v} -> v == :blank end)
    |> Enum.sort_by(fn {coord, _v} -> coord end)
  end

  # Excel lookup equality: same-type only (numbers/numbers, text/text
  # case-insensitively, booleans/booleans); cross-type and :blank never match.
  defp lookup_compare(a, b) when is_number(a) and is_number(b), do: a == b

  defp lookup_compare(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp lookup_compare(a, b) when is_boolean(a) and is_boolean(b), do: a == b
  defp lookup_compare(_a, _b), do: false

  # Same-type ordered comparisons for approximate lookup; a cross-type pair
  # (order/2 → :mismatch) never qualifies.
  defp lookup_le?(cell, val), do: order(cell, val) in [:lt, :eq]
  defp lookup_ge?(cell, val), do: order(cell, val) in [:gt, :eq]

  # rest is the optional VLOOKUP 4th arg: [] (or truthy) → approximate.
  defp vlookup_range_flag([], _ctx), do: true

  defp vlookup_range_flag([ast], ctx) do
    case eval(ast, ctx) do
      {:error, _} = e ->
        e

      v ->
        case truthy(v) do
          {:ok, b} -> b
          :error -> err(:value)
        end
    end
  end

  defp do_vlookup(val, c1, r1, r2, n, approx?, ctx) do
    row =
      if approx? do
        # Sorted-ascending assumption: keep the last value <= val.
        Enum.reduce(column_cells(c1, r1, r2, ctx), nil, fn {r, cell}, best ->
          if lookup_le?(cell, val), do: r, else: best
        end)
      else
        case Enum.find(column_cells(c1, r1, r2, ctx), fn {_r, cell} ->
               lookup_compare(cell, val)
             end) do
          {r, _cell} -> r
          nil -> nil
        end
      end

    case row do
      nil -> err(:na)
      # Blank result cell mirrors a plain ref: cell_at raw → :blank → 0.
      r -> cell_at({c1 + n - 1, r}, ctx)
    end
  end

  # rest is the optional MATCH type arg: [] defaults to 1.
  defp match_type([], _ctx), do: 1

  defp match_type([ast], ctx) do
    case eval_number(ast, ctx) do
      {:error, _} = e -> e
      n -> trunc(n)
    end
  end

  # cells :: [{coordinate, value}] ascending by coordinate; base is the range's
  # low coordinate, so the returned 1-based position counts blank gaps too.
  defp do_match(val, mt, cells, base) do
    coord =
      cond do
        mt == 0 -> match_exact(val, cells)
        mt > 0 -> match_le(val, cells)
        true -> match_ge(val, cells)
      end

    case coord do
      nil -> err(:na)
      c -> c - base + 1
    end
  end

  defp match_exact(val, cells) do
    pred =
      if is_binary(val) and String.contains?(val, ["*", "?"]) do
        rx = wildcard_regex(val)
        fn cell -> is_binary(cell) and Regex.match?(rx, cell) end
      else
        fn cell -> lookup_compare(cell, val) end
      end

    case Enum.find(cells, fn {_coord, cell} -> pred.(cell) end) do
      {coord, _cell} -> coord
      nil -> nil
    end
  end

  # type 1: ascending assumption, largest value <= val (last kept while walking).
  defp match_le(val, cells) do
    Enum.reduce(cells, nil, fn {coord, cell}, best ->
      if lookup_le?(cell, val), do: coord, else: best
    end)
  end

  # type -1: descending assumption, smallest value >= val (last kept while walking).
  defp match_ge(val, cells) do
    Enum.reduce(cells, nil, fn {coord, cell}, best ->
      if lookup_ge?(cell, val), do: coord, else: best
    end)
  end

  defp index_one(c1, r1, c2, r2, idx_ast, ctx) do
    case eval_number(idx_ast, ctx) do
      {:error, _} = e ->
        e

      idx_n ->
        i = trunc(idx_n)

        cond do
          i < 1 -> err(:value)
          # A single row (covers a single cell): index across columns.
          r1 == r2 -> if c1 + i - 1 > c2, do: err(:ref), else: cell_at({c1 + i - 1, r1}, ctx)
          c1 == c2 -> if r1 + i - 1 > r2, do: err(:ref), else: cell_at({c1, r1 + i - 1}, ctx)
          # Excel's array-return form on a 2D range is out of scope.
          true -> err(:value)
        end
    end
  end

  defp index_two(c1, r1, c2, r2, row_ast, col_ast, ctx) do
    case {eval_number(row_ast, ctx), eval_number(col_ast, ctx)} do
      {{:error, _} = e, _} ->
        e

      {_, {:error, _} = e} ->
        e

      {rn, cn} ->
        row = trunc(rn)
        col = trunc(cn)

        cond do
          row < 1 or col < 1 -> err(:value)
          r1 + row - 1 > r2 or c1 + col - 1 > c2 -> err(:ref)
          true -> cell_at({c1 + col - 1, r1 + row - 1}, ctx)
        end
    end
  end

  # ── criteria mini-language (COUNTIF/SUMIF/AVERAGEIF) ────────────────────

  defp eval_criteria(ast, ctx) do
    case eval(ast, ctx) do
      {:error, _} = e -> e
      v -> {:ok, parse_criteria(v)}
    end
  end

  # Collect the sum/average values for SUMIF/AVERAGEIF. The criteria range and
  # the sum range MUST have identical shape — Excel's resize-from-top-left
  # would read cells the topo graph never registered as range deps, so we
  # reject a mismatch as #VALUE! rather than silently under-computing.
  defp sumif_values(range_ast, crit_ast, sum_ast, ctx) do
    with {:ok, c1, c2} <- as_range(range_ast),
         {:ok, s1, s2} <- as_range(sum_ast),
         :ok <- same_shape(c1, c2, s1, s2),
         {:ok, spec} <- eval_criteria(crit_ast, ctx) do
      {cc1, cr1} = c1
      {sc1, sr1} = s1
      dc = sc1 - cc1
      dr = sr1 - cr1

      matched =
        for {c, r} = pos <- occupied_positions(c1, c2, ctx),
            crit_match?(cell_at(pos, ctx), spec),
            do: {c + dc, r + dr}

      # When the criteria matches BLANK, an unoccupied criteria cell also
      # matches: find those by scanning occupied SUM cells whose un-shifted
      # criteria position is unoccupied (disjoint from `matched`, no double
      # count).
      blank_matched =
        if crit_match?(:blank, spec) do
          for {c, r} = pos <- occupied_positions(s1, s2, ctx),
              not MapSet.member?(ctx.occupied, {c - dc, r - dr}),
              do: pos
        else
          []
        end

      cells = Enum.map(matched ++ blank_matched, &cell_at(&1, ctx))

      case Enum.find(cells, &match?({:error, _}, &1)) do
        {:error, _} = e -> e
        nil -> {:ok, Enum.filter(cells, &is_number/1)}
      end
    end
  end

  defp same_shape({c1, r1}, {c2, r2}, {sc1, sr1}, {sc2, sr2}) do
    if c2 - c1 == sc2 - sc1 and r2 - r1 == sr2 - sr1, do: :ok, else: :error
  end

  # ── plural conditional-aggregate helpers ───────────────────────────────────

  # Evaluate the flat [range, crit, range, crit, …] argument list into
  # [{top_left, bottom_right, spec}, …]. Every rect must share the FIRST rect's
  # shape (offset-space matching depends on it); a non-range arg or a criteria
  # error propagates, a shape mismatch is :error (→ #VALUE!).
  defp criteria_pairs(args, ctx) do
    args
    |> Enum.chunk_every(2)
    |> Enum.reduce_while({:ok, []}, fn [range_ast, crit_ast], {:ok, acc} ->
      with {:ok, p1, p2} <- as_range(range_ast),
           {:ok, spec} <- eval_criteria(crit_ast, ctx) do
        {:cont, {:ok, [{p1, p2, spec} | acc]}}
      else
        :error -> {:halt, :error}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, rev} ->
        pairs = Enum.reverse(rev)
        {p1, p2, _} = hd(pairs)

        if Enum.all?(pairs, fn {q1, q2, _} -> same_shape(p1, p2, q1, q2) == :ok end),
          do: {:ok, pairs},
          else: :error

      other ->
        other
    end
  end

  # UNION of every pair's occupied cells expressed as shape-relative offsets,
  # plus the offsets in that union where EVERY pair's criterion matches. A
  # never-written cell reads :blank (cell_at default), so blank criteria match
  # for free.
  defp countifs_offsets(pairs, ctx) do
    union =
      Enum.reduce(pairs, MapSet.new(), fn {{ci, ri} = p1, p2, _spec}, acc ->
        occupied_positions(p1, p2, ctx)
        |> Enum.reduce(acc, fn {c, r}, a -> MapSet.put(a, {c - ci, r - ri}) end)
      end)

    matched =
      Enum.filter(union, fn {dc, dr} ->
        Enum.all?(pairs, fn {{ci, ri}, _p2, spec} ->
          crit_match?(cell_at({ci + dc, ri + dr}, ctx), spec)
        end)
      end)

    {union, matched}
  end

  defp all_blank_match?(pairs) do
    Enum.all?(pairs, fn {_, _, spec} -> crit_match?(:blank, spec) end)
  end

  # SUMIFS/AVERAGEIFS value collection. The sum rect must match the first
  # criteria rect's shape; matched offsets read the sum cell at the same offset.
  # When every criterion matches blank, an occupied sum cell whose criteria
  # offset is UNoccupied (disjoint from the union) also contributes — mirroring
  # sumif_values' blank branch and its error propagation.
  defp sumifs_values(sum_ast, crit_args, ctx) do
    with {:ok, s1, s2} <- as_range(sum_ast),
         {:ok, pairs} <- criteria_pairs(crit_args, ctx),
         {p1, p2, _} <- hd(pairs),
         :ok <- same_shape(p1, p2, s1, s2) do
      {union, matched} = countifs_offsets(pairs, ctx)
      {sc1, sr1} = s1

      matched_cells = Enum.map(matched, fn {dc, dr} -> cell_at({sc1 + dc, sr1 + dr}, ctx) end)

      blank_cells =
        if all_blank_match?(pairs) do
          for {sc, sr} = pos <- occupied_positions(s1, s2, ctx),
              not MapSet.member?(union, {sc - sc1, sr - sr1}),
              do: cell_at(pos, ctx)
        else
          []
        end

      cells = matched_cells ++ blank_cells

      case Enum.find(cells, &match?({:error, _}, &1)) do
        {:error, _} = e -> e
        nil -> {:ok, Enum.filter(cells, &is_number/1)}
      end
    else
      :error -> :error
      {:error, _} = e -> e
    end
  end

  # Parse an EVALUATED criteria scalar into a match spec. Two-char comparators
  # before one-char; a bare value is equality.
  defp parse_criteria(:blank), do: {:eq, ""}

  defp parse_criteria(v) when is_binary(v) do
    {op, rest} = split_comparator(v)
    operand = parse_number(rest) || rest

    if op in [:eq, :ne] and is_binary(operand) do
      # Compile a regex whenever a wildcard OR an escape is present so `~*`
      # unescapes to a literal `*` (Excel semantics); otherwise a plain
      # case-insensitive equality via compare/2.
      if needs_regex?(operand),
        do: {op, {:rx, wildcard_regex(operand)}},
        else: {op, String.downcase(operand)}
    else
      {op, operand}
    end
  end

  defp parse_criteria(v), do: {:eq, v}

  defp split_comparator(">=" <> rest), do: {:ge, rest}
  defp split_comparator("<=" <> rest), do: {:le, rest}
  defp split_comparator("<>" <> rest), do: {:ne, rest}
  defp split_comparator("=" <> rest), do: {:eq, rest}
  defp split_comparator(">" <> rest), do: {:gt, rest}
  defp split_comparator("<" <> rest), do: {:lt, rest}
  defp split_comparator(rest), do: {:eq, rest}

  # Any `*`/`?`/`~` means the operand needs the regex path (`~` may escape a
  # wildcard, which the plain equality path cannot unescape).
  defp needs_regex?(s), do: String.contains?(s, ["*", "?", "~"])

  # Compile a wildcard pattern to a case-insensitive regex. Anchored (`^…$`) by
  # default for MATCH/criteria whole-cell matching; SEARCH asks for the
  # UNANCHORED variant so it can find the pattern anywhere in the haystack.
  # `u` (unicode) mode: without it case-folding and `.`/`?` are byte-wise, so a
  # `?` mid-codepoint corrupted any non-ASCII match (SEARCH("Æ","æble") missed;
  # positions landed mid-byte). With `u`, `?` matches exactly one codepoint.
  defp wildcard_regex(s, anchored? \\ true) do
    inner = s |> String.graphemes() |> wild_to_regex([])
    pattern = if anchored?, do: "^" <> inner <> "$", else: inner
    Regex.compile!(pattern, "ius")
  end

  defp wild_to_regex(["~", "*" | rest], acc), do: wild_to_regex(rest, [Regex.escape("*") | acc])
  defp wild_to_regex(["~", "?" | rest], acc), do: wild_to_regex(rest, [Regex.escape("?") | acc])
  defp wild_to_regex(["~", "~" | rest], acc), do: wild_to_regex(rest, [Regex.escape("~") | acc])
  defp wild_to_regex(["*" | rest], acc), do: wild_to_regex(rest, [".*" | acc])
  defp wild_to_regex(["?" | rest], acc), do: wild_to_regex(rest, ["." | acc])
  defp wild_to_regex([c | rest], acc), do: wild_to_regex(rest, [Regex.escape(c) | acc])
  defp wild_to_regex([], acc), do: acc |> Enum.reverse() |> Enum.join()

  # ── text helpers (FIND / SEARCH / SUBSTITUTE / VALUE) ──────────────────

  # Case-sensitive literal search from a 1-based start; out-of-range start or a
  # miss is #VALUE!. String.split on the needle gives a grapheme-correct offset.
  defp find_at(needle, hay, start) do
    len = String.length(hay)

    cond do
      start < 1 or start > len + 1 ->
        err(:value)

      true ->
        sub = String.slice(hay, start - 1, len)

        case String.split(sub, needle, parts: 2) do
          [_single] -> err(:value)
          [prefix, _rest] -> start + String.length(prefix)
        end
    end
  end

  # Case-insensitive wildcard search from a 1-based start; the unanchored regex
  # match's byte offset converts to a grapheme position via the matched prefix.
  defp search_at(needle, hay, start) do
    len = String.length(hay)

    cond do
      start < 1 or start > len + 1 ->
        err(:value)

      true ->
        sub = String.slice(hay, start - 1, len)
        rx = wildcard_regex(needle, false)

        case Regex.run(rx, sub, return: :index) do
          [{byte_off, _} | _] -> start + String.length(binary_part(sub, 0, byte_off))
          nil -> err(:value)
        end
    end
  end

  # Replace only the nth occurrence of `old`; fewer than n occurrences leaves
  # the text unchanged (Excel).
  defp substitute_nth(text, old, new, n) do
    parts = String.split(text, old)

    if length(parts) - 1 < n do
      text
    else
      {before_parts, after_parts} = Enum.split(parts, n)
      Enum.join(before_parts, old) <> new <> Enum.join(after_parts, old)
    end
  end

  defp parse_value(s) do
    if String.ends_with?(s, "%") do
      case parse_number(s |> String.trim_trailing("%") |> String.trim()) do
        nil -> err(:value)
        n -> n / 100
      end
    else
      parse_number(s) || err(:value)
    end
  end

  # ── branching helpers (SWITCH / IFS) ──────────────────────────────────

  # Walk expr/result pairs; a trailing odd arg is the default. Only the matched
  # result AST evaluates; no match and no default is #N/A.
  defp switch_match(v, [val_ast, res_ast | rest], ctx) do
    case eval(val_ast, ctx) do
      {:error, _} = e ->
        e

      candidate ->
        if lookup_compare(v, candidate), do: eval(res_ast, ctx), else: switch_match(v, rest, ctx)
    end
  end

  defp switch_match(_v, [default_ast], ctx), do: eval(default_ast, ctx)
  defp switch_match(_v, [], _ctx), do: err(:na)

  # Conditions evaluate lazily left-to-right; the first truthy one's result
  # AST evaluates. None true is #N/A.
  defp ifs_walk([], _ctx), do: err(:na)

  defp ifs_walk([cond_ast, res_ast | rest], ctx) do
    case eval(cond_ast, ctx) do
      {:error, _} = e ->
        e

      v ->
        case truthy(v) do
          :error -> err(:value)
          {:ok, true} -> eval(res_ast, ctx)
          {:ok, false} -> ifs_walk(rest, ctx)
        end
    end
  end

  # Match an evaluated cell value against a criteria spec. Blank rules first,
  # then errors (never match), then wildcard regex, then general comparison.
  defp crit_match?(:blank, {:eq, ""}), do: true
  defp crit_match?(:blank, {:ne, operand}), do: operand != ""
  defp crit_match?(:blank, _spec), do: false
  defp crit_match?({:error, _}, _spec), do: false

  defp crit_match?(v, {:eq, {:rx, rx}}) when is_binary(v), do: Regex.match?(rx, v)
  defp crit_match?(_v, {:eq, {:rx, _rx}}), do: false
  defp crit_match?(v, {:ne, {:rx, rx}}) when is_binary(v), do: not Regex.match?(rx, v)
  defp crit_match?(_v, {:ne, {:rx, _rx}}), do: true

  defp crit_match?(v, {op, operand}) do
    # Excel coerces numeric-looking text against numeric criteria.
    v = if is_binary(v) and is_number(operand), do: parse_number(v) || v, else: v

    case compare(op, v, operand) do
      true -> true
      _ -> false
    end
  end

  defp aggregate("SUM", items), do: Enum.sum(items)

  defp aggregate(avg, items) when avg in ["AVG", "AVERAGE"] do
    case items do
      [] -> err(:div0)
      nums -> divide(Enum.sum(nums), length(nums))
    end
  end

  defp aggregate("MIN", []), do: 0
  defp aggregate("MIN", items), do: Enum.min(items)
  defp aggregate("MAX", []), do: 0
  defp aggregate("MAX", items), do: Enum.max(items)
  defp aggregate("COUNT", items), do: Enum.count(items, &is_number/1)
  defp aggregate("COUNTA", items), do: length(items)

  # ── statistics helpers ────────────────────────────────────────────────────
  #
  # sorted_numbers: the flattened numeric arguments (strict aggregate rules —
  # text/booleans skipped, an error propagates) sorted ascending. ordered_numbers
  # keeps ENCOUNTER order for MODE's earliest-occurrence tie-break, which the
  # reverse-building collect_agg_items would scramble.

  defp sorted_numbers(args, ctx) do
    case collect_agg_items(args, ctx, true, []) do
      {:error, _} = e -> e
      {:ok, nums} -> {:ok, Enum.sort(nums)}
    end
  end

  defp ordered_numbers(args, ctx) do
    Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, acc} ->
      case arg do
        {:range, p1, p2} ->
          vals = range_values(p1, p2, ctx)

          case Enum.find(vals, &match?({:error, _}, &1)) do
            {:error, _} = e -> {:halt, e}
            nil -> {:cont, {:ok, acc ++ Enum.filter(vals, &is_number/1)}}
          end

        _ ->
          case eval(arg, ctx) do
            {:error, _} = e -> {:halt, e}
            :blank -> {:cont, {:ok, acc}}
            n when is_number(n) -> {:cont, {:ok, acc ++ [n]}}
            _ -> {:halt, err(:value)}
          end
      end
    end)
  end

  # kth smallest (:small) / largest (:large); k<1 or k>n is #NUM!.
  defp order_stat(which, array_ast, k_ast, ctx) do
    case eval_number(k_ast, ctx) do
      {:error, _} = e ->
        e

      k_n ->
        case sorted_numbers([array_ast], ctx) do
          {:error, _} = e ->
            e

          {:ok, nums} ->
            n = length(nums)
            k = trunc(k_n)

            cond do
              k < 1 or k > n -> err(:num)
              which == :small -> Enum.at(nums, k - 1)
              true -> Enum.at(nums, n - k)
            end
        end
    end
  end

  # Linear-interpolation percentile: rank = k*(n-1); an integral rank returns the
  # order statistic exactly (int-preserving), else interpolate the neighbours.
  # Empty input or k outside [0,1] is #NUM!.
  defp percentile_of(args, k, ctx) do
    case sorted_numbers(args, ctx) do
      {:error, _} = e ->
        e

      {:ok, []} ->
        err(:num)

      {:ok, nums} ->
        if k < 0 or k > 1 do
          err(:num)
        else
          n = length(nums)
          rank = k * (n - 1)
          lo = trunc(:math.floor(rank))
          frac = rank - lo

          if frac == 0 do
            Enum.at(nums, lo)
          else
            a = Enum.at(nums, lo)
            b = Enum.at(nums, lo + 1)
            # A bignum neighbour makes `(b - a) * frac` coerce past float64 and
            # raise — degrade to #NUM! rather than crash the whole recompute.
            safe_arith(fn -> a + (b - a) * frac end)
          end
        end
    end
  end

  # Most frequent value; nothing repeating is #N/A (not #NUM!). Ties in the top
  # frequency resolve to the earliest first occurrence (nums is encounter order).
  defp mode_of(nums) do
    # Canonicalise the frequency key so the integer 1 and the float 1.0 (e.g.
    # from 0.5+0.5) share a bucket — otherwise MODE(1, 0.5+0.5, 2) wrongly
    # returned #N/A because they counted as distinct values.
    counts =
      Enum.reduce(nums, %{}, fn v, acc -> Map.update(acc, mode_key(v), 1, &(&1 + 1)) end)

    top = counts |> Map.values() |> Enum.max(fn -> 0 end)

    if top < 2 do
      err(:na)
    else
      Enum.find(nums, fn v -> Map.fetch!(counts, mode_key(v)) == top end)
    end
  end

  defp mode_key(v) when is_float(v) and v == trunc(v), do: trunc(v)
  defp mode_key(v), do: v

  # Sample (n-1) / population (n) variance, then sqrt for STDEV/STDEVP. The
  # divisor floor (n<2 sample, n<1 population) is #DIV/0!.
  defp stdev_or_var(name, args, ctx, kind) do
    case variance(args, ctx, kind) do
      {:error, _} = e -> e
      var when name in ["STDEV", "STDEVP"] -> :math.sqrt(var)
      var -> var
    end
  end

  defp variance(args, ctx, kind) do
    case collect_agg_items(args, ctx, true, []) do
      {:error, _} = e ->
        e

      {:ok, nums} ->
        n = length(nums)
        floor_n = if kind == :sample, do: 2, else: 1

        if n < floor_n do
          err(:div0)
        else
          # A bignum item (e.g. an imported cell or 2^1023+2^1023 summing past
          # float64) blows up the `/n` coercion — keep recompute total by
          # turning that ArithmeticError into a #NUM! cell.
          safe_arith(fn ->
            mean = Enum.sum(nums) / n
            ss = Enum.reduce(nums, 0, fn v, acc -> acc + (v - mean) * (v - mean) end)
            divisor = if kind == :sample, do: n - 1, else: n
            ss / divisor
          end)
        end
    end
  end

  defp err(:value), do: {:error, "#VALUE!"}
  defp err(:div0), do: {:error, "#DIV/0!"}
  defp err(:ref), do: {:error, "#REF!"}
  defp err(:cycle), do: {:error, "#CYCLE!"}
  defp err(:na), do: {:error, "#N/A"}
  defp err(:num), do: {:error, "#NUM!"}
end
