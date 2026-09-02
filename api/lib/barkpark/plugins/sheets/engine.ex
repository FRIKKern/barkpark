defmodule Barkpark.Plugins.Sheets.Engine do
  @moduledoc """
  The Sheets formula engine — recomputes cached `"v"` values for every
  formula cell of a sheet document's content, AHEAD of snapshot synthesis
  (`Barkpark.Plugins.Sheets.Core.snapshot_for/2`). `Barkpark.Content` calls `recompute/1`
  on every `"sheet"` save, so HTTP mutations persist computed values and the
  write-through snapshots project them into embeds with zero renderer
  changes. Pure functions: no Repo, no I/O — except `TODAY`/`NOW` (which read
  the wall clock) and `RAND`/`RANDBETWEEN` (which draw from a fresh
  per-recompute seed): all four are volatile-as-of-last-save — they recompute
  only when the sheet is saved, not on every read. A RAND draw is a PURE
  function of `{recompute-seed, tab, col, row}`, so it is identical across
  every phase of a multi-phase (spill) recompute — a spill anchor and its
  dependents persist the same draw — yet fresh on the next save; process-global
  `:rand` state is never touched.

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
  Refs resolve within the cell's OWN tab by default, and a `Tab!A1`
  qualifier reaches another tab: `Sheet2!A1`, `SUM(Sheet2!A1:A3)`, and the
  quoted `'My Sheet'!A1` (with `''` escaping a literal apostrophe). A tab
  name that resolves to the formula's own tab is same-tab; an UNKNOWN tab
  name is `#REF!`; a range whose two corners name different tabs is `#REF!`.
  A document with any cross-tab reference recomputes as ONE unified
  `{tab, col, row}` dependency graph (so a `Sheet1!A1 → Sheet2!A1 →
  Sheet1!A1` loop is `#CYCLE!` on both cells); a document with none keeps the
  per-tab fast path byte-for-byte. The grid is bounded at column XFD (16,384)
  and row 1,048,576 (the Excel limits); a ref beyond either bound is `#REF!`.

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
      integer (`INT(-1.5)` is `-2`). Also `MOD` (the result takes the
      DIVISOR's sign; `MOD(x, 0)` is `#DIV/0!`), `POWER` (the `^` operator in
      function form), `SQRT` (negative is `#NUM!`), `PRODUCT` (strict-
      aggregate collection; no numeric input is `0`), `SIGN`,
      `CEILING`/`FLOOR` (round to a multiple of the significance, default 1,
      with Excel's sign rules — including the `CEILING(x,0)` = `0` vs
      `FLOOR(x,0)` = `#DIV/0!` asymmetry), `TRUNC` (alias of `ROUNDDOWN`),
      `LN`/`LOG` (default base 10; non-positive input `#NUM!`, base 1
      `#DIV/0!`) and `EXP` — every float path overflow-guards to `#NUM!`.
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
      (no args) and `NOW` (no args). The time side: `HOUR`/`MINUTE`/`SECOND`
      (a pure date reads midnight), `WEEKDAY` (types 1/2/3; 1 = Sun=1..Sat=7),
      and the month shifts `EDATE` (day clamps into a shorter month) and
      `EOMONTH` (the target month's last day) — outside year 0001..9999 is
      `#NUM!`.
    * Logic/info, continued — `XOR` (TRUE on an odd count of truthy values,
      AND/OR's coercion), `IFNA` (IFERROR for `#N/A` only), `COUNTBLANK`
      (empty cells of a range), `ISEVEN`/`ISODD` (truncate first; `#VALUE!`
      on text, errors propagate).
    * Reference — `ROW`/`COLUMN` (no argument: the formula's own cell; a
      ref/range argument: its top-left coordinate) and `ROWS`/`COLUMNS`
      (a range's dimensions). These read the argument's SHAPE, not its value.
    * Text formatting — `TEXT(value, pattern)` maps an Excel/Sheets
      number-format pattern onto the engine's `fmt` vocabulary and renders
      the class's canonical form (see the `TEXT` clause for the pattern
      table); plus `CHAR`/`CODE` (codepoint 1..255 / first-char codepoint)
      and the string formatters `DOLLAR(n, [dec])` and
      `FIXED(n, [dec], [no_commas])` (ties away from zero, negative `dec`
      rounds left of the decimal point).
    * Lookup, continued — `HLOOKUP` (`VLOOKUP`'s horizontal twin: scan the
      first ROW, answer `row_index` rows down, same approx/exact + `#N/A`
      logic) and the conditional extrema `MAXIFS`/`MINIFS` (SUMIFS' criteria
      machinery, target range first; no numeric match is `0`).
    * Math, continued — `SUMSQ` (sum of squares), `GCD`/`LCM` (arguments
      truncate, exact bignum-safe integer math; a negative argument is
      `#NUM!`, an LCM past the float64 range canonicalises to `#NUM!`).
    * Dates, continued — `DATEDIF(start, end, unit)` (units
      `Y M D MD YM YD`, case-insensitive; a bad unit or start > end is
      `#NUM!`), `WEEKNUM` (types 1/2 = Sunday/Monday week start, 21 = ISO),
      `DAYS(end, start)`, `TIME(h, m, s)` (the Excel fractional-day serial —
      `HOUR`/`MINUTE`/`SECOND` now read a numeric serial back), and the
      business-day pair `WORKDAY`/`NETWORKDAYS` (Sat/Sun weekends, optional
      holiday range; deduped, weekday-only subtraction).
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
    * Reference/array tier — `XLOOKUP(key, lookup_vec, return_vec,
      [if_not_found], [match_mode])`: both vectors 1-D (either orientation)
      and equal length, the hit's offset indexes the return vector; modes `0`
      exact (default), `-1`/`1` nearest-smaller/-larger over UNSORTED data,
      `2` wildcard; a miss answers the LAZY `if_not_found`, else `#N/A`.
      `SUMPRODUCT(range, …)` multiplies positionally-aligned cells across
      same-shape rectangles and sums (text/booleans/blanks count `0`; a shape
      mismatch or non-range argument is `#VALUE!`). `ADDRESS(row, col, [abs],
      [a1])` is pure string construction (`"$C$2"`; abs `1..4`, falsy `a1` →
      R1C1 style). `INDIRECT`/`OFFSET` stay out: a runtime-computed reference
      can't join the statically-collected dependency graph. (`TRANSPOSE` was in
      that exclusion list until spill shipped — it takes a LITERAL range, so its
      dependencies collect statically like any other; it now lives in the array
      tier below.)
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
    * `TRANSPOSE(range)` — the genuinely 2-D one: rows become columns. Where
      `UNIQUE`/`SORT`/`FILTER` flatten their source to a vector, `TRANSPOSE`
      reads a RECTANGULAR grid, keeps blanks, and keeps an element error IN
      PLACE (Excel transposes an error cell like any other value). An empty
      source is `#VALUE!` and a result past the array cap is `#NUM!`.
    * `VSTACK(range…)` / `HSTACK(range…)` — append grids down / across. A
      ragged edge pads with `#N/A` (Excel), and those pads are GENERATED
      element values — distinct from a source error, which rides through in
      place. An argument that materialises to nothing contributes nothing;
      all-empty is `#VALUE!`, past the cap is `#NUM!`.

  Blanks inside the array are dropped exactly as an aggregate drops blank
  range cells; an error value anywhere in the source propagates, as it does
  from a range. Consumed by every aggregate (`SUM`/`COUNTA`/…), by `AND`/`OR`,
  and by `TEXTJOIN` with the same flatten rules those apply to a range today.
  The 2-D tier (`TRANSPOSE`/`VSTACK`/`HSTACK`) is the deliberate exception on
  both counts: dropping a blank or collapsing on an error would change the
  SHAPE, which is the only thing those three exist to preserve, so they keep
  blanks and element errors positioned and let the consumer apply its own rule.

  ## Aggregate selection and range-flattened text

    * `CONCAT(value…)` — `CONCATENATE`'s modern replacement: identical text
      coercion, but a RANGE or array argument is legal and flattens ROW-MAJOR
      (`CONCATENATE` keeps its legacy `#VALUE!`-on-a-range rule). Blank cells
      contribute `""` rather than being skipped — there is no delimiter to
      double up, which is precisely why `TEXTJOIN` carries an ignore-empty flag
      and `CONCAT` does not. An error in a source propagates; a result past
      Excel's 32,767-character cell limit is `#VALUE!`.
    * `SUBTOTAL(function_code, ref…)` — one of eleven aggregates chosen by
      code: `1` AVERAGE, `2` COUNT, `3` COUNTA, `4` MAX, `5` MIN, `6` PRODUCT,
      `7` STDEV, `8` STDEVP, `9` SUM, `10` VAR, `11` VARP; `101`-`111` are the
      same eleven. A code outside both bands is `#VALUE!`.

      **Two documented gaps, both structural, neither an oversight.** (1) In
      Excel the `101`-`111` band additionally skips MANUALLY HIDDEN rows; this
      engine has no row-visibility input at all, so `101`-`111` evaluate
      IDENTICALLY to `1`-`11`. (2) Excel also skips a nested `SUBTOTAL` found
      inside the referenced range, so stacked subtotals don't double-count;
      `ctx.formulas` carries only the COORDINATES of formula cells, never their
      formula text, so a nested `SUBTOTAL` is invisible here and IS counted.
      Closing either needs a new input to `recompute/1`, not a new clause.

      iex> cells = %{"A1" => %{"v" => 1}, "A2" => %{"v" => 2}, "A3" => %{"v" => 3},
      ...>   "B1" => %{"f" => "SUBTOTAL(9, A1:A3)"}, "B2" => %{"f" => "SUBTOTAL(109, A1:A3)"}}
      iex> cells = Barkpark.Plugins.Sheets.Engine.recompute(%{"tabs" => [%{"cells" => cells}]})
      ...>         |> get_in(["tabs", Access.at(0), "cells"])
      iex> {cells["B1"]["v"], cells["B2"]["v"]}
      {6, 6}

      iex> cells = %{"A1" => %{"v" => "a"}, "B1" => %{"v" => "b"}, "A2" => %{"v" => "c"}}
      iex> content = %{"tabs" => [%{"cells" => Map.put(cells, "D1", %{"f" => "CONCAT(A1:B2)"})}]}
      iex> Barkpark.Plugins.Sheets.Engine.recompute(content)
      ...> |> get_in(["tabs", Access.at(0), "cells", "D1", "v"])
      "abc"

  **Spill.** A formula whose TOP-LEVEL result is an array spills into a
  rows×cols rectangle anchored at the formula cell: the anchor keeps its `f`
  and gains `"spill" => self` + `"spill_dims"`, each neighbouring cell is an
  engine-owned marked cell (`v`/`t`/`"spill" => anchor`, no `f`), and a spill
  obstructed by existing content blocks WHOLE — the anchor becomes `#SPILL!`
  and nothing else is written (design §3.3). The anchor's own `"v"` is still
  the array's top-left, so `=A2` reads a spilled value and an array in a
  NESTED/scalar position (an arm of arithmetic, `SUM(UNIQUE(A1:A5))`) still
  intersects to its top-left element (Excel's legacy `@` semantics).

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

  Eight error values, written with `"t" => "e"`:

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
    * `#SPILL!` — a dynamic-array formula whose spill rectangle is obstructed
      by existing content (or would fall off the grid); nothing but the anchor
      is written.
    * `#NAME?` — a formula naming a function this engine does not implement,
      in a cell with NOTHING cached to fall back on (see the stale rule below).

  Errors propagate through references: a formula reading a cell whose value
  is an error yields that error. A literal cell whose `"v"` is one of the
  six error strings (or whose `"t"` is `"e"`) propagates the same way.

  A call to an UNKNOWN function splits on whether the cell has anything
  cached (main's ruling 2026-09-02 — import fidelity beats purity, and the
  loud style is the honesty):

    * NO cached `"v"` (a formula typed in the grid, or one edited to a name
      the engine lacks) — there is nothing honest to show, so the cell
      becomes `#NAME?` (`"t" => "e"`) and dependents propagate it like any
      other error. A plausible-looking blank behind a quiet dot was the bug.
    * A cached `"v"` (an xlsx import — Excel really computed that number)
      keeps rendering: `"v"`/`"t"` stay untouched and the cell gains
      `"stale" => true` PLUS `"stale_fn" => "FOO"`, the first unsupported
      name in formula order. Dependents read that cached value. Surfaces
      turn the pair into an ERROR-STYLED cell titled `not evaluated: FOO is
      not supported` — never a quiet dot.

  Any decisive recompute — a computed value or a computed error — clears both
  flags.

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
  edges), no per-cell rescans.

  Graph BUILD resolves a range dependency through a formula-position index
  (per column, rows sorted; built once per recompute in O(F log F)), so a
  range costs O(log F + hits) — never the rectangle, and never a scan of the
  formula set. Resolving the whole graph is therefore O(cells + edges + F log
  F). Before that index every range filtered the entire formula set, which
  made a document with one row-local `SUM(A_r:J_r)` per row cost O(n^2) to
  BUILD — quadratic on a workload whose evaluation is linear, and the reason
  a measured log-log sweep on that shape fitted k ~ 2.0 against this
  paragraph's promise.

  Range EVALUATION iterates min(rectangle, occupied cells).

  A formula whose own reads grow with the sheet is still quadratic and
  correctly so: `=SUM($A$1:A_r)` on every row reads Sum(r) cells by
  definition, in this engine and in Excel alike. `mix barkpark.sheets.bench`
  sweeps both families and labels which is which.

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
  alias Barkpark.Plugins.Sheets.Fmt

  # Excel grid bounds: column XFD, row 1_048_576.
  @max_col 16_384
  @max_row 1_048_576

  # Hard cap on the spill re-topo fixpoint (charter D3). Each phase widens spill
  # visibility by one dependency level, so a chain of depth d settles in d+1
  # phases; ten covers any realistic nesting. The loop is NOT provably monotone
  # (a pathological anchor could oscillate between #SPILL! and a region), so the
  # cap is load-bearing: on exhaustion recompute falls back to the last computed
  # map rather than hanging.
  @spill_max_phases 10

  # Guard on pure array generation (SEQUENCE): a rows*cols request beyond this
  # is #NUM!, so a fat-fingered SEQUENCE(1000000) can't materialise a runaway
  # intermediate list.
  @array_cap 100_000

  # Bound on WORKDAY's |days| walk (~380 years of workdays): past this is
  # #NUM!, mirroring @max_date_days' hang guard on date arithmetic.
  @max_workdays 100_000

  @functions ~w(SUM AVG AVERAGE MIN MAX COUNT COUNTA IF ROUND ABS
                AND OR NOT IFERROR ROUNDUP ROUNDDOWN INT
                LEN TRIM UPPER LOWER LEFT RIGHT MID CONCATENATE TEXTJOIN
                EXACT FIND SEARCH SUBSTITUTE REPLACE REPT PROPER VALUE
                ISBLANK ISNUMBER ISTEXT ISLOGICAL ISERROR ISERR ISNA
                CHOOSE SWITCH IFS
                DATE YEAR MONTH DAY TODAY NOW RAND RANDBETWEEN
                NA COUNTIF SUMIF AVERAGEIF
                VLOOKUP MATCH INDEX
                COUNTIFS SUMIFS AVERAGEIFS
                MEDIAN SMALL LARGE PERCENTILE QUARTILE
                MODE RANK VAR STDEV VARP STDEVP SPARKLINE
                UNIQUE SORT FILTER SEQUENCE COUNTUNIQUE
                MOD POWER SQRT PRODUCT SIGN CEILING FLOOR TRUNC LN LOG EXP
                HOUR MINUTE SECOND WEEKDAY EDATE EOMONTH
                XOR IFNA COUNTBLANK ISEVEN ISODD
                ROW COLUMN ROWS COLUMNS
                TEXT CHAR CODE DOLLAR FIXED HLOOKUP MAXIFS MINIFS
                SUMSQ GCD LCM DATEDIF WEEKNUM TIME DAYS WORKDAY NETWORKDAYS
                XLOOKUP SUMPRODUCT ADDRESS
                AVERAGEA MAXA MINA GEOMEAN HARMEAN MROUND QUOTIENT JOIN
                NUMBERVALUE CLEAN T N ISFORMULA TYPE DATEVALUE TIMEVALUE YEARFRAC
                TRANSPOSE CONCAT SUBTOTAL HSTACK VSTACK)
  @aggregates ~w(SUM AVG AVERAGE MIN MAX COUNT COUNTA)
  @cmp_ops [:eq, :ne, :lt, :le, :gt, :ge]
  @error_values ~w(#CYCLE! #REF! #VALUE! #DIV/0! #N/A #NUM! #SPILL! #NAME?)

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
  Machine-readable signatures for EVERY function in `function_names/0` — name,
  ordered args (each flagged `optional`/`variadic`) and a one-line Sheets-style
  doc. Formula-UX surfaces (autocomplete signature-help, ghost-suggest, the
  capabilities manifest) read THIS instead of re-deriving argument shapes. Kept
  in lockstep with `function_names/0` by a MapSet-equality drift test.
  """
  @spec function_specs() :: [
          %{
            name: String.t(),
            args: [%{name: String.t(), optional: boolean(), variadic: boolean()}],
            doc: String.t()
          }
        ]
  def function_specs do
    [
      fspec(
        "SUM",
        [farg("value1"), frest("value2")],
        "Returns the sum of a series of numbers or cells."
      ),
      fspec(
        "AVG",
        [farg("value1"), frest("value2")],
        "Returns the numerical average value in a dataset."
      ),
      fspec(
        "AVERAGE",
        [farg("value1"), frest("value2")],
        "Returns the numerical average value in a dataset."
      ),
      fspec(
        "MIN",
        [farg("value1"), frest("value2")],
        "Returns the minimum value in a numeric dataset."
      ),
      fspec(
        "MAX",
        [farg("value1"), frest("value2")],
        "Returns the maximum value in a numeric dataset."
      ),
      fspec(
        "COUNT",
        [farg("value1"), frest("value2")],
        "Counts the number of numeric values in a dataset."
      ),
      fspec(
        "COUNTA",
        [farg("value1"), frest("value2")],
        "Counts the number of non-empty values in a dataset."
      ),
      fspec(
        "IF",
        [farg("condition"), farg("value_if_true"), fopt("value_if_false")],
        "Returns one value if a condition is true and another if false."
      ),
      fspec(
        "ROUND",
        [farg("value"), fopt("places")],
        "Rounds a number to a given number of decimal places."
      ),
      fspec("ABS", [farg("value")], "Returns the absolute value of a number."),
      fspec(
        "AND",
        [farg("logical1"), frest("logical2")],
        "Returns true if all of the provided arguments are true."
      ),
      fspec(
        "OR",
        [farg("logical1"), frest("logical2")],
        "Returns true if any of the provided arguments is true."
      ),
      fspec("NOT", [farg("logical")], "Returns the opposite of a logical value."),
      fspec(
        "IFERROR",
        [farg("value"), farg("value_if_error")],
        "Returns the first argument unless it is an error, then the second."
      ),
      fspec(
        "ROUNDUP",
        [farg("value"), fopt("places")],
        "Rounds a number up, away from zero, to a number of places."
      ),
      fspec(
        "ROUNDDOWN",
        [farg("value"), fopt("places")],
        "Rounds a number down, toward zero, to a number of places."
      ),
      fspec("INT", [farg("value")], "Rounds a number down to the nearest integer."),
      fspec("LEN", [farg("text")], "Returns the number of characters in a text string."),
      fspec("TRIM", [farg("text")], "Removes leading, trailing and repeated spaces from text."),
      fspec("UPPER", [farg("text")], "Converts a string to uppercase."),
      fspec("LOWER", [farg("text")], "Converts a string to lowercase."),
      fspec(
        "LEFT",
        [farg("string"), fopt("num_chars")],
        "Returns a substring from the start of a string."
      ),
      fspec(
        "RIGHT",
        [farg("string"), fopt("num_chars")],
        "Returns a substring from the end of a string."
      ),
      fspec(
        "MID",
        [farg("string"), farg("start"), farg("length")],
        "Returns a segment of a string from a given position."
      ),
      fspec(
        "CONCATENATE",
        [farg("text1"), frest("text2")],
        "Joins several text strings into one string."
      ),
      fspec(
        "TEXTJOIN",
        [farg("delimiter"), farg("ignore_empty"), farg("text1"), frest("text2")],
        "Joins text with a delimiter, optionally skipping empty values."
      ),
      fspec(
        "EXACT",
        [farg("string1"), farg("string2")],
        "Tests whether two strings are identical (case-sensitive)."
      ),
      fspec(
        "FIND",
        [farg("search_for"), farg("text_to_search"), fopt("starting_at")],
        "Returns the position of a substring (case-sensitive)."
      ),
      fspec(
        "SEARCH",
        [farg("search_for"), farg("text_to_search"), fopt("starting_at")],
        "Returns the position of a substring (case-insensitive)."
      ),
      fspec(
        "SUBSTITUTE",
        [farg("text"), farg("search_for"), farg("replace_with"), fopt("occurrence")],
        "Replaces occurrences of a substring within text."
      ),
      fspec(
        "REPLACE",
        [farg("text"), farg("position"), farg("length"), farg("new_text")],
        "Replaces part of a string with new text by position."
      ),
      fspec(
        "REPT",
        [farg("text"), farg("number")],
        "Repeats a text string a given number of times."
      ),
      fspec("PROPER", [farg("text")], "Capitalizes the first letter of each word in a string."),
      fspec("VALUE", [farg("text")], "Converts a numeric text string into a number."),
      fspec("ISBLANK", [farg("value")], "Returns true if the referenced cell is empty."),
      fspec("ISNUMBER", [farg("value")], "Returns true if the value is a number."),
      fspec("ISTEXT", [farg("value")], "Returns true if the value is text."),
      fspec("ISLOGICAL", [farg("value")], "Returns true if the value is a boolean."),
      fspec("ISERROR", [farg("value")], "Returns true if the value is any error."),
      fspec("ISERR", [farg("value")], "Returns true if the value is any error except #N/A."),
      fspec("ISNA", [farg("value")], "Returns true if the value is the #N/A error."),
      fspec(
        "CHOOSE",
        [farg("index"), farg("choice1"), frest("choice2")],
        "Returns an element from a list by its index."
      ),
      fspec(
        "SWITCH",
        [farg("expression"), farg("case1"), farg("value1"), frest("case_or_default")],
        "Compares an expression against cases and returns the match."
      ),
      fspec(
        "IFS",
        [farg("condition1"), farg("value1"), frest("condition_value")],
        "Returns the value for the first condition that is true."
      ),
      fspec(
        "DATE",
        [farg("year"), farg("month"), farg("day")],
        "Builds a date from year, month and day numbers."
      ),
      fspec("YEAR", [farg("date")], "Returns the year of a date."),
      fspec("MONTH", [farg("date")], "Returns the month of a date as a number."),
      fspec("DAY", [farg("date")], "Returns the day of the month of a date."),
      fspec("TODAY", [], "Returns the current date."),
      fspec("NOW", [], "Returns the current date and time."),
      fspec("RAND", [], "Returns a random number in [0, 1), fresh on each save."),
      fspec(
        "RANDBETWEEN",
        [farg("bottom"), farg("top")],
        "Returns a random integer between bottom and top, inclusive."
      ),
      fspec("NA", [], "Returns the #N/A error value."),
      fspec(
        "COUNTIF",
        [farg("range"), farg("criterion")],
        "Counts cells in a range that meet a criterion."
      ),
      fspec(
        "SUMIF",
        [farg("range"), farg("criterion"), fopt("sum_range")],
        "Sums cells in a range that meet a criterion."
      ),
      fspec(
        "AVERAGEIF",
        [farg("range"), farg("criterion"), fopt("average_range")],
        "Averages cells in a range that meet a criterion."
      ),
      fspec(
        "VLOOKUP",
        [farg("search_key"), farg("range"), farg("index"), fopt("is_sorted")],
        "Looks up a value in the first column and returns a row cell."
      ),
      fspec(
        "MATCH",
        [farg("search_key"), farg("range"), fopt("search_type")],
        "Returns the relative position of a value in a range."
      ),
      fspec(
        "INDEX",
        [farg("range"), farg("row"), fopt("column")],
        "Returns the cell at a row and column offset in a range."
      ),
      fspec(
        "COUNTIFS",
        [farg("criteria_range1"), farg("criterion1"), frest("criteria")],
        "Counts cells that meet multiple criteria."
      ),
      fspec(
        "SUMIFS",
        [farg("sum_range"), farg("criteria_range1"), farg("criterion1"), frest("criteria")],
        "Sums cells that meet multiple criteria."
      ),
      fspec(
        "AVERAGEIFS",
        [farg("average_range"), farg("criteria_range1"), farg("criterion1"), frest("criteria")],
        "Averages cells that meet multiple criteria."
      ),
      fspec(
        "MEDIAN",
        [farg("value1"), frest("value2")],
        "Returns the median value in a numeric dataset."
      ),
      fspec("SMALL", [farg("data"), farg("n")], "Returns the nth smallest value in a dataset."),
      fspec("LARGE", [farg("data"), farg("n")], "Returns the nth largest value in a dataset."),
      fspec(
        "PERCENTILE",
        [farg("data"), farg("percentile")],
        "Returns the value at a given percentile of a dataset."
      ),
      fspec(
        "QUARTILE",
        [farg("data"), farg("quartile")],
        "Returns the value at a given quartile of a dataset."
      ),
      fspec(
        "MODE",
        [farg("value1"), frest("value2")],
        "Returns the most frequently occurring value in a dataset."
      ),
      fspec(
        "RANK",
        [farg("value"), farg("data"), fopt("is_ascending")],
        "Returns the rank of a value within a dataset."
      ),
      fspec("VAR", [farg("value1"), frest("value2")], "Returns the variance of a sample."),
      fspec(
        "STDEV",
        [farg("value1"), frest("value2")],
        "Returns the standard deviation of a sample."
      ),
      fspec(
        "VARP",
        [farg("value1"), frest("value2")],
        "Returns the variance of an entire population."
      ),
      fspec(
        "STDEVP",
        [farg("value1"), frest("value2")],
        "Returns the standard deviation of an entire population."
      ),
      fspec(
        "SPARKLINE",
        [farg("range")],
        "Renders a miniature in-cell bar chart from a numeric range."
      ),
      fspec(
        "UNIQUE",
        [farg("range")],
        "Returns the unique rows in a range, discarding duplicates."
      ),
      fspec(
        "SORT",
        [farg("range"), fopt("is_ascending")],
        "Returns the values in a range sorted in order."
      ),
      fspec(
        "FILTER",
        [farg("range"), farg("condition")],
        "Returns the rows in a range that meet a condition."
      ),
      fspec(
        "SEQUENCE",
        [farg("rows"), fopt("columns"), fopt("start"), fopt("step")],
        "Generates a sequence of numbers as an array."
      ),
      fspec(
        "COUNTUNIQUE",
        [farg("value1"), frest("value2")],
        "Counts the number of unique values in a dataset."
      ),
      fspec(
        "TRANSPOSE",
        [farg("range")],
        "Flips a range's rows and columns."
      ),
      fspec(
        "VSTACK",
        [farg("range1"), frest("range2")],
        "Stacks ranges vertically, padding short rows with #N/A."
      ),
      fspec(
        "HSTACK",
        [farg("range1"), frest("range2")],
        "Stacks ranges horizontally, padding short columns with #N/A."
      ),
      fspec(
        "CONCAT",
        [farg("value1"), frest("value2")],
        "Joins the text of its arguments, ranges flattened row by row."
      ),
      fspec(
        "SUBTOTAL",
        [farg("function_code"), farg("range1"), frest("range2")],
        "Applies one of eleven aggregates, selected by a function code."
      ),
      fspec(
        "MOD",
        [farg("dividend"), farg("divisor")],
        "Returns the remainder after dividing two numbers."
      ),
      fspec("POWER", [farg("base"), farg("exponent")], "Raises a number to a power."),
      fspec("SQRT", [farg("value")], "Returns the positive square root of a number."),
      fspec(
        "PRODUCT",
        [farg("value1"), frest("value2")],
        "Returns the product of a series of numbers."
      ),
      fspec("SIGN", [farg("value")], "Returns the sign of a number as -1, 0 or 1."),
      fspec(
        "CEILING",
        [farg("value"), fopt("factor")],
        "Rounds a number up to the nearest multiple of a factor."
      ),
      fspec(
        "FLOOR",
        [farg("value"), fopt("factor")],
        "Rounds a number down to the nearest multiple of a factor."
      ),
      fspec(
        "TRUNC",
        [farg("value"), fopt("places")],
        "Truncates a number to a number of decimal places."
      ),
      fspec("LN", [farg("value")], "Returns the natural logarithm of a number."),
      fspec(
        "LOG",
        [farg("value"), fopt("base")],
        "Returns the logarithm of a number for a given base."
      ),
      fspec("EXP", [farg("value")], "Returns e raised to the power of a number."),
      fspec("HOUR", [farg("time")], "Returns the hour component of a time value."),
      fspec("MINUTE", [farg("time")], "Returns the minute component of a time value."),
      fspec("SECOND", [farg("time")], "Returns the second component of a time value."),
      fspec(
        "WEEKDAY",
        [farg("date"), fopt("type")],
        "Returns the day of the week of a date as a number."
      ),
      fspec(
        "EDATE",
        [farg("start_date"), farg("months")],
        "Returns a date a number of months from a start date."
      ),
      fspec(
        "EOMONTH",
        [farg("start_date"), farg("months")],
        "Returns the last day of the month a number of months away."
      ),
      fspec(
        "XOR",
        [farg("logical1"), frest("logical2")],
        "Returns true if an odd number of arguments are true."
      ),
      fspec(
        "IFNA",
        [farg("value"), farg("value_if_na")],
        "Returns the first argument unless it is #N/A, then the second."
      ),
      fspec("COUNTBLANK", [farg("range")], "Counts the number of empty cells in a range."),
      fspec("ISEVEN", [farg("value")], "Returns true if a number is even."),
      fspec("ISODD", [farg("value")], "Returns true if a number is odd."),
      fspec("ROW", [fopt("cell")], "Returns the row number of a cell reference."),
      fspec("COLUMN", [fopt("cell")], "Returns the column number of a cell reference."),
      fspec("ROWS", [farg("range")], "Returns the number of rows in a range."),
      fspec("COLUMNS", [farg("range")], "Returns the number of columns in a range."),
      fspec("TEXT", [farg("number"), farg("format")], "Formats a number using a format string."),
      fspec("CHAR", [farg("number")], "Returns the character for a Unicode code point."),
      fspec("CODE", [farg("string")], "Returns the Unicode code point of the first character."),
      fspec("DOLLAR", [farg("number"), fopt("decimals")], "Formats a number as currency text."),
      fspec(
        "FIXED",
        [farg("number"), fopt("decimals"), fopt("no_commas")],
        "Formats a number as text with fixed decimals."
      ),
      fspec(
        "HLOOKUP",
        [farg("search_key"), farg("range"), farg("index"), fopt("is_sorted")],
        "Looks up a value in the first row and returns a column cell."
      ),
      fspec(
        "MAXIFS",
        [farg("range"), farg("criteria_range1"), farg("criterion1"), frest("criteria")],
        "Returns the maximum of cells meeting multiple criteria."
      ),
      fspec(
        "MINIFS",
        [farg("range"), farg("criteria_range1"), farg("criterion1"), frest("criteria")],
        "Returns the minimum of cells meeting multiple criteria."
      ),
      fspec(
        "SUMSQ",
        [farg("value1"), frest("value2")],
        "Returns the sum of the squares of a series of numbers."
      ),
      fspec(
        "GCD",
        [farg("value1"), frest("value2")],
        "Returns the greatest common divisor of a set of integers."
      ),
      fspec(
        "LCM",
        [farg("value1"), frest("value2")],
        "Returns the least common multiple of a set of integers."
      ),
      fspec(
        "DATEDIF",
        [farg("start_date"), farg("end_date"), farg("unit")],
        "Returns the difference between two dates in a given unit."
      ),
      fspec(
        "WEEKNUM",
        [farg("date"), fopt("type")],
        "Returns the week number of the year for a date."
      ),
      fspec(
        "TIME",
        [farg("hour"), farg("minute"), farg("second")],
        "Builds a time value from hours, minutes and seconds."
      ),
      fspec(
        "DAYS",
        [farg("end_date"), farg("start_date")],
        "Returns the number of days between two dates."
      ),
      fspec(
        "WORKDAY",
        [farg("start_date"), farg("num_days"), fopt("holidays")],
        "Returns a date a number of working days away."
      ),
      fspec(
        "NETWORKDAYS",
        [farg("start_date"), farg("end_date"), fopt("holidays")],
        "Returns the number of working days between two dates."
      ),
      fspec(
        "XLOOKUP",
        [
          farg("search_key"),
          farg("lookup_range"),
          farg("result_range"),
          fopt("missing_value"),
          fopt("match_mode")
        ],
        "Searches a range and returns a matching result."
      ),
      fspec(
        "SUMPRODUCT",
        [farg("array1"), frest("array2")],
        "Returns the sum of products of corresponding array entries."
      ),
      fspec(
        "ADDRESS",
        [farg("row"), farg("column"), fopt("abs_num"), fopt("use_a1")],
        "Returns a cell reference as text from row and column numbers."
      ),
      fspec(
        "AVERAGEA",
        [farg("value1"), frest("value2")],
        "Averages values, counting text and booleans as numbers."
      ),
      fspec(
        "MAXA",
        [farg("value1"), frest("value2")],
        "Returns the maximum, counting text and booleans as numbers."
      ),
      fspec(
        "MINA",
        [farg("value1"), frest("value2")],
        "Returns the minimum, counting text and booleans as numbers."
      ),
      fspec(
        "GEOMEAN",
        [farg("value1"), frest("value2")],
        "Returns the geometric mean of a positive dataset."
      ),
      fspec(
        "HARMEAN",
        [farg("value1"), frest("value2")],
        "Returns the harmonic mean of a positive dataset."
      ),
      fspec(
        "MROUND",
        [farg("value"), farg("factor")],
        "Rounds a number to the nearest multiple of a factor."
      ),
      fspec(
        "QUOTIENT",
        [farg("dividend"), farg("divisor")],
        "Returns the integer result of a division."
      ),
      fspec(
        "JOIN",
        [farg("delimiter"), farg("value1"), frest("value2")],
        "Joins a list of values into text with a delimiter."
      ),
      fspec(
        "NUMBERVALUE",
        [farg("text"), fopt("decimal_separator"), fopt("group_separator")],
        "Converts locale-formatted number text into a number."
      ),
      fspec("CLEAN", [farg("text")], "Removes non-printable control characters from text."),
      fspec("T", [farg("value")], "Returns the argument if it is text, otherwise empty text."),
      fspec("N", [farg("value")], "Converts a value to a number."),
      fspec("ISFORMULA", [farg("cell")], "Returns true if a cell contains a formula."),
      fspec("TYPE", [farg("value")], "Returns a number describing the type of a value."),
      fspec("DATEVALUE", [farg("text")], "Converts a date string into a date value."),
      fspec("TIMEVALUE", [farg("text")], "Converts a time string into a time value."),
      fspec(
        "YEARFRAC",
        [farg("start_date"), farg("end_date"), fopt("basis")],
        "Returns the fraction of a year between two dates."
      )
    ]
  end

  defp fspec(name, args, doc), do: %{name: name, args: args, doc: doc}
  defp farg(name), do: %{name: name, optional: false, variadic: false}
  defp fopt(name), do: %{name: name, optional: true, variadic: false}
  defp frest(name), do: %{name: name, optional: true, variadic: true}

  @doc """
  The engine's error vocabulary — every `"#…!"` string a computed cell can
  hold. Surfaces that mark error cells (Studio's `sheet-err` class, the web
  grid, PortableDoc's html render) read THIS single list instead of hand-
  copying it, so a new code (e.g. `#NUM!`) lights up every surface at once.

  ## Where the mirrors are — ADD A CODE HERE, THEN UPDATE ALL OF THESE

  Surfaces that cannot call this function at runtime keep a local mirror. Each
  is held EQUAL to this list by a named test, so the duplication is a CHECKED
  invariant, never a silent fork:

    * `Barkpark.PortableDoc.Render.Walk` `@error_values` (`error_vocab/0`)
      — `api/test/barkpark/sheets_parity_test.exs`
    * `BarkparkWeb.Studio.SheetGrid.Cells` `@error_values` (`error_vocab/0`)
      — `api/test/barkpark/sheets_parity_test.exs`
    * `web/__tests__/fixtures/engine-errors.json` — the generated fixture the
      two TS surfaces read; `sheets_parity_test.exs` asserts it EQUALS this
      list, so regenerating it is step one of any vocabulary change
    * `web/lib/sheets.ts` `ENGINE_ERRORS` — `web/__tests__/sheets-errors.test.ts`
      (against the fixture above)
    * `js/packages/react/src/blocks/sheet.ts` `ERROR_VALUES` — the FIFTH mirror,
      unguarded until #15376; now
      `js/packages/react/tests/sheet-error-vocabulary.test.ts` (against the same
      fixture)

    * `apps/mobile/src/papers/portabledoc/blocks/sheet.tsx` `ERROR_VALUES` —
      the SIXTH mirror, unguarded until #15473, by which time it had already
      DRIFTED: #15374 added `#NAME?` to the list above and no one copied it
      into the mobile set, so a `#NAME?` cell rendered as ordinary text on
      mobile while every other surface painted it as an error. Now
      `apps/mobile/__tests__/sheetErrorVocabulary.test.ts` (against the same
      fixture, asserting set equality in both directions)

  Every mirror is now checked. A surface added here without a named drift test
  is the hole #15473 closed, reopened.
  """
  # @canonical capability:engine-error-vocabulary aka:error-codes,#NUM!,#DIV/0!,#SPILL!,#NAME?,name-error,unknown-function,stale_fn,spill,sheet-err,error_values
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
    name_index = tab_name_index(tabs)
    # ONE seed per recompute invocation, threaded into every cell's ctx so a
    # RAND/RANDBETWEEN draw is stable across all recompute phases within this
    # save (pure per {seed, tab, col, row}) yet fresh on the next.
    seed = rand_recompute_seed()

    if needs_unified?(tabs, name_index) do
      # Any cross-tab reference forces ONE unified {tab,col,row} graph over
      # every formula cell of every tab (CT-D4); cross-tab cycles fall out as
      # ordinary Kahn leftovers. See recompute_unified/4.
      recompute_unified(content, tabs, name_index, seed)
    else
      # Zero cross-tab references → the per-tab fast path, byte-for-byte the
      # legacy behaviour (each tab recomputed in isolation).
      new_tabs =
        tabs
        |> Enum.with_index()
        |> Enum.map(fn {tab, ti} -> recompute_tab(tab, ti, seed) end)

      Map.put(content, "tabs", new_tabs)
    end
  end

  def recompute(content), do: content

  # A fresh integer for each recompute/1 call: unique_integer guarantees a new
  # value on every call within the node (so two saves reseed and RAND is
  # volatile between them), system_time keeps it fresh across restarts.
  defp rand_recompute_seed do
    :erlang.unique_integer([:positive]) + :erlang.system_time(:nanosecond)
  end

  # One uniform draw in [0, 1), pure in the cell's identity: seed the exsss
  # generator (a **-scrambled algorithm, decorrelated on its first output) with
  # {seed, tab, cell} and take a single value. col/row fold into one integer —
  # row is grid-bounded (< 2_000_000) so the 3-int seed tuple stays unique per
  # cell — and :exsss_seed rejects a 4-tuple, hence the fold.
  defp rand_unit(seed, tab, col, row) do
    {v, _} = :rand.uniform_s(:rand.seed_s(:exsss, {seed, tab, col * 2_000_000 + row}))
    v
  end

  @doc false
  # Would recompute/1 take the unified cross-tab path? The regression lock in
  # engine_test.exs asserts this is FALSE for a zero-cross-tab document (the
  # fast path is provably taken). Not part of the public surface.
  @spec uses_cross_tab?(term()) :: boolean()
  def uses_cross_tab?(%{"tabs" => tabs}) when is_list(tabs),
    do: needs_unified?(tabs, tab_name_index(tabs))

  def uses_cross_tab?(_), do: false

  defp recompute_tab(%{"cells" => cells} = tab, ti, seed)
       when is_map(cells) and map_size(cells) > 0 do
    Map.put(tab, "cells", recompute_cells(cells, ti, seed))
  end

  defp recompute_tab(tab, _ti, _seed), do: tab

  # ── cross-tab routing ───────────────────────────────────────────────────────

  # Map every tab's (downcased) name to its 0-based index. Tab names are the
  # source of truth for cross-tab qualifiers (CT-D1, Excel-style); the internal
  # coordinate is the integer index. Excel sheet names are case-insensitive and
  # unique, so first-wins on a (degenerate) duplicate.
  defp tab_name_index(tabs) do
    tabs
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {tab, idx}, acc ->
      case tab do
        %{"name" => name} when is_binary(name) and name != "" ->
          Map.put_new(acc, String.downcase(name), idx)

        _ ->
          acc
      end
    end)
  end

  # A document needs the unified path iff some formula carries a `!` qualifier
  # that RESOLVES to a real tab (self OR other). The cheap `String.contains?`
  # guard keeps the common (no-`!`) document off the tokenizer entirely, so the
  # fast path pays only a substring scan per formula. An unresolvable `Foo!A1`
  # never triggers unified — the fast path degrades it to #REF! on its own.
  defp needs_unified?(tabs, name_index) do
    Enum.any?(tabs, fn tab ->
      case tab do
        %{"cells" => cells} when is_map(cells) ->
          Enum.any?(cells, fn
            {_addr, %{"f" => f}} when is_binary(f) ->
              String.contains?(f, "!") and formula_qualified?(f, name_index)

            _ ->
              false
          end)

        _ ->
          false
      end
    end)
  end

  # Does this formula tokenize to a tab-name qualifier that resolves in the
  # name index? (Detection only — the real parse happens in recompute_unified.)
  defp formula_qualified?(f, name_index) do
    src =
      case String.trim(f) do
        "=" <> rest -> rest
        other -> other
      end

    case tokenize(src, []) do
      {:ok, tokens} ->
        Enum.any?(tokens, fn
          {:tabname, name} -> Map.has_key?(name_index, String.downcase(name))
          _ -> false
        end)

      _ ->
        false
    end
  end

  # ── unified (cross-tab) recompute ───────────────────────────────────────────
  #
  # One {tab,col,row}-keyed dependency graph over every formula cell of every
  # tab. Node coordinate is the integer tab index; a bare ref carries its own
  # tab, a `Sheet2!A1` ref carries the resolved index. A single Kahn pass orders
  # cross-tab edges and detects cross-tab cycles as residual-in-degree leftovers
  # (no new cycle algorithm — the per-tab rule generalises for free).

  defp recompute_unified(content, tabs, name_index, seed) do
    # Gather, across ALL tabs: per-tab occupied sets, a global {tab,col,row}
    # value map (literals), and the parsed formula nodes.
    {occupied, values, parsed} =
      tabs
      |> Enum.with_index()
      |> Enum.reduce({%{}, %{}, %{}}, fn {tab, ti}, {occ, vals, par} ->
        case tab do
          %{"cells" => cells} when is_map(cells) and map_size(cells) > 0 ->
            entries =
              for {addr, cell} <- cells, is_map(cell), reduce: [] do
                acc ->
                  case Sheets.parse_ref(addr) do
                    {:ok, {c, r}} -> [{addr, {c, r}, cell} | acc]
                    :error -> acc
                  end
              end

            occ_t = MapSet.new(entries, fn {_addr, cr, _cell} -> cr end)

            vals_t =
              Map.new(entries, fn {_addr, {c, r}, cell} -> {{ti, c, r}, literal_value(cell)} end)

            par_t =
              for {addr, {c, r}, %{"f" => f}} <- entries, is_binary(f), into: %{} do
                {{ti, c, r}, {ti, addr, parse_formula(f, name_index)}}
              end

            {Map.put(occ, ti, occ_t), Map.merge(vals, vals_t), Map.merge(par, par_t)}

          _ ->
            {Map.put(occ, ti, MapSet.new()), vals, par}
        end
      end)

    if parsed == %{} do
      content
    else
      node_asts =
        for {key, {ti, _addr, {:ok, ast, _pts, _rgs}}} <- parsed, into: %{} do
          {pts, rgs} = walk_qualified(ast, ti, {[], []})
          {key, {ast, pts, rgs}}
        end

      node_set = node_asts |> Map.keys() |> MapSet.new()
      {in_deg, out_edges} = build_graph_unified(node_asts, node_set)

      computed0 =
        Enum.reduce(parsed, %{}, fn {key, {_ti, _addr, result}}, acc ->
          case parse_error(result, Map.get(values, key)) do
            nil -> acc
            e -> Map.put(acc, key, e)
          end
        end)

      base = %{
        unified: true,
        values: values,
        occupied: occupied,
        formulas: parsed |> Map.keys() |> MapSet.new(),
        seed: seed
      }

      queue = for {key, 0} <- in_deg, do: key
      {computed, residual} = topo_unified(queue, computed0, in_deg, out_edges, node_asts, base)
      computed = mark_cycles(computed, residual)

      # N-phase spill fixpoint in the cross-tab graph, identical to the fast
      # path (charter D3): a spill inside a cross-tab document distributes and
      # its readers see the region, and a spill chain crossing tabs converges
      # instead of stalling one level per phase. Spill keys carry the tab index.
      recompute = fn base_k ->
        {c, residual} = topo_unified(queue, computed0, in_deg, out_edges, node_asts, base_k)
        mark_cycles(c, residual)
      end

      spill_of = fn c -> unified_spill_map(tabs, parsed, c) end

      computed = spill_fixpoint(computed, base, spill_of, recompute)

      write_back_unified(content, tabs, parsed, computed)
    end
  end

  # Collect a resolved AST's precedent nodes as {tab,col,row} triples — a bare
  # ref/range inherits `own` tab; a qualified one already carries its index.
  defp walk_qualified({:ref, {t, c, r}}, _own, {ps, rs}), do: {[{t, c, r} | ps], rs}
  defp walk_qualified({:ref, {c, r}}, own, {ps, rs}), do: {[{own, c, r} | ps], rs}

  defp walk_qualified({:range, {t, c1, r1}, {t, c2, r2}}, _own, {ps, rs}),
    do: {ps, [{{t, c1, r1}, {t, c2, r2}} | rs]}

  defp walk_qualified({:range, {c1, r1}, {c2, r2}}, own, {ps, rs}),
    do: {ps, [{{own, c1, r1}, {own, c2, r2}} | rs]}

  # Full-axis ranges (4-tuple) in the unified graph: strip the bounds tag. A
  # cross-tab `Sheet2!A:A` already carries its resolved index in both corners; a
  # bare `A:A` in a cross-tab document inherits the formula's own tab.
  defp walk_qualified({:range, {t, c1, r1}, {t, c2, r2}, _b}, _own, {ps, rs}),
    do: {ps, [{{t, c1, r1}, {t, c2, r2}} | rs]}

  defp walk_qualified({:range, {c1, r1}, {c2, r2}, _b}, own, {ps, rs}),
    do: {ps, [{{own, c1, r1}, {own, c2, r2}} | rs]}

  defp walk_qualified({:neg, x}, own, acc), do: walk_qualified(x, own, acc)

  defp walk_qualified({:binop, _op, l, r}, own, acc),
    do: walk_qualified(r, own, walk_qualified(l, own, acc))

  defp walk_qualified({:call, _name, args}, own, acc),
    do: Enum.reduce(args, acc, &walk_qualified(&1, own, &2))

  defp walk_qualified({:array_lit, rows}, own, acc),
    do: Enum.reduce(rows, acc, fn row, a -> Enum.reduce(row, a, &walk_qualified(&1, own, &2)) end)

  defp walk_qualified(_literal, _own, acc), do: acc

  defp build_graph_unified(node_asts, node_set) do
    index = build_pos_index_unified(MapSet.to_list(node_set))

    Enum.reduce(node_asts, {%{}, %{}}, fn {key, {_ast, pts, rgs}}, {in_deg, out} ->
      deps =
        pts
        |> Enum.filter(&MapSet.member?(node_set, &1))
        |> Kernel.++(range_node_deps_unified(rgs, index))
        |> Enum.uniq()

      in_deg = Map.put(in_deg, key, length(deps))
      out = Enum.reduce(deps, out, fn dep, o -> Map.update(o, dep, [key], &[key | &1]) end)
      {in_deg, out}
    end)
  end

  # Range deps hit the formula-position index of the range's OWN tab (never the
  # rectangle, never a full scan) — the per-tab guarantee, tab-qualified. An
  # absent tab has no index entry and contributes nothing.
  defp range_node_deps_unified(ranges, index) do
    Enum.flat_map(ranges, fn {{t, c1, r1}, {t, c2, r2}} ->
      case index do
        %{^t => tab_index} ->
          Enum.map(index_band(tab_index, c1, r1, c2, r2), fn {c, r} -> {t, c, r} end)

        _ ->
          []
      end
    end)
  end

  defp topo_unified([], computed, in_deg, _out, _node_asts, _base), do: {computed, in_deg}

  defp topo_unified([key | rest], computed, in_deg, out, node_asts, base) do
    {tab, c, r} = key
    {ast, _pts, _rgs} = Map.fetch!(node_asts, key)

    ctx = %{
      unified: true,
      tab: tab,
      computed: computed,
      values: base.values,
      occupied: base.occupied,
      formulas: base.formulas,
      self: {c, r},
      spill: Map.get(base, :spill),
      seed: base.seed
    }

    computed = Map.put(computed, key, eval(ast, ctx))

    {ready, in_deg} =
      out
      |> Map.get(key, [])
      |> Enum.reduce({[], in_deg}, fn dep, {ready, ind} ->
        ind = Map.update!(ind, dep, &(&1 - 1))
        if ind[dep] == 0, do: {[dep | ready], ind}, else: {ready, ind}
      end)

    topo_unified(ready ++ rest, computed, in_deg, out, node_asts, base)
  end

  defp write_back_unified(content, tabs, parsed, computed) do
    by_tab = Enum.group_by(parsed, fn {{t, _c, _r}, _v} -> t end)

    new_tabs =
      tabs
      |> Enum.with_index()
      |> Enum.map(fn {tab, ti} ->
        case tab do
          %{"cells" => cells} when is_map(cells) ->
            {new_cells, _spill} = distribute_tab(cells, Map.get(by_tab, ti, []), computed, ti)
            Map.put(tab, "cells", new_cells)

          _ ->
            tab
        end
      end)

    Map.put(content, "tabs", new_tabs)
  end

  # The cross-tab twin of the fast-path spill map: rebuild every tab's spill
  # region (from the SAME plan write_back_unified writes) into one {tab,col,row}
  # -keyed value map for phase-2 readers.
  defp unified_spill_map(tabs, parsed, computed) do
    by_tab = Enum.group_by(parsed, fn {{t, _c, _r}, _v} -> t end)

    tabs
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {tab, ti}, acc ->
      case tab do
        %{"cells" => cells} when is_map(cells) ->
          {_cells, spill} = distribute_tab(cells, Map.get(by_tab, ti, []), computed, ti)
          Map.merge(acc, spill)

        _ ->
          acc
      end
    end)
  end

  # One tab's write-back with spill distribution. `entries` are this tab's parsed
  # formula cells ({tab,col,row}-keyed). Returns {new_cells, spill_map} — the map
  # is {tab,col,row}-keyed so it merges into the unified phase-2 spill map.
  defp distribute_tab(cells, entries, computed, ti) do
    anchors =
      for {key, {_ti, addr, _result}} <- entries,
          spillable_array?(Map.get(computed, key)),
          do: {local_pos(key), addr, elem(Map.fetch!(computed, key), 1)}

    if anchors == [] and not has_spill_markers?(cells) do
      # No spill this tab, ever — the legacy byte-identical unified write.
      new =
        Enum.reduce(entries, cells, fn {key, {_ti, addr, result}}, acc ->
          if kept_stale?(result, computed, key) do
            Map.update!(acc, addr, &mark_unsupported(&1, elem(result, 1)))
          else
            Map.update!(acc, addr, &write_value(&1, Map.fetch!(computed, key)))
          end
        end)

      {new, %{}}
    else
      anchor_addrs = MapSet.new(anchors, fn {_p, a, _r} -> a end)

      base =
        entries
        |> Enum.reduce(strip_engine_spills(cells), fn {key, {_ti, addr, result}}, acc ->
          cond do
            MapSet.member?(anchor_addrs, addr) ->
              acc

            kept_stale?(result, computed, key) ->
              Map.update!(acc, addr, &mark_unsupported(&1, elem(result, 1)))

            true ->
              Map.update!(acc, addr, &write_value(&1, Map.fetch!(computed, key)))
          end
        end)

      distribute_anchors(base, anchors, fn {c, r} -> {ti, c, r} end)
    end
  end

  defp local_pos({_t, c, r}), do: {c, r}

  # ── recompute pipeline ──────────────────────────────────────────────────────

  defp recompute_cells(cells, tab_index, seed) do
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
      # No formulas: a document that once spilled but whose anchor was deleted
      # still carries engine spill cells — vacate them; otherwise pass through.
      if has_spill_markers?(cells), do: strip_engine_spills(cells), else: cells
    else
      node_asts =
        for {pos, {_addr, {:ok, ast, points, ranges}}} <- parsed, into: %{} do
          {pos, {ast, points, ranges}}
        end

      node_set = node_asts |> Map.keys() |> MapSet.new()
      {in_deg, out_edges} = build_graph(node_asts, node_set)

      computed0 =
        Enum.reduce(parsed, %{}, fn {pos, {_addr, result}}, acc ->
          case parse_error(result, Map.get(values, pos)) do
            nil -> acc
            e -> Map.put(acc, pos, e)
          end
        end)

      # `formulas` carries every formula-cell coordinate (valid, invalid or
      # stale parse alike) — ISFORMULA's single read.
      base = %{
        values: values,
        occupied: occupied,
        formulas: parsed |> Map.keys() |> MapSet.new(),
        seed: seed,
        tab: tab_index
      }

      queue = for {pos, 0} <- in_deg, do: pos
      {computed, residual} = topo(queue, computed0, in_deg, out_edges, node_asts, base)
      computed = mark_cycles(computed, residual)

      # N-phase spill fixpoint (design §3.3, charter D3): when a formula's
      # top-level result spills, re-topo with the materialised spill map visible
      # via cell_at until that map stops changing, so a reader (`=A2`) sees the
      # spilled value and — critically — a spill whose SOURCE is itself spilled
      # (`E1=SORT(C1:C3)` where `C1=SORT(A1:A3)`) converges instead of reading a
      # stale, one-level-behind region. Bounded — ONLY when array formulas are
      # present; a zero-array document never enters and stays single-pass
      # byte-identical (regression lock). Depth-1 settles in exactly one extra
      # phase, byte-identical to the prior two-phase engine.
      recompute = fn base_k ->
        {c, residual} = topo(queue, computed0, in_deg, out_edges, node_asts, base_k)
        mark_cycles(c, residual)
      end

      spill_of = fn c ->
        {_cells, spill} = spill_distribution(cells, parsed, c)
        spill
      end

      computed = spill_fixpoint(computed, base, spill_of, recompute)

      write_back(cells, parsed, computed)
    end
  end

  defp build_graph(node_asts, node_set) do
    index = build_pos_index(MapSet.to_list(node_set))

    Enum.reduce(node_asts, {%{}, %{}}, fn {pos, {_ast, points, ranges}}, {in_deg, out} ->
      deps =
        points
        |> Enum.filter(&MapSet.member?(node_set, &1))
        |> Kernel.++(range_node_deps(ranges, index))
        |> Enum.uniq()

      in_deg = Map.put(in_deg, pos, length(deps))
      out = Enum.reduce(deps, out, fn dep, o -> Map.update(o, dep, [pos], &[pos | &1]) end)
      {in_deg, out}
    end)
  end

  # Range deps hit the FORMULA-position index (§Complexity), never the
  # rectangle and never a full scan of the formula set: a binary search per
  # covered column yields only the formula positions actually inside the
  # rectangle, so one range costs O(log F + hits) instead of O(F). A SUM over a
  # million-cell range stays cheap AND n row-local SUMs stay O(n) in total.
  defp range_node_deps(ranges, index) do
    Enum.flat_map(ranges, fn {{c1, r1}, {c2, r2}} -> index_band(index, c1, r1, c2, r2) end)
  end

  # ── formula-position index (the §Complexity range bound) ────────────────────
  #
  # Built ONCE per recompute in O(F log F) and queried once per range. Shape:
  # `{cols, %{col => rows}}` where `cols` is a tuple of the distinct formula
  # columns in ascending order and each `rows` is a tuple of that column's
  # formula rows in ascending order. Tuples (not lists) because `elem/2` is
  # O(1), which is what makes the binary search a binary search.
  #
  # Before this index each range ran `Enum.filter` over the WHOLE formula set,
  # so a document with one row-local `SUM` per row cost O(ranges x formulas) =
  # O(n^2) to merely BUILD the graph — quadratic on a workload whose real work
  # is linear, and directly contrary to the O(cells + edges) contract above.

  defp build_pos_index(positions) do
    by_col =
      positions
      |> Enum.group_by(fn {c, _r} -> c end, fn {_c, r} -> r end)
      |> Map.new(fn {c, rows} -> {c, rows |> Enum.sort() |> List.to_tuple()} end)

    {by_col |> Map.keys() |> Enum.sort() |> List.to_tuple(), by_col}
  end

  # One index per tab, keyed by tab index; corners carry their tab, so a
  # cross-tab range never touches another tab's positions.
  defp build_pos_index_unified(keys) do
    keys
    |> Enum.group_by(fn {t, _c, _r} -> t end, fn {_t, c, r} -> {c, r} end)
    |> Map.new(fn {t, pairs} -> {t, build_pos_index(pairs)} end)
  end

  # Every indexed position inside the rectangle, as {col, row}. Cost:
  # O(log C + covered_cols x log R + hits) — bounded by the ANSWER, not by the
  # formula count and not by the rectangle area.
  defp index_band({cols, by_col}, c1, r1, c2, r2) do
    cols
    |> tuple_band(c1, c2)
    |> Enum.flat_map(fn c ->
      by_col |> Map.fetch!(c) |> tuple_band(r1, r2) |> Enum.map(&{c, &1})
    end)
  end

  # Ascending-sorted tuple -> the elements in [lo, hi], in order.
  defp tuple_band(t, lo, hi), do: take_band(t, lower_bound(t, lo), tuple_size(t), hi, [])

  # Smallest 1-based index i with elem(t, i - 1) >= v; tuple_size(t) + 1 if none.
  defp lower_bound(t, v), do: lower_bound(t, v, 1, tuple_size(t) + 1)

  defp lower_bound(_t, _v, lo, hi) when lo >= hi, do: lo

  defp lower_bound(t, v, lo, hi) do
    mid = div(lo + hi, 2)
    if elem(t, mid - 1) < v, do: lower_bound(t, v, mid + 1, hi), else: lower_bound(t, v, lo, mid)
  end

  defp take_band(_t, i, size, _hi, acc) when i > size, do: :lists.reverse(acc)

  defp take_band(t, i, size, hi, acc) do
    v = elem(t, i - 1)
    if v > hi, do: :lists.reverse(acc), else: take_band(t, i + 1, size, hi, [v | acc])
  end

  defp topo([], computed, in_deg, _out, _node_asts, _base), do: {computed, in_deg}

  defp topo([pos | rest], computed, in_deg, out, node_asts, base) do
    {ast, _points, _ranges} = Map.fetch!(node_asts, pos)
    # `self` is the formula's own coordinate — the no-arg ROW()/COLUMN() forms
    # read it; nothing else does.
    ctx = %{
      computed: computed,
      values: base.values,
      occupied: base.occupied,
      formulas: base.formulas,
      self: pos,
      spill: Map.get(base, :spill),
      seed: base.seed,
      tab: base.tab
    }

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

  # Kahn leftovers sit on a cycle or depend on one — both get #CYCLE!.
  defp mark_cycles(computed, in_deg) do
    Enum.reduce(in_deg, computed, fn
      {key, d}, acc when d > 0 -> Map.put(acc, key, err(:cycle))
      _other, acc -> acc
    end)
  end

  defp write_back(cells, parsed, computed) do
    # A document that spills this recompute, or still carries a stale region from
    # a prior one, takes the distribution path; everything else is byte-identical
    # to the legacy per-tab write.
    if any_array_result?(computed) or has_spill_markers?(cells) do
      {new_cells, _spill} = spill_distribution(cells, parsed, computed)
      new_cells
    else
      Enum.reduce(parsed, cells, fn {pos, {addr, result}}, acc ->
        if kept_stale?(result, computed, pos) do
          Map.update!(acc, addr, &mark_unsupported(&1, elem(result, 1)))
        else
          Map.update!(acc, addr, &write_value(&1, Map.fetch!(computed, pos)))
        end
      end)
    end
  end

  # ── spill distribution (dynamic arrays, design §3.3 / one-way-door §4.3) ─────
  #
  # A formula whose TOP-LEVEL result is a non-empty {:array, rows} spills into a
  # rows×cols rectangle anchored at the formula cell. The anchor keeps its `f`
  # + user style and gains `"spill" => self` + `"spill_dims"`; each non-anchor
  # spilled cell is a pure engine cell (`v`/`t`/`"spill" => anchor`, NO `f`, NO
  # style), re-derived every recompute (CT-D3). A spill obstructed by user
  # content — or overflowing the grid — blocks WHOLE: the anchor becomes
  # `#SPILL!` (CT-D4) and nothing else is written. output/1 still collapses a
  # NESTED/empty array to its top-left (scalarize/array_top_left consumers);
  # this write-back layer owns the top-level spill decision alone.

  defp spillable_array?({:array, [row | _]}) when is_list(row) and row != [], do: true
  defp spillable_array?(_), do: false

  defp any_array_result?(computed), do: Enum.any?(computed, fn {_k, v} -> spillable_array?(v) end)

  # The spill re-topo fixpoint shared by BOTH recompute paths (charter D3). The
  # zero-array guard is preserved here — a document with no top-level array
  # result never re-topos and stays single-pass byte-identical (regression
  # lock). Otherwise iterate { spill_k = spill_of(computed_k); computed_k+1 =
  # recompute(with_spill(base, spill_k)) } until the spill map stops changing.
  # `spill_of` and `recompute` are the per-path closures (fast: spill_distribution
  # + topo; unified: unified_spill_map + topo_unified), so ONE fixpoint drives
  # both — fixing only one path would silently leave cross-tab depth-2 broken.
  # Only the returned (final) computed map is written back, so a transient
  # #SPILL! from an intermediate phase is never persisted.
  defp spill_fixpoint(computed, base, spill_of, recompute) do
    if any_array_result?(computed) do
      converge_spill(computed, nil, base, spill_of, recompute, @spill_max_phases)
    else
      computed
    end
  end

  # Drive the fixpoint to a stable spill map or the hard cap. On `spill == prev`
  # the region has settled — return the current computed (its readers already saw
  # this exact map). On fuel exhaustion fall back to the last computed rather
  # than looping: the iteration is not provably monotone, so the cap guarantees
  # termination for any input.
  defp converge_spill(computed, _prev_spill, _base, _spill_of, _recompute, 0), do: computed

  defp converge_spill(computed, prev_spill, base, spill_of, recompute, fuel) do
    spill = spill_of.(computed)

    if spill == prev_spill do
      computed
    else
      base
      |> with_spill(spill)
      |> recompute.()
      |> converge_spill(spill, base, spill_of, recompute, fuel - 1)
    end
  end

  # Phase-2 base: expose the materialised spill map to cell_at AND fold the
  # spilled positions into the occupied set so a RANGE aggregate over a spill
  # region visits the engine-written cells (they were never in the stored
  # occupied set). Both keyed to match the ambient ctx (fast: {c,r}; unified:
  # {tab,c,r}).
  defp with_spill(base, spill) do
    base
    |> Map.put(:spill, spill)
    |> Map.put(:occupied, merge_spill_occupied(base.occupied, spill))
  end

  defp merge_spill_occupied(%MapSet{} = occ, spill),
    do: MapSet.union(occ, MapSet.new(Map.keys(spill)))

  defp merge_spill_occupied(occ, spill) when is_map(occ) do
    Enum.reduce(Map.keys(spill), occ, fn {t, c, r}, acc ->
      Map.update(acc, t, MapSet.new([{c, r}]), &MapSet.put(&1, {c, r}))
    end)
  end

  # Any cell still carrying a `"spill"` marker (anchor or engine-written). A
  # document that has EVER spilled takes the distribution path so a stale region
  # vacates even when nothing spills now (anchor deleted / edited to a scalar).
  defp has_spill_markers?(cells) do
    Enum.any?(cells, fn {_addr, cell} -> is_map(cell) and Map.has_key?(cell, "spill") end)
  end

  # Drop every engine-written non-anchor spill cell and strip stale
  # `"spill"`/`"spill_dims"` off surviving formula cells — the region is rebuilt
  # from scratch each recompute (design §3.3: engine-owned, never individually
  # undoable), so an old region can never linger past its anchor.
  defp strip_engine_spills(cells) do
    Enum.reduce(cells, %{}, fn {addr, cell}, acc ->
      cond do
        not is_map(cell) ->
          Map.put(acc, addr, cell)

        Map.has_key?(cell, "spill") and not Map.has_key?(cell, "f") ->
          acc

        Map.has_key?(cell, "spill") ->
          Map.put(acc, addr, cell |> Map.delete("spill") |> Map.delete("spill_dims"))

        true ->
          Map.put(acc, addr, cell)
      end
    end)
  end

  # Positions holding USER content (a literal value or a formula) in the stripped
  # map — the collision set. Engine spill cells are already gone, so a target
  # owned by THIS anchor last recompute reads empty here (writable, per §3.3).
  defp user_occupied(base) do
    for {addr, cell} <- base,
        is_map(cell),
        user_content?(cell),
        {:ok, pos} <- [Sheets.parse_ref(addr)],
        into: MapSet.new(),
        do: pos
  end

  defp user_content?(cell), do: Map.has_key?(cell, "f") or Map.get(cell, "v") not in [nil, ""]

  defp array_dims([first | _] = rows), do: {length(rows), length(first)}
  defp array_dims([]), do: {0, 0}

  # Fast-path (single-tab) spill write-back: strip prior regions, write the
  # scalar/stale results, distribute array anchors. Returns {new_cells,
  # spill_map} — the {col,row}-keyed map feeds phase-2 readers via cell_at.
  defp spill_distribution(cells, parsed, computed) do
    anchors =
      for {pos, {addr, _result}} <- parsed,
          spillable_array?(Map.get(computed, pos)),
          do: {pos, addr, elem(Map.fetch!(computed, pos), 1)}

    anchor_addrs = MapSet.new(anchors, fn {_pos, addr, _rows} -> addr end)

    base =
      parsed
      |> Enum.reduce(strip_engine_spills(cells), fn {pos, {addr, result}}, acc ->
        cond do
          MapSet.member?(anchor_addrs, addr) ->
            acc

          kept_stale?(result, computed, pos) ->
            Map.update!(acc, addr, &mark_unsupported(&1, elem(result, 1)))

          true ->
            Map.update!(acc, addr, &write_value(&1, Map.fetch!(computed, pos)))
        end
      end)

    distribute_anchors(base, anchors, & &1)
  end

  # The shared distribution core. `anchors` :: [{ {c,r}, addr, rows }] in tab-
  # local coordinates; `key_fun` maps a local pos onto the spill-map key ({c,r}
  # fast, {tab,c,r} unified). Anchors are processed in a stable row-major order
  # and a `claimed` set makes two anchors racing for one empty cell first-wins.
  defp distribute_anchors(base, anchors, key_fun) do
    occupied = user_occupied(base)
    anchors = Enum.sort_by(anchors, fn {{c, r}, _a, _rows} -> {r, c} end)

    {cells, spill, _claimed} =
      Enum.reduce(anchors, {base, %{}, MapSet.new()}, fn {{ac, ar} = apos, addr, rows},
                                                         {cacc, sacc, claimed} ->
        {nr, nc} = array_dims(rows)

        blocked? =
          ac + nc - 1 > @max_col or ar + nr - 1 > @max_row or
            Enum.any?(0..(nr - 1), fn i ->
              Enum.any?(0..(nc - 1), fn j ->
                t = {ac + j, ar + i}
                t != apos and (MapSet.member?(occupied, t) or MapSet.member?(claimed, t))
              end)
            end)

        if blocked? do
          {Map.update!(cacc, addr, &spill_error_cell/1),
           Map.put(sacc, key_fun.(apos), err(:spill)), claimed}
        else
          topleft = rows |> hd() |> hd()

          rows
          |> Enum.with_index()
          |> Enum.reduce({cacc, sacc, claimed}, fn {row, i}, outer ->
            row
            |> Enum.with_index()
            |> Enum.reduce(outer, fn {val, j}, {c2, s2, cl2} ->
              tpos = {ac + j, ar + i}
              taddr = Sheets.format_ref(tpos)
              anchor? = i == 0 and j == 0

              cell =
                if anchor? do
                  c2
                  |> Map.fetch!(addr)
                  |> write_value(topleft)
                  |> Map.put("spill", addr)
                  |> Map.put("spill_dims", [nr, nc])
                else
                  %{} |> write_value(val) |> Map.put("spill", addr)
                end

              {Map.put(c2, taddr, cell),
               Map.put(s2, key_fun.(tpos), if(anchor?, do: topleft, else: val)),
               MapSet.put(cl2, tpos)}
            end)
          end)
        end
      end)

    {cells, spill}
  end

  # A blocked anchor keeps its `f`/style, shows `#SPILL!`, and sheds any stale
  # region markers (nothing else is written — Excel's block-whole rule).
  defp spill_error_cell(cell) do
    cell |> write_value(err(:spill)) |> Map.delete("spill") |> Map.delete("spill_dims")
  end

  # A formula the engine cannot evaluate seeds the graph with its error BEFORE
  # the topo pass, so every dependent propagates it like a computed error
  # instead of reading around it:
  #
  #   :invalid                       → #REF!  (unparseable / unknown tab)
  #   {:stale, fn} and nothing cached → #NAME? (nothing honest to render)
  #   {:stale, fn} over a cached value → nil — the imported value stays
  #     authoritative, dependents keep reading it, and `mark_unsupported/2`
  #     makes the cell itself loud at write-back.
  #
  # `literal` is the cell's own pre-recompute value (`literal_value/1`);
  # `:blank` is exactly "no `v`, or an empty one".
  defp parse_error(:invalid, _literal), do: err(:ref)
  defp parse_error({:stale, _fn}, :blank), do: err(:name)
  defp parse_error(_result, _literal), do: nil

  # True for the one result the write-back must NOT write a value for: an
  # unsupported function over a cell that kept its cached value (so nothing was
  # seeded into `computed`). A `{:stale, _}` cell WITH a seeded #NAME? falls
  # through to the ordinary decisive write, which is what makes it an error
  # cell.
  defp kept_stale?({:stale, _fn}, computed, key), do: not is_map_key(computed, key)
  defp kept_stale?(_result, _computed, _key), do: false

  # The import-fidelity arm: keep `v`/`t` exactly as Excel computed them, but
  # say so LOUDLY — `stale => true` plus the name the engine could not
  # evaluate. Surfaces turn the pair into an error-styled cell titled
  # "not evaluated: FOO is not supported" (never a quiet dot).
  defp mark_unsupported(cell, fname) do
    cell |> Map.put("stale", true) |> Map.put("stale_fn", fname)
  end

  defp write_value(cell, value) do
    {v, t} = output(value)

    cell
    |> Map.put("v", v)
    |> Map.put("t", t)
    |> Map.delete("stale")
    |> Map.delete("stale_fn")
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
  # NOTE: output/1 stores integers up to 2^1024, so any NEW arithmetic site in
  # this module MUST go through safe_arith/divide (a bignum can reach it).
  defp output(v) when is_integer(v) and abs(v) >= @float_overflow_int,
    do: output({:error, "#NUM!"})

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
  # parse_formula/1 → {:ok, ast, points, ranges} | {:stale, fname} | :invalid
  #
  # `{:stale, fname}` carries the FIRST unsupported function name in formula
  # order — the write-back layer needs it to name the function in the cell's
  # "not evaluated" title, and the seeding layer needs the tag to tell an
  # unsupported call apart from an unparseable one.

  # The fast path parses with an EMPTY name index: a formula with no `!` is
  # unchanged, and any `!` qualifier is unresolvable → :invalid → #REF! (the
  # fast path only ever sees unknown-tab qualifiers; a resolvable one routes to
  # recompute_unified before we get here).
  defp parse_formula(f), do: parse_formula(f, %{})

  defp parse_formula(f, name_index) do
    src =
      case String.trim(f) do
        "=" <> rest -> rest
        other -> other
      end

    with {:ok, tokens} <- tokenize(src, []),
         {:ok, ast0} <- parse(tokens),
         {:ok, ast} <- resolve_tabs(ast0, name_index) do
      {points, ranges, fns} = walk(ast, {[], [], []})

      # `walk` prepends outermost-first, so reversing reads the formula
      # left-to-right: `FOO(BAR(1))` names FOO, the one a human typed.
      case Enum.find(Enum.reverse(fns), &(&1 not in @functions)) do
        nil -> {:ok, ast, points, ranges}
        unsupported -> {:stale, unsupported}
      end
    else
      _ -> :invalid
    end
  end

  # Resolve tab-name qualifiers (CT-D1). A `{:qref, name, {c,r}}` /
  # `{:qrange, name, p1, p2}` node names a tab in the formula STRING; here the
  # name becomes an integer index and the node becomes a plain 3-tuple ref/
  # range. An unknown name fails the whole formula (→ :invalid → #REF!). A name
  # that resolves to the formula's own tab is kept as a 3-tuple too — in the
  # unified graph a self-index reads the same tab, and a self-cycle
  # (`=Sheet1!A1` in A1) is a #CYCLE! like any other, matching Excel.
  defp resolve_tabs(ast, name_index) do
    {:ok, resolve_node(ast, name_index)}
  catch
    :unknown_tab -> :error
  end

  defp resolve_node({:qref, name, {c, r}}, ni), do: {:ref, {resolve_tab_name!(name, ni), c, r}}

  defp resolve_node({:qrange, name, {c1, r1}, {c2, r2}}, ni) do
    idx = resolve_tab_name!(name, ni)
    {:range, {idx, min(c1, c2), min(r1, r2)}, {idx, max(c1, c2), max(r1, r2)}}
  end

  # Tab-qualified full-axis range (`Sheet2!A:A` / `Sheet2!3:3`) — attach the
  # resolved index into both corners and carry the bounds tag forward.
  defp resolve_node({:qrange, name, {c1, r1}, {c2, r2}, bounds}, ni) do
    idx = resolve_tab_name!(name, ni)
    {:range, {idx, min(c1, c2), min(r1, r2)}, {idx, max(c1, c2), max(r1, r2)}, bounds}
  end

  defp resolve_node({:neg, x}, ni), do: {:neg, resolve_node(x, ni)}

  defp resolve_node({:binop, op, l, r}, ni),
    do: {:binop, op, resolve_node(l, ni), resolve_node(r, ni)}

  defp resolve_node({:call, name, args}, ni),
    do: {:call, name, Enum.map(args, &resolve_node(&1, ni))}

  defp resolve_node({:array_lit, rows}, ni),
    do: {:array_lit, Enum.map(rows, fn row -> Enum.map(row, &resolve_node(&1, ni)) end)}

  defp resolve_node(node, _ni), do: node

  defp resolve_tab_name!(name, ni) do
    case Map.fetch(ni, String.downcase(name)) do
      {:ok, idx} -> idx
      :error -> throw(:unknown_tab)
    end
  end

  defp walk({:ref, pos}, {ps, rs, fs}), do: {[pos | ps], rs, fs}
  defp walk({:range, p1, p2}, {ps, rs, fs}), do: {ps, [{p1, p2} | rs], fs}
  # Full-axis range (4-tuple): strip the bounds tag → feed the same {p1,p2} dep
  # so an A:A over its own column self-edges → #CYCLE! for free (no new code).
  defp walk({:range, p1, p2, _b}, {ps, rs, fs}), do: {ps, [{p1, p2} | rs], fs}
  defp walk({:neg, x}, acc), do: walk(x, acc)
  defp walk({:binop, _op, l, r}, acc), do: walk(r, walk(l, acc))

  defp walk({:call, name, args}, {ps, rs, fs}) do
    Enum.reduce(args, {ps, rs, [name | fs]}, &walk/2)
  end

  defp walk({:array_lit, rows}, acc) do
    Enum.reduce(rows, acc, fn row, a -> Enum.reduce(row, a, &walk/2) end)
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
  defp tokenize(<<"!", rest::binary>>, acc), do: tokenize(rest, [:bang | acc])
  # Array-literal delimiters (`={1,2;3,4}`): `{`/`}` bracket the literal, `;`
  # separates rows and `,` (the existing :comma) separates columns. Outside a
  # `{…}` the parser rejects them → #REF!, exactly as before they lexed.
  defp tokenize(<<"{", rest::binary>>, acc), do: tokenize(rest, [:lbrace | acc])
  defp tokenize(<<"}", rest::binary>>, acc), do: tokenize(rest, [:rbrace | acc])
  defp tokenize(<<";", rest::binary>>, acc), do: tokenize(rest, [:semi | acc])

  # A single-quoted tab name (Excel): `'My Sheet'!A1`, `'Q1 2026'!A1`, with
  # `''` escaping a literal apostrophe. Meaningful only before `!`; the parser
  # rejects a `{:tabname}` not followed by `:bang`.
  defp tokenize(<<?', rest::binary>>, acc) do
    case lex_quoted_name(rest, "") do
      {:ok, name, rest2} -> tokenize(rest2, [{:tabname, name} | acc])
      :error -> :error
    end
  end

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

  # `''` inside a quoted tab name is a literal apostrophe; a lone `'` closes it.
  defp lex_quoted_name(<<?', ?', rest::binary>>, acc), do: lex_quoted_name(rest, acc <> "'")
  defp lex_quoted_name(<<?', rest::binary>>, acc), do: {:ok, acc, rest}

  defp lex_quoted_name(<<c::utf8, rest::binary>>, acc),
    do: lex_quoted_name(rest, acc <> <<c::utf8>>)

  defp lex_quoted_name(<<>>, _acc), do: :error

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
      # A bare word immediately followed by `!` is a tab-name qualifier
      # (`Sheet2!A1`). Bare names must match `[A-Za-z_][A-Za-z0-9_]*` and NOT be
      # ref-shaped — a ref-shaped name (`A1!B2`) must be quoted (`'A1'!B2`), so
      # an unquoted one fails the grammar (→ :invalid → #REF!).
      next_is_bang?(rest) and bare_tab_name?(word) -> {:ok, {:tabname, word}, rest}
      next_is_bang?(rest) -> :error
      function_name?(word) and next_is_lparen?(rest) -> {:ok, {:ident, up}, rest}
      ref_like?(word) -> ref_token(word, rest)
      up in ["TRUE", "FALSE"] -> {:ok, {:bool, up == "TRUE"}, rest}
      # A bare letters-only word (`A`, `$A`, `AB`) that resolves to an in-bounds
      # column becomes a `{:colword}` — the lexeme a full-column range (`A:A`) is
      # built from. This clause sits BELOW the `SUM(`-style function clause (a
      # function name like `SUM` is ALSO a valid column, so only the `(`
      # lookahead separates `SUM(` the function from `SUM` the column) and below
      # TRUE/FALSE. A bare colword outside a `col:col` parser position has no
      # primary clause → :error → #REF! (byte-identical to a bare ident today).
      colword?(word) -> {:ok, {:colword, colword_col(word)}, rest}
      function_name?(word) -> {:ok, {:ident, up}, rest}
      true -> :error
    end
  end

  defp function_name?(word), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, word)
  defp ref_like?(word), do: Regex.match?(~r/^\$?[A-Za-z]+\$?[0-9]+$/, word)

  # A letters-only word (optional leading `$`) that resolves to an in-bounds
  # column — the raw material for a full-column range (`A:A`). Ref-shaped words
  # carry a trailing digit and are handled by `ref_like?`; a letters-only word
  # past XFD (a long function name used bare, or `TRUE`) is NOT a colword and
  # stays an ident/bool. Reuses `Sheets.parse_ref` (no hand-rolled base-26).
  defp colword?(word), do: colword_col(word) != nil

  defp colword_col(word) do
    if Regex.match?(~r/^\$?[A-Za-z]+$/, word) do
      case Sheets.parse_ref(String.replace(word, "$", "") <> "1") do
        {:ok, {col, _row}} when col <= @max_col -> col
        _ -> nil
      end
    end
  end

  # A bare tab name matches the identifier shape and is NOT a VALID in-bounds
  # cell reference (Excel). `Sheet2` reads as column "SHEET" (far past XFD) so
  # it is not a real ref → legal bare name; `A1`/`Q1` ARE real refs → must be
  # quoted (`'A1'!B2`). This is why the default `Sheet1`/`Sheet2` names work
  # unquoted while a sheet literally named `A1` does not.
  defp bare_tab_name?(word), do: function_name?(word) and not valid_ref?(word)

  defp valid_ref?(word) do
    ref_like?(word) and
      match?(
        {:ok, {c, r}} when c <= @max_col and r <= @max_row,
        Sheets.parse_ref(String.replace(word, "$", ""))
      )
  end

  defp next_is_lparen?(<<?\s, rest::binary>>), do: next_is_lparen?(rest)
  defp next_is_lparen?(<<?(, _::binary>>), do: true
  defp next_is_lparen?(_), do: false

  defp next_is_bang?(<<?!, _::binary>>), do: true
  defp next_is_bang?(_), do: false

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

  # Full-row range (`3:3`, `2:5`) → a row-bounded 4-tuple range spanning cols
  # 1..@max_col. This clause MUST sit ABOVE the bare `{:num}` literal clause
  # below — otherwise `3` in `3:3` is consumed as a literal and the dangling
  # `:colon` fails the parse. The row form is recognised ONLY in this
  # num:colon:num position (a bare `{:num}` stays a literal everywhere else) and
  # is guarded to in-bounds INTEGER rows — floats / out-of-range fall through to
  # the literal clause, leaving a dangling colon → #REF!.
  defp parse_primary([{:num, r1}, :colon, {:num, r2} | rest])
       when is_integer(r1) and is_integer(r2) and r1 >= 1 and r1 <= @max_row and
              r2 >= 1 and r2 <= @max_row do
    {:ok, {:range, {1, min(r1, r2)}, {@max_col, max(r1, r2)}, :row}, rest}
  end

  defp parse_primary([{:num, n} | rest]), do: {:ok, {:num, n}, rest}
  defp parse_primary([{:str, s} | rest]), do: {:ok, {:str, s}, rest}
  defp parse_primary([{:bool, b} | rest]), do: {:ok, {:bool, b}, rest}

  # Tab-qualified range (`Sheet2!A1:B5`) — ONE qualifier spans the whole range;
  # the tab name resolves to an index in resolve_tabs. A range whose two corners
  # name DIFFERENT tabs (`Sheet2!A1:Sheet3!B5`) never matches this clause: the
  # leftover `:colon` after the first qref fails the parse → #REF! (Excel).
  defp parse_primary([{:tabname, name}, :bang, {:ref, {c1, r1}}, :colon, {:ref, {c2, r2}} | rest]) do
    {:ok, {:qrange, name, {c1, r1}, {c2, r2}}, rest}
  end

  # Tab-qualified full-column range (`Sheet2!A:A`) / full-row range
  # (`Sheet2!3:3`) — the wave-1 `{:tabname},:bang` precedent carrying the wave-2
  # bounds tag. resolve_tabs attaches the resolved tab index into both corners.
  defp parse_primary([{:tabname, name}, :bang, {:colword, c1}, :colon, {:colword, c2} | rest]) do
    {:ok, {:qrange, name, {c1, 1}, {c2, @max_row}, :col}, rest}
  end

  defp parse_primary([{:tabname, name}, :bang, {:num, r1}, :colon, {:num, r2} | rest])
       when is_integer(r1) and is_integer(r2) and r1 >= 1 and r1 <= @max_row and
              r2 >= 1 and r2 <= @max_row do
    {:ok, {:qrange, name, {1, r1}, {@max_col, r2}, :row}, rest}
  end

  # Tab-qualified single ref (`Sheet2!A1`).
  defp parse_primary([{:tabname, name}, :bang, {:ref, pos} | rest]) do
    {:ok, {:qref, name, pos}, rest}
  end

  # Full-column range (`A:A`, `$A:$C`) → a col-bounded range spanning rows
  # 1..@max_row; full-row range (`3:3`, `2:5`) → a row-bounded range spanning
  # cols 1..@max_col. The `bounds` tag (`:col`/`:row`) rides a 4-tuple range
  # node so Structure/F4 can tell a full-axis range from a coincidental one; eval
  # is unchanged because occupied_positions filters the used set (CT-D2 — A:A is
  # never a stored rect). The row form is recognised ONLY in this num:colon:num
  # position (a bare `{:num}` stays a literal everywhere else) and is guarded to
  # in-bounds integer rows — floats / out-of-range fall through to #REF!.
  defp parse_primary([{:colword, c1}, :colon, {:colword, c2} | rest]) do
    {:ok, {:range, {min(c1, c2), 1}, {max(c1, c2), @max_row}, :col}, rest}
  end

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

  # Array literal (`={1;2;3}` col, `={1,2,3}` row, `={1,2;3,4}` grid) — `;` ends
  # a row, `,` a column (Excel). Elements are scalar expressions; the eval step
  # rejects a ragged (non-rectangular) literal as #VALUE!. An empty `{}` fails
  # the grammar (parse_cmp on `}` errors) → #REF!.
  defp parse_primary([:lbrace | rest]), do: parse_array_lit(rest, [], [])

  defp parse_primary(_tokens), do: :error

  defp parse_array_lit(tokens, cur, rows) do
    case parse_cmp(tokens) do
      {:ok, el, [:comma | rest]} ->
        parse_array_lit(rest, [el | cur], rows)

      {:ok, el, [:semi | rest]} ->
        parse_array_lit(rest, [], [Enum.reverse([el | cur]) | rows])

      {:ok, el, [:rbrace | rest]} ->
        {:ok, {:array_lit, Enum.reverse([Enum.reverse([el | cur]) | rows])}, rest}

      _ ->
        :error
    end
  end

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
  # A bare full-axis range (`=A:A` typed straight into a cell, no aggregate) is
  # #VALUE! too — the same non-scalar rule.
  defp eval({:range, _p1, _p2, _b}, _ctx), do: err(:value)

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

  # An array literal evaluates each scalar element (implicit intersection on any
  # nested array) into a rows-major {:array, rows} — the same value SORT/UNIQUE/
  # SEQUENCE produce, so it spills through the identical write-back path. A
  # ragged literal (rows of unequal width) is #VALUE!; an error element rides
  # through as that cell's value and propagates from an outer aggregate.
  defp eval({:array_lit, rows}, ctx) do
    evaled = Enum.map(rows, fn row -> Enum.map(row, &scalarize(eval(&1, ctx))) end)

    case evaled |> Enum.map(&length/1) |> Enum.uniq() do
      [_uniform_width] -> {:array, evaled}
      _ -> err(:value)
    end
  end

  # Cross-tab read (explicit tab) — hits the named tab's store no matter the
  # ambient ctx.tab. In the unified ctx `computed`/`values` are {tab,col,row}
  # keyed; a bare {col,row} inherits the formula's own tab (ctx.tab).
  defp cell_at({t, c, r}, %{unified: true} = ctx), do: fetch_cell({t, c, r}, ctx)
  defp cell_at({c, r}, %{unified: true} = ctx), do: fetch_cell({ctx.tab, c, r}, ctx)

  # Fast path — the per-tab store is keyed by {col,row}; byte-for-byte legacy.
  defp cell_at(pos, ctx), do: fetch_cell(pos, ctx)

  # A live spill region (phase 2 of a spill recompute) is visible here: a
  # reader of a spilled cell (`=A2`) or of an anchor read inside a range sees
  # the materialised SCALAR value, not the anchor's whole {:array}. Absent a
  # spill map (phase 1 and every zero-array document) this is the legacy read.
  defp fetch_cell(key, ctx) do
    case ctx do
      %{spill: spill} when is_map(spill) and is_map_key(spill, key) ->
        Map.fetch!(spill, key)

      _ ->
        case Map.fetch(ctx.computed, key) do
          {:ok, v} -> v
          :error -> Map.get(ctx.values, key, :blank)
        end
    end
  end

  # ISFORMULA's precedent test. The formula set is {col,row} keyed on the fast
  # path and {tab,col,row} keyed in the unified ctx; a same-tab {col,row} probe
  # inherits the ambient tab.
  defp formula_member?({c, r}, %{unified: true, tab: t} = ctx),
    do: MapSet.member?(ctx.formulas, {t, c, r})

  defp formula_member?(p1, ctx), do: MapSet.member?(ctx.formulas, p1)

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
    # safe_arith wraps the whole body: a stored BIGNUM base makes even the
    # :math.log2(abs(a)) magnitude probe overflow the float coercion — that is
    # #NUM!, not a crash. In-range Integer.pow results are unaffected.
    safe_arith(fn ->
      cond do
        a in [-1, 0, 1] -> Integer.pow(a, b)
        b <= 1024 and b * :math.log2(abs(a)) < 1024 -> Integer.pow(a, b)
        true -> power_float(a, b)
      end
    end)
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
  # Floats coerce through the shared 15-sig-digit General view — `="x"&3.0`
  # is "x3", never "x3.0"/"x2.0e6"/IEEE noise (Excel's text world is the
  # DISPLAY string). Flows through &, CONCATENATE/TEXTJOIN and eval_text.
  defp to_text(f) when is_float(f), do: Sheets.number_to_display(f)
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

  # XOR is TRUE when an ODD number of its coercible values are truthy — the
  # same argument coercion as AND/OR (ranges flatten keeping numbers/booleans,
  # an error propagates, zero coercible values is #VALUE!).
  defp call("XOR", args, ctx) when args != [] do
    case collect_bools(args, ctx, []) do
      {:error, _} = e -> e
      [] -> err(:value)
      bools -> rem(Enum.count(bools, & &1), 2) == 1
    end
  end

  # IFNA mirrors IFERROR but catches ONLY #N/A — every other error propagates.
  defp call("IFNA", [x, fallback], ctx) do
    case eval(x, ctx) do
      {:error, "#N/A"} -> eval(fallback, ctx)
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
      # An integer is already its own floor — and a stored bignum would raise
      # inside the :math.floor float coercion (mirror fn_round's int clause;
      # output/1 canonicalises an out-of-range result to #NUM!).
      n when is_integer(n) -> n
      n -> trunc(:math.floor(n))
    end
  end

  # MOD follows Excel: the result takes the DIVISOR's sign; MOD(x, 0) is
  # #DIV/0!. Integer pairs stay exact via Integer.mod (bignum-safe); the float
  # path goes through safe_arith (a bignum coercion overflow is #NUM!).
  defp call("MOD", [x, d], ctx) do
    case {eval_number(x, ctx), eval_number(d, ctx)} do
      {{:error, _} = e, _} -> e
      {_, {:error, _} = e} -> e
      {_n, divisor} when divisor == 0 -> err(:div0)
      {n, divisor} -> fn_mod(n, divisor)
    end
  end

  # POWER(b, e) is the ^ operator in function form — same overflow/domain
  # rules (power/2 already wraps safe_arith: 10^400 is #NUM!, not a raise).
  defp call("POWER", [b, e], ctx) do
    case {eval_number(b, ctx), eval_number(e, ctx)} do
      {{:error, _} = err_v, _} -> err_v
      {_, {:error, _} = err_v} -> err_v
      {base, exp} -> power(base, exp)
    end
  end

  defp call("SQRT", [x], ctx) do
    case eval_number(x, ctx) do
      {:error, _} = e -> e
      n when n < 0 -> err(:num)
      # A bignum arg overflows :math.sqrt's float coercion — #NUM!, not a crash.
      n -> safe_arith(fn -> :math.sqrt(n) end)
    end
  end

  # PRODUCT multiplies with the strict-aggregate collection rules (range text
  # skipped, errors propagate); zero numeric inputs is 0 (Excel). A pure-int
  # product past 2^1024 canonicalises to #NUM! at the output boundary; a float
  # sibling overflows mid-fold under safe_arith.
  defp call("PRODUCT", args, ctx) when args != [] do
    case collect_agg_items(args, ctx, true, []) do
      {:error, _} = e -> e
      {:ok, []} -> 0
      {:ok, items} -> safe_arith(fn -> Enum.reduce(items, 1, &(&1 * &2)) end)
    end
  end

  defp call("SIGN", [x], ctx) do
    case eval_number(x, ctx) do
      {:error, _} = e -> e
      n when n > 0 -> 1
      n when n < 0 -> -1
      _zero -> 0
    end
  end

  defp call("CEILING", [x], ctx), do: call("CEILING", [x, {:num, 1}], ctx)

  defp call("CEILING", [x, sig], ctx) do
    case {eval_number(x, ctx), eval_number(sig, ctx)} do
      {{:error, _} = e, _} -> e
      {_, {:error, _} = e} -> e
      {n, s} -> fn_ceiling(n, s)
    end
  end

  defp call("FLOOR", [x], ctx), do: call("FLOOR", [x, {:num, 1}], ctx)

  defp call("FLOOR", [x, sig], ctx) do
    case {eval_number(x, ctx), eval_number(sig, ctx)} do
      {{:error, _} = e, _} -> e
      {_, {:error, _} = e} -> e
      {n, s} -> fn_floor(n, s)
    end
  end

  # TRUNC(x, [d]) truncates toward zero at d digits — exactly ROUNDDOWN.
  defp call("TRUNC", [x], ctx), do: call("ROUNDDOWN", [x, {:num, 0}], ctx)
  defp call("TRUNC", [x, d], ctx), do: call("ROUNDDOWN", [x, d], ctx)

  defp call("LN", [x], ctx) do
    case eval_number(x, ctx) do
      {:error, _} = e -> e
      n when n <= 0 -> err(:num)
      n -> safe_arith(fn -> :math.log(n) end)
    end
  end

  defp call("LOG", [x], ctx), do: call("LOG", [x, {:num, 10}], ctx)

  # LOG(x, [base]) defaults to base 10 (via :math.log10 so LOG(100) is exactly
  # 2.0). Excel's domain map: x<=0 or base<=0 is #NUM!, base 1 is #DIV/0!.
  defp call("LOG", [x, base], ctx) do
    case {eval_number(x, ctx), eval_number(base, ctx)} do
      {{:error, _} = e, _} -> e
      {_, {:error, _} = e} -> e
      {n, _b} when n <= 0 -> err(:num)
      {_n, b} when b <= 0 -> err(:num)
      {_n, b} when b == 1 -> err(:div0)
      {n, b} when b == 10 -> safe_arith(fn -> :math.log10(n) end)
      {n, b} -> safe_arith(fn -> :math.log(n) / :math.log(b) end)
    end
  end

  # EXP overflows the double range fast (e^710) — safe_arith degrades that
  # (and a bignum arg's float coercion) to #NUM! instead of raising.
  defp call("EXP", [x], ctx) do
    case eval_number(x, ctx) do
      {:error, _} = e -> e
      n -> safe_arith(fn -> :math.exp(n) end)
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

  # CONCAT(value…) — CONCATENATE's modern replacement: same text coercion, but a
  # RANGE or an intermediate array argument is legal and flattens ROW-MAJOR
  # (CONCATENATE's `#VALUE!`-on-a-range rule is the legacy behaviour Excel kept
  # for back-compat). Blank cells contribute "" (they are NOT skipped — there is
  # no delimiter to double up, which is exactly why TEXTJOIN has an ignore-empty
  # flag and CONCAT does not). An error anywhere in a source propagates, as it
  # does from a range. A result past Excel's 32,767-character cell limit is
  # #VALUE!.
  defp call("CONCAT", args, ctx) when args != [] do
    Enum.reduce_while(args, "", fn arg, acc ->
      case concat_texts(arg, ctx) do
        {:error, _} = e -> {:halt, e}
        texts -> {:cont, acc <> Enum.join(texts)}
      end
    end)
    |> case do
      {:error, _} = e -> e
      s when is_binary(s) -> if String.length(s) > 32_767, do: err(:value), else: s
    end
  end

  defp call("TEXTJOIN", [delim_ast, ignore_ast | rest], ctx) when rest != [] do
    with delim when is_binary(delim) <- eval_text(delim_ast, ctx),
         {:ok, ignore?} <- bool_arg(ignore_ast, ctx),
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

  # COUNTBLANK counts a range's EMPTY cells: never-written positions plus
  # occupied cells holding "" — the exact complement of the non-blank reads.
  # An error cell is non-blank (and, uniquely for a range read, never
  # propagates: the cell is merely classified).
  defp call("COUNTBLANK", [range_ast], ctx) do
    case as_range(range_ast) do
      :error ->
        err(:value)

      {:ok, p1, p2} ->
        nonblank = Enum.count(occupied_positions(p1, p2, ctx), &(cell_at(&1, ctx) != :blank))
        rect_area(p1, p2) - nonblank
    end
  end

  # ISEVEN/ISODD truncate toward zero first (Excel: ISEVEN(2.5) is TRUE) and —
  # unlike the IS* classifiers above — DO propagate errors and #VALUE! on text.
  defp call("ISEVEN", [x], ctx), do: even_odd(x, ctx, 0)
  defp call("ISODD", [x], ctx), do: even_odd(x, ctx, 1)

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

  # RAND/RANDBETWEEN are volatile-as-of-last-save (see moduledoc): the draw is a
  # PURE function of the per-recompute seed and the cell's own {tab, col, row},
  # so a multi-phase spill recompute yields the identical value in every phase
  # (no process-global :rand state), yet the next save reseeds. A single cell
  # carrying more than one volatile draw shares that one per-cell draw by design.
  defp call("RAND", [], ctx) do
    {c, r} = ctx.self
    rand_unit(ctx.seed, ctx.tab, c, r)
  end

  defp call("RANDBETWEEN", [lo_ast, hi_ast], ctx) do
    with lo when is_number(lo) <- eval_number(lo_ast, ctx),
         hi when is_number(hi) <- eval_number(hi_ast, ctx) do
      lo = trunc(lo)
      hi = trunc(hi)

      if lo > hi do
        err(:num)
      else
        {c, r} = ctx.self
        # min-clamp: for astronomically wide ranges (span near 2^53) the float
        # product `v * (hi - lo + 1)` can round UP to the span itself, which
        # would emit hi + 1 — clamp so the inclusive contract always holds.
        min(lo + trunc(rand_unit(ctx.seed, ctx.tab, c, r) * (hi - lo + 1)), hi)
      end
    else
      {:error, _} = e -> e
    end
  end

  # HOUR/MINUTE/SECOND read the time component the way YEAR/MONTH/DAY read the
  # date component; a pure date reads midnight (all three are 0).
  defp call("HOUR", [x], ctx), do: time_field(x, ctx, :hour)
  defp call("MINUTE", [x], ctx), do: time_field(x, ctx, :minute)
  defp call("SECOND", [x], ctx), do: time_field(x, ctx, :second)

  defp call("WEEKDAY", [x], ctx), do: call("WEEKDAY", [x, {:num, 1}], ctx)

  # WEEKDAY types: 1 (default) Sun=1..Sat=7, 2 Mon=1..Sun=7, 3 Mon=0..Sun=6.
  # Excel's exotic 11..17 variants are out of scope — an unsupported type is
  # #NUM! (a domain miss, not a type error).
  defp call("WEEKDAY", [x, type_ast], ctx) do
    with %Date{} = d <- eval_date(x, ctx),
         t when is_integer(t) <- weekday_type(type_ast, ctx) do
      dow = Date.day_of_week(d)

      case t do
        1 -> rem(dow, 7) + 1
        2 -> dow
        3 -> dow - 1
      end
    else
      {:error, _} = e -> e
    end
  end

  defp call("EDATE", [date_ast, months_ast], ctx) do
    with %Date{} = d <- eval_date(date_ast, ctx),
         m when is_number(m) <- eval_number(months_ast, ctx) do
      shift_months(d, trunc(m), :clamp)
    else
      {:error, _} = e -> e
    end
  end

  defp call("EOMONTH", [date_ast, months_ast], ctx) do
    with %Date{} = d <- eval_date(date_ast, ctx),
         m when is_number(m) <- eval_number(months_ast, ctx) do
      shift_months(d, trunc(m), :eom)
    else
      {:error, _} = e -> e
    end
  end

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
      # A bignum item overflows the float coercion inside Enum.sum -> #NUM!.
      # Temporals sum as day serials (agg_serial), never silently drop to 0.
      {:ok, vals} -> safe_arith(fn -> vals |> Enum.map(&agg_serial/1) |> Enum.sum() end)
    end
  end

  defp call("AVERAGEIF", [range_ast, crit_ast], ctx),
    do: call("AVERAGEIF", [range_ast, crit_ast, range_ast], ctx)

  defp call("AVERAGEIF", [range_ast, crit_ast, sum_ast], ctx) do
    case sumif_values(range_ast, crit_ast, sum_ast, ctx) do
      {:error, _} = e ->
        e

      :error ->
        err(:value)

      {:ok, []} ->
        err(:div0)

      {:ok, vals} ->
        # Sum first under safe_arith (a bignum + float item raises inside
        # Enum.sum), then the exact-int divide keeps an even split precise.
        # Temporals average as day serials (agg_serial).
        case safe_arith(fn -> vals |> Enum.map(&agg_serial/1) |> Enum.sum() end) do
          {:error, _} = e -> e
          sum -> divide(sum, length(vals))
        end
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
      # Same bignum-in-Enum.sum overflow guard + temporal serials as SUMIF.
      {:ok, vals} -> safe_arith(fn -> vals |> Enum.map(&agg_serial/1) |> Enum.sum() end)
    end
  end

  defp call("AVERAGEIFS", [sum_ast | crit_args], ctx)
       when crit_args != [] and rem(length(crit_args), 2) == 0 do
    case sumifs_values(sum_ast, crit_args, ctx) do
      {:error, _} = e ->
        e

      :error ->
        err(:value)

      {:ok, []} ->
        err(:div0)

      {:ok, vals} ->
        # Same sum-under-safe_arith + exact-int divide split as AVERAGEIF.
        case safe_arith(fn -> vals |> Enum.map(&agg_serial/1) |> Enum.sum() end) do
          {:error, _} = e -> e
          sum -> divide(sum, length(vals))
        end
    end
  end

  # MAXIFS/MINIFS ride SUMIFS' criteria machinery (target range FIRST, then
  # range/criteria pairs, offset-space matched, one shared shape); no match
  # is 0 (Excel). Extrema order by agg_serial: an all-temporal collection
  # returns the extreme temporal itself (renders as a date, Sheets-style),
  # a mixed number+date collection compares via the day serial. Pure
  # max_by/min_by — no arithmetic, so bignums pass through exactly and
  # output/1 canonicalises any out-of-range one.
  defp call(name, [target_ast | crit_args], ctx)
       when name in ["MAXIFS", "MINIFS"] and crit_args != [] and
              rem(length(crit_args), 2) == 0 do
    case sumifs_values(target_ast, crit_args, ctx) do
      {:error, _} = e ->
        e

      :error ->
        err(:value)

      {:ok, []} ->
        0

      {:ok, vals} ->
        if name == "MAXIFS",
          do: Enum.max_by(vals, &agg_serial/1),
          else: Enum.min_by(vals, &agg_serial/1)
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
             flag when is_boolean(flag) <- lookup_range_flag(rest, ctx) do
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

  # HLOOKUP is VLOOKUP's horizontal twin: scan the range's FIRST row for the
  # key, answer from `row_index` rows below — same approx/exact + #N/A logic.
  defp call("HLOOKUP", [val_ast, range_ast, row_ast | rest], ctx)
       when rest == [] or length(rest) == 1 do
    case eval(val_ast, ctx) do
      {:error, _} = e ->
        e

      val ->
        with {:ok, {c1, r1}, {c2, r2}} <- as_range(range_ast),
             row_n when is_number(row_n) <- eval_number(row_ast, ctx),
             flag when is_boolean(flag) <- lookup_range_flag(rest, ctx) do
          n = trunc(row_n)

          cond do
            n < 1 -> err(:value)
            r1 + n - 1 > r2 -> err(:ref)
            true -> do_hlookup(val, r1, c1, c2, n, flag, ctx)
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

  # ── reference/array tier (batch 3) ──────────────────────────────────────
  #
  # Single-value forms only: the engine is one-value-per-cell, so anything
  # that would SPILL (TRANSPOSE, array-returning XLOOKUP) is out, and anything
  # whose reads escape its LITERAL range args (INDIRECT, OFFSET) is out too —
  # walk/2 collects dependencies statically at parse time, so a runtime-
  # computed reference would read stale topo state and dodge #CYCLE!.

  # XLOOKUP(key, lookup_vec, return_vec, [if_not_found], [match_mode]) — the
  # modern single-value lookup. Both vectors are 1-D (either orientation) and
  # equal length; the hit's offset in the lookup vector indexes the return
  # vector. Modes: 0 exact (default), -1 exact-or-next-smaller, 1 exact-or-
  # next-larger — nearest-neighbour searches valid on UNSORTED data, unlike
  # MATCH's sorted assumption — and 2 wildcard. A miss answers the LAZY
  # if_not_found AST (evaluated only on a miss), else #N/A.
  defp call("XLOOKUP", [key_ast, lookup_ast, return_ast | rest], ctx)
       when length(rest) <= 2 do
    case eval(key_ast, ctx) do
      {:error, _} = e ->
        e

      key ->
        with {:ok, l1, l2} <- as_range(lookup_ast),
             {:ok, s1, s2} <- as_range(return_ast),
             {:ok, cells, base} <- lookup_vector(l1, l2, ctx),
             {:ok, answer_at} <- return_vector(l1, l2, s1, s2),
             mode when is_integer(mode) <- xlookup_mode(rest, ctx) do
          case xlookup_find(key, mode, cells) do
            nil ->
              case rest do
                [nf_ast | _] -> eval(nf_ast, ctx)
                [] -> err(:na)
              end

            coord ->
              # A blank answer cell mirrors a plain ref: :blank → 0 at output.
              cell_at(answer_at.(coord - base), ctx)
          end
        else
          :error -> err(:value)
          {:error, _} = e -> e
        end
    end
  end

  # SUMPRODUCT(range, …) — multiply positionally-aligned cells across the
  # rectangles and sum the products: a scalar fold, no spill. Every argument
  # must be a ref/range of the FIRST argument's exact shape (#VALUE! otherwise
  # — Excel's silent resize would read cells the topo graph never registered).
  # Numbers participate; text/booleans/dates/blanks count 0, so only offsets
  # occupied in SOME range can contribute — the walk unions occupied offsets
  # and never expands the rectangle. An error anywhere propagates, even when
  # its aligned counterpart is blank. Products and the running sum fold under
  # safe_arith: a bignum×float coercion overflow is #NUM!, not a crash.
  defp call("SUMPRODUCT", args, ctx) when args != [] do
    rects = Enum.map(args, &as_range/1)

    if Enum.any?(rects, &(&1 == :error)) do
      err(:value)
    else
      [{f1, f2} | others] = rects = Enum.map(rects, fn {:ok, p1, p2} -> {p1, p2} end)

      if Enum.all?(others, fn {p1, p2} -> same_shape(f1, f2, p1, p2) == :ok end),
        do: sumproduct(rects, ctx),
        else: err(:value)
    end
  end

  # ADDRESS(row, col, [abs], [a1]) — pure string construction, no reference
  # machinery: abs 1 "$C$2", 2 "C$2", 3 "$C2", 4 "C2"; a falsy a1 flag renders
  # R1C1 style (absolute parts bare, relative parts bracketed). Out-of-grid
  # coordinates (bignums included — the bound check is exact integer math)
  # and an abs outside 1..4 are #VALUE!.
  defp call("ADDRESS", [row_ast, col_ast], ctx),
    do: call("ADDRESS", [row_ast, col_ast, {:num, 1}], ctx)

  defp call("ADDRESS", [row_ast, col_ast, abs_ast], ctx),
    do: call("ADDRESS", [row_ast, col_ast, abs_ast, {:bool, true}], ctx)

  defp call("ADDRESS", [row_ast, col_ast, abs_ast, a1_ast], ctx) do
    with rn when is_number(rn) <- eval_number(row_ast, ctx),
         cn when is_number(cn) <- eval_number(col_ast, ctx),
         an when is_number(an) <- eval_number(abs_ast, ctx),
         {:ok, a1?} <- bool_arg(a1_ast, ctx) do
      {row, col, abs_mode} = {trunc(rn), trunc(cn), trunc(an)}

      cond do
        row < 1 or row > @max_row or col < 1 or col > @max_col -> err(:value)
        abs_mode not in 1..4 -> err(:value)
        a1? -> a1_address(row, col, abs_mode)
        true -> r1c1_address(row, col, abs_mode)
      end
    else
      {:error, _} = e -> e
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
          # The pair sum itself can overflow (bignum int + float sibling), so
          # it goes under safe_arith; divide/2 then keeps an even-summing
          # integer pair exact.
          case safe_arith(fn -> Enum.at(nums, mid - 1) + Enum.at(nums, mid) end) do
            {:error, _} = e -> e
            sum -> divide(sum, 2)
          end
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

  # SUBTOTAL(function_code, ref1, …) — the eleven aggregates behind one code.
  # The whole point in Excel is the 1-11 / 101-111 split (101-111 additionally
  # skip MANUALLY HIDDEN rows) plus the rule that a nested SUBTOTAL inside a ref
  # is not counted twice. NEITHER is implementable here and both are DOCUMENTED
  # GAPS, not oversights (see the moduledoc): the engine has no row-visibility
  # input at all, and `ctx.formulas` carries only the COORDINATES of formula
  # cells — never their formula text — so a nested SUBTOTAL inside a range is
  # invisible to this clause and IS double-counted. Codes 1-11 and 101-111 are
  # therefore evaluated identically. A code outside both bands (or a text code)
  # is #VALUE!, as Excel does.
  defp call("SUBTOTAL", [code_ast | refs], ctx) when refs != [] do
    case eval_number(code_ast, ctx) do
      {:error, _} = e ->
        e

      n when is_number(n) ->
        case subtotal_target(trunc(n)) do
          nil -> err(:value)
          name -> call(name, refs, ctx)
        end

      _ ->
        err(:value)
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
          # A float start/step overflows the double range while generating
          # elements (e.g. 1.0e308 + 1.0e308) — #NUM!, not a crash.
          safe_arith(fn ->
            {:array, for(i <- 0..(nr - 1), do: for(j <- 0..(nc - 1), do: s + (i * nc + j) * st))}
          end)
      end
    else
      {:error, _} = e -> e
      _ -> err(:value)
    end
  end

  # TRANSPOSE(range | array) — flip rows and columns. Unlike UNIQUE/SORT/FILTER
  # (which flatten to a vector) this is genuinely 2-D, so it reads the argument
  # through `array_grid/2`: a rectangular, row-major grid that KEEPS blanks and
  # keeps element errors IN PLACE (Excel transposes an error cell like any other
  # value, and the spill writer types each element through `output/1`). An empty
  # source — an all-blank range has no occupied cells to bound a rectangle with
  # — is #VALUE!, and a result past the array cap is #NUM!.
  defp call("TRANSPOSE", [ast], ctx) do
    with {:ok, rows} <- array_grid(ast, ctx) do
      cond do
        rows == [] -> err(:value)
        grid_area(rows) > @array_cap -> err(:num)
        true -> {:array, Enum.zip_with(rows, & &1)}
      end
    end
  end

  # VSTACK(range…) / HSTACK(range…) — append grids along one axis. Excel pads a
  # ragged edge with #N/A, and those pads are GENERATED element values (they ride
  # into the spilled rectangle as error cells), distinct from a source error,
  # which propagates in place like every other array element. An argument that
  # materialises to nothing (an all-blank range) contributes no rows/columns;
  # all-empty is #VALUE!, and a result past the array cap is #NUM!.
  defp call("VSTACK", args, ctx) when args != [], do: stack(args, ctx, :vertical)

  defp call("HSTACK", args, ctx) when args != [], do: stack(args, ctx, :horizontal)

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

  # ── reference introspection (ROW / COLUMN / ROWS / COLUMNS) ────────────
  #
  # These read the argument's SHAPE (the raw ref/range AST), never its value; a
  # range answers with its top-left corner. The no-arg forms answer for the
  # formula's own cell (ctx.self). NOTE: `ROW(ref)` still registers a value
  # dependency on `ref` (walk/2 collects every ref), so a self-referencing
  # `ROW(A1)` in A1 reads #CYCLE! — the no-arg ROW() is the own-cell form.

  defp call("ROW", [], ctx), do: elem(ctx.self, 1)
  defp call("ROW", [arg], _ctx), do: ref_coord(arg, 1)
  defp call("COLUMN", [], ctx), do: elem(ctx.self, 0)
  defp call("COLUMN", [arg], _ctx), do: ref_coord(arg, 0)

  defp call("ROWS", [arg], _ctx) do
    case as_range(arg) do
      {:ok, {_c1, r1}, {_c2, r2}} -> r2 - r1 + 1
      :error -> err(:value)
    end
  end

  defp call("COLUMNS", [arg], _ctx) do
    case as_range(arg) do
      {:ok, {c1, _r1}, {c2, _r2}} -> c2 - c1 + 1
      :error -> err(:value)
    end
  end

  # ── text formatting (TEXT / CHAR / CODE / DOLLAR / FIXED) ─────────────

  # TEXT(value, pattern) renders `value` under an Excel/Sheets number-format
  # pattern by classifying the pattern onto the engine's `fmt` vocabulary with
  # the SAME classifier xlsx import uses (Fmt.classify_format/1), then
  # rendering with that class's canonical display rules (Fmt.display/2):
  #
  #     "0.00", "0.0#", …          → fixed      "1234.50"    (2dp, no grouping)
  #     "0%", "0.00%"              → percent    "25.00%"
  #     "$#,##0.00", "€…", "kr…"   → currency   "$1,234.50"  (sign outside $)
  #     "#,##0"                    → thousands  "1,234,567"
  #     "yyyy-mm-dd", "dd/mm/yyyy" → date       "2026-06-12" (canonical ISO)
  #     patterns with h (time)     → datetime   "2026-06-12 10:30:45"
  #
  # The rendering is the CLASS's canonical form, not a faithful re-layout of
  # the pattern (a "dd/mm/yyyy" date still comes out ISO). A pattern with no
  # class ("@", "General", "0") falls back to the general rendering — numbers
  # via Core.number_to_display, text verbatim, TRUE/FALSE — never a crash.
  defp call("TEXT", [val_ast, fmt_ast], ctx) do
    with fmt when is_binary(fmt) <- eval_text(fmt_ast, ctx),
         v when not is_tuple(v) <- scalarize(eval(val_ast, ctx)) do
      class = Fmt.classify_format(fmt)

      # Temporal values render through their ISO text form (Fmt's date
      # classes read the stored ISO strings); blank coerces to 0.
      v =
        cond do
          temporal?(v) -> to_text(v)
          v == :blank -> 0
          true -> v
        end

      # A float overflow inside a numeric class (e.g. 1.0e308 under "0%")
      # degrades to #NUM! instead of raising; bignum ints format exactly
      # (Fmt's decimal rendering is pure integer math).
      safe_arith(fn -> Fmt.display(v, class) end)
    else
      {:error, _} = e -> e
    end
  end

  # CHAR maps 1..255 to the codepoint (Latin-1 range); anything else —
  # including a truncated bignum — is #VALUE!.
  defp call("CHAR", [x], ctx) do
    case eval_number(x, ctx) do
      {:error, _} = e ->
        e

      n ->
        code = trunc(n)
        if code < 1 or code > 255, do: err(:value), else: <<code::utf8>>
    end
  end

  # CODE reads the FIRST character's codepoint (scalars coerce through the
  # text rule, so CODE(5) is 53); an empty string is #VALUE!.
  defp call("CODE", [s], ctx) do
    case eval_text(s, ctx) do
      {:error, _} = e -> e
      <<cp::utf8, _::binary>> -> cp
      _ -> err(:value)
    end
  end

  defp call("DOLLAR", [x], ctx), do: call("DOLLAR", [x, {:num, 2}], ctx)

  # DOLLAR(n, [dec]) — comma-grouped currency string in Fmt's sign-outside-$
  # convention ("-$1,234.57", not parentheses). A negative dec rounds left of
  # the decimal point (DOLLAR(1234.567, -2) is "$1,200").
  defp call("DOLLAR", [x, d], ctx) do
    case {eval_number(x, ctx), eval_number(d, ctx)} do
      {{:error, _} = e, _} -> e
      {_, {:error, _} = e} -> e
      {n, dec} -> money_string(n, trunc(dec))
    end
  end

  defp call("FIXED", [x], ctx), do: call("FIXED", [x, {:num, 2}], ctx)
  defp call("FIXED", [x, d], ctx), do: call("FIXED", [x, d, {:bool, false}], ctx)

  # FIXED(n, [dec], [no_commas]) — fixed-decimal string, comma-grouped unless
  # no_commas is truthy; ties round away from zero (Excel half-up).
  defp call("FIXED", [x, d, nc_ast], ctx) do
    with n when is_number(n) <- eval_number(x, ctx),
         dec when is_number(dec) <- eval_number(d, ctx),
         {:ok, no_commas?} <- bool_arg(nc_ast, ctx) do
      fixed_string(n, trunc(dec), not no_commas?)
    else
      {:error, _} = e -> e
    end
  end

  # ── math (SUMSQ / GCD / LCM) ──────────────────────────────────────────

  # SUMSQ collects with the strict-aggregate rules (range text skipped,
  # errors propagate); a pure-int bignum square canonicalises to #NUM! at the
  # output boundary and a float square overflows under safe_arith.
  defp call("SUMSQ", args, ctx) when args != [] do
    case collect_agg_items(args, ctx, true, []) do
      {:error, _} = e -> e
      {:ok, items} -> safe_arith(fn -> Enum.reduce(items, 0, fn v, acc -> acc + v * v end) end)
    end
  end

  # GCD/LCM truncate their arguments (Excel) and stay in exact integer math —
  # bignum-safe; an LCM past 2^1024 canonicalises to #NUM! at the output
  # boundary. A negative argument is #NUM!.
  defp call(name, args, ctx) when name in ["GCD", "LCM"] and args != [] do
    case collect_agg_items(args, ctx, true, []) do
      {:error, _} = e ->
        e

      {:ok, items} ->
        if Enum.any?(items, &(&1 < 0)) do
          err(:num)
        else
          ints = Enum.map(items, &trunc/1)

          if name == "GCD",
            do: Enum.reduce(ints, 0, &Integer.gcd/2),
            else: Enum.reduce(ints, 1, &lcm/2)
        end
    end
  end

  # ── dates (DATEDIF / WEEKNUM / TIME / DAYS) ───────────────────────────

  # DATEDIF(start, end, unit) — units "Y"/"M"/"D"/"MD"/"YM"/"YD",
  # case-insensitive. Start after end or an unknown unit is #NUM! (Excel).
  defp call("DATEDIF", [s_ast, e_ast, u_ast], ctx) do
    with %Date{} = s <- eval_date(s_ast, ctx),
         %Date{} = e <- eval_date(e_ast, ctx),
         u when is_binary(u) <- eval_text(u_ast, ctx) do
      if Date.compare(s, e) == :gt, do: err(:num), else: datedif(s, e, String.upcase(u))
    else
      {:error, _} = err_v -> err_v
    end
  end

  defp call("WEEKNUM", [x], ctx), do: call("WEEKNUM", [x, {:num, 1}], ctx)

  defp call("WEEKNUM", [x, type_ast], ctx) do
    with %Date{} = d <- eval_date(x, ctx),
         t when is_number(t) <- eval_number(type_ast, ctx) do
      weeknum(d, trunc(t))
    else
      {:error, _} = e -> e
    end
  end

  # TIME(h, m, s) → the Excel fractional-day serial (TIME(12,0,0) is 0.5).
  # Components truncate and roll over past a day; a negative total is #NUM!.
  # HOUR/MINUTE/SECOND read the serial back (serial_time_field/2).
  defp call("TIME", [h_ast, m_ast, s_ast], ctx) do
    with h when is_number(h) <- eval_number(h_ast, ctx),
         m when is_number(m) <- eval_number(m_ast, ctx),
         s when is_number(s) <- eval_number(s_ast, ctx) do
      total = trunc(h) * 3600 + trunc(m) * 60 + trunc(s)
      if total < 0, do: err(:num), else: divide(Integer.mod(total, 86_400), 86_400)
    else
      {:error, _} = e -> e
    end
  end

  # DAYS(end, start) — signed day count between two dates.
  defp call("DAYS", [e_ast, s_ast], ctx) do
    with %Date{} = e <- eval_date(e_ast, ctx),
         %Date{} = s <- eval_date(s_ast, ctx) do
      Date.diff(e, s)
    else
      {:error, _} = err_v -> err_v
    end
  end

  # ── business days (WORKDAY / NETWORKDAYS) ─────────────────────────────
  #
  # Weekends are Sat+Sun (Excel's default; the .INTL variants are out of
  # scope). `holidays` is an optional range/ref of date cells: temporal
  # values count (deduped), blanks and non-temporal values are ignored the
  # way aggregates skip text, and an error cell propagates.

  defp call("NETWORKDAYS", [s_ast, e_ast | rest], ctx) when length(rest) <= 1 do
    with %Date{} = s <- eval_date(s_ast, ctx),
         %Date{} = e <- eval_date(e_ast, ctx),
         {:ok, holidays} <- holiday_set(rest, ctx) do
      if Date.compare(s, e) == :gt,
        do: -networkdays(e, s, holidays),
        else: networkdays(s, e, holidays)
    else
      {:error, _} = err_v -> err_v
      :error -> err(:value)
    end
  end

  defp call("WORKDAY", [s_ast, days_ast | rest], ctx) when length(rest) <= 1 do
    with %Date{} = s <- eval_date(s_ast, ctx),
         d when is_number(d) <- eval_number(days_ast, ctx),
         {:ok, holidays} <- holiday_set(rest, ctx) do
      days = trunc(d)
      # Bound the walk the way @max_date_days bounds date+number arithmetic —
      # a huge/bignum day count is #NUM!, not a Session-freezing loop.
      if abs(days) > @max_workdays, do: err(:num), else: workday_walk(s, days, holidays)
    else
      {:error, _} = err_v -> err_v
      :error -> err(:value)
    end
  end

  # ── coverage batch 4: A-variants / means / math / text / info / date ──

  # The A-variant aggregates COERCE where the plain ones skip: text → 0,
  # TRUE → 1, FALSE → 0, a temporal → its Excel serial (a_coerce/1). Range
  # blanks still drop; an error cell propagates.
  defp call(name, args, ctx) when name in ["AVERAGEA", "MAXA", "MINA"] and args != [] do
    {:ok, items} = collect_agg_items(args, ctx, false, [])

    case Enum.find(items, &match?({:error, _}, &1)) do
      {:error, _} = e ->
        e

      nil ->
        nums = Enum.map(items, &a_coerce/1)

        case name do
          "AVERAGEA" -> aggregate("AVERAGE", nums)
          "MAXA" -> aggregate("MAX", nums)
          "MINA" -> aggregate("MIN", nums)
        end
    end
  end

  # GEOMEAN = product^(1/n), HARMEAN = n / sum(1/x). Both are defined only
  # over positive numbers — a zero/negative (or an empty input) is #NUM!.
  # The whole float body sits under safe_arith: a stored bignum overflows the
  # product/pow (or the 1/x) coercion and degrades to #NUM!, never a raise.
  defp call(name, args, ctx) when name in ["GEOMEAN", "HARMEAN"] and args != [] do
    case collect_agg_items(args, ctx, true, []) do
      {:error, _} = e ->
        e

      {:ok, []} ->
        err(:num)

      {:ok, nums} ->
        if Enum.any?(nums, &(&1 <= 0)) do
          err(:num)
        else
          n = length(nums)

          if name == "GEOMEAN",
            do: safe_arith(fn -> :math.pow(Enum.reduce(nums, 1, &(&1 * &2)), 1 / n) end),
            else: safe_arith(fn -> n / Enum.reduce(nums, 0, &(1 / &1 + &2)) end)
        end
    end
  end

  # MROUND(n, mult) — nearest multiple, half away from zero. mult 0 is 0;
  # opposite signs are #NUM! (Excel). fn_mround keeps integer pairs exact.
  defp call("MROUND", [x_ast, m_ast], ctx) do
    with n when is_number(n) <- eval_number(x_ast, ctx),
         m when is_number(m) <- eval_number(m_ast, ctx) do
      fn_mround(n, m)
    else
      {:error, _} = e -> e
    end
  end

  # QUOTIENT(a, b) — the integer part of the division, truncated toward zero.
  defp call("QUOTIENT", [a_ast, b_ast], ctx) do
    with a when is_number(a) <- eval_number(a_ast, ctx),
         b when is_number(b) <- eval_number(b_ast, ctx) do
      cond do
        b == 0 -> err(:div0)
        is_integer(a) and is_integer(b) -> div(a, b)
        true -> safe_arith(fn -> trunc_toward(a / b) end)
      end
    else
      {:error, _} = e -> e
    end
  end

  # JOIN(delim, values…) — Sheets' scalar join; exactly TEXTJOIN that keeps
  # empty strings (range blanks drop either way).
  defp call("JOIN", [delim_ast | rest], ctx) when rest != [],
    do: call("TEXTJOIN", [delim_ast, {:bool, false} | rest], ctx)

  # NUMBERVALUE(text[, dec_sep[, grp_sep]]) — parse locale-formatted number
  # text. Only each separator's FIRST character counts (Excel); equal or
  # empty separators are #VALUE!.
  defp call("NUMBERVALUE", [t_ast], ctx),
    do: call("NUMBERVALUE", [t_ast, {:str, "."}, {:str, ","}], ctx)

  defp call("NUMBERVALUE", [t_ast, dec_ast], ctx),
    do: call("NUMBERVALUE", [t_ast, dec_ast, {:str, ","}], ctx)

  defp call("NUMBERVALUE", [t_ast, dec_ast, grp_ast], ctx) do
    with t when is_binary(t) <- eval_text(t_ast, ctx),
         d when is_binary(d) <- eval_text(dec_ast, ctx),
         g when is_binary(g) <- eval_text(grp_ast, ctx) do
      numbervalue(t, String.first(d), String.first(g))
    else
      {:error, _} = e -> e
    end
  end

  # CLEAN(text) — strip the non-printable control range (codepoints 0–31).
  defp call("CLEAN", [s_ast], ctx) do
    case eval_text(s_ast, ctx) do
      {:error, _} = e -> e
      s -> for <<c::utf8 <- s>>, c > 31, into: "", do: <<c::utf8>>
    end
  end

  # T(value) — text passes through, anything else is "".
  defp call("T", [ast], ctx) do
    case scalarize(eval(ast, ctx)) do
      {:error, _} = e -> e
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  # N(value) — the numeric coercion table (shared with the A-variants):
  # number → itself, TRUE → 1, FALSE → 0, temporal → serial, text/blank → 0.
  defp call("N", [ast], ctx) do
    case scalarize(eval(ast, ctx)) do
      {:error, _} = e -> e
      v -> a_coerce(v)
    end
  end

  # ISFORMULA(ref) — does the referenced cell carry a formula? A range reads
  # its top-left; a non-reference argument is #VALUE!.
  defp call("ISFORMULA", [arg], ctx) do
    case as_range(arg) do
      {:ok, p1, _p2} -> formula_member?(p1, ctx)
      :error -> err(:value)
    end
  end

  # TYPE(value) — 1 number (blanks and temporals included), 2 text,
  # 4 boolean, 16 error (NOT propagated — the code IS the answer), 64 array.
  defp call("TYPE", [{:range, _p1, _p2}], _ctx), do: 64

  defp call("TYPE", [ast], ctx) do
    case eval(ast, ctx) do
      {:error, _} -> 16
      {:array, _rows} -> 64
      v when is_number(v) -> 1
      v when is_binary(v) -> 2
      v when is_boolean(v) -> 4
      _blank_or_temporal -> 1
    end
  end

  # DATEVALUE(text) — parse ISO-8601 date (or datetime, keeping the date
  # part) text into the engine's date vocabulary. The engine's temporals are
  # Date structs, not Excel serials, so this returns a Date — which is what
  # composes with YEAR/EDATE/… here (a raw serial would not).
  defp call("DATEVALUE", [ast], ctx) do
    case scalarize(eval(ast, ctx)) do
      {:error, _} = e ->
        e

      s when is_binary(s) ->
        case parse_temporal(String.trim(s)) do
          nil -> err(:value)
          t -> to_date(t)
        end

      _ ->
        err(:value)
    end
  end

  # TIMEVALUE(text) — parse "H:MM[:SS]" (or ISO datetime text, keeping the
  # time part) into the fractional-day serial, rolling over past a day the
  # way TIME/3 does. HOUR/MINUTE/SECOND read the serial back.
  defp call("TIMEVALUE", [ast], ctx) do
    case scalarize(eval(ast, ctx)) do
      {:error, _} = e -> e
      s when is_binary(s) -> timevalue(String.trim(s))
      _ -> err(:value)
    end
  end

  # YEARFRAC(start, end[, basis]) — the year fraction between two dates.
  # Bases: 0 US 30/360 (default), 1 actual/actual, 2 actual/360,
  # 3 actual/365, 4 European 30/360. Reversed dates swap (Excel); any other
  # basis is #NUM!.
  defp call("YEARFRAC", [s_ast, e_ast], ctx),
    do: call("YEARFRAC", [s_ast, e_ast, {:num, 0}], ctx)

  defp call("YEARFRAC", [s_ast, e_ast, b_ast], ctx) do
    with %Date{} = s <- eval_date(s_ast, ctx),
         %Date{} = e <- eval_date(e_ast, ctx),
         b when is_number(b) <- eval_number(b_ast, ctx) do
      {s, e} = if Date.compare(s, e) == :gt, do: {e, s}, else: {s, e}
      yearfrac(s, e, trunc(b))
    else
      {:error, _} = err_v -> err_v
    end
  end

  # Known function, wrong arity (and the unreachable unknown-name fallthrough).
  defp call(_name, _args, _ctx), do: err(:value)

  # ROW/COLUMN's coordinate read: a ref/range AST's top-left row (idx 1) or
  # column (idx 0); a non-ref argument is #VALUE!.
  defp ref_coord(arg, idx) do
    case as_range(arg) do
      {:ok, p1, _p2} -> elem(p1, idx)
      :error -> err(:value)
    end
  end

  defp truthy(b) when is_boolean(b), do: {:ok, b}
  defp truthy(n) when is_number(n), do: {:ok, n != 0}
  defp truthy(:blank), do: {:ok, false}
  defp truthy(_v), do: :error

  # Half away from zero (Excel/Erlang convention); n <= 0 keeps ints exact.
  # The scaled operand clamps to the 15-sig-digit decimal view (Core.sig15)
  # before rounding — 1.005*100 is 100.49999999999999 in IEEE, but Excel
  # rounds the DECIMAL 100.5, so ROUND(1.005,2) = 1.01, never 1.0.
  defp fn_round(x, n) when n >= 0 and is_integer(x), do: x
  defp fn_round(x, 0), do: round(x)

  defp fn_round(x, n) when n > 0 do
    # Cap the scale exponent: rounding a representable float beyond ~300 decimals
    # is a no-op, so a huge n need not build a giant bignum.
    p = Integer.pow(10, min(n, 300))
    safe_arith(fn -> round(Sheets.sig15(x * p)) / p end)
  end

  defp fn_round(x, n) do
    p = Integer.pow(10, min(-n, 300))
    safe_arith(fn -> round(Sheets.sig15(x / p)) * p end)
  end

  # ROUNDUP mirrors fn_round (same sig15 clamp on the scaled operand — a
  # +1-ulp scaling like 1.1*100 = 110.00000000000001 must not ceil an extra
  # step) but rounds away from zero at the scaled precision.
  defp fn_roundup(x, n) when n >= 0 and is_integer(x), do: x
  defp fn_roundup(x, 0), do: ceil_away(x)

  defp fn_roundup(x, n) when n > 0 do
    p = Integer.pow(10, min(n, 300))
    safe_arith(fn -> ceil_away(Sheets.sig15(x * p)) / p end)
  end

  defp fn_roundup(x, n) do
    p = Integer.pow(10, min(-n, 300))
    safe_arith(fn -> ceil_away(Sheets.sig15(x / p)) * p end)
  end

  # ROUNDDOWN mirrors fn_round (sig15: a -1-ulp scaling like 4.35*100 =
  # 434.99999999999994 must not trunc a step short) but rounds toward zero.
  defp fn_rounddown(x, n) when n >= 0 and is_integer(x), do: x
  defp fn_rounddown(x, 0), do: trunc_toward(x)

  defp fn_rounddown(x, n) when n > 0 do
    p = Integer.pow(10, min(n, 300))
    safe_arith(fn -> trunc_toward(Sheets.sig15(x * p)) / p end)
  end

  defp fn_rounddown(x, n) do
    p = Integer.pow(10, min(-n, 300))
    safe_arith(fn -> trunc_toward(Sheets.sig15(x / p)) * p end)
  end

  defp ceil_away(x) when x >= 0, do: trunc(:math.ceil(x))
  defp ceil_away(x), do: trunc(:math.floor(x))

  defp trunc_toward(x) when x >= 0, do: trunc(:math.floor(x))
  defp trunc_toward(x), do: trunc(:math.ceil(x))

  # MOD's divisor-sign rule. Integer pairs are exact (Integer.mod already
  # takes the divisor's sign, bignums included). The float path shifts
  # :math.fmod's dividend-signed remainder by the divisor when signs differ;
  # a bignum operand overflows the fmod coercion — #NUM! via safe_arith.
  defp fn_mod(n, d) when is_integer(n) and is_integer(d), do: Integer.mod(n, d)

  defp fn_mod(n, d) do
    safe_arith(fn ->
      r = :math.fmod(n, d)
      if r == 0 or r > 0 == d > 0, do: r, else: r + d
    end)
  end

  # LCM's pairwise step — exact integer math; 0 short-circuits (LCM(0, x) is
  # 0, and it also dodges Integer.gcd(0, 0) as a divisor).
  defp lcm(a, b) when a == 0 or b == 0, do: 0
  defp lcm(a, b), do: div(a * b, Integer.gcd(a, b))

  # CEILING/FLOOR round to a multiple of `sig`. Excel's rules: a positive x
  # with a negative sig is #NUM!; sig 0 is 0 for CEILING but #DIV/0! for FLOOR
  # (the classic asymmetry). Integer pairs stay exact via floor_div; the float
  # path goes through safe_arith (a bignum coercion overflow is #NUM!).
  defp fn_ceiling(_n, s) when s == 0, do: 0
  defp fn_ceiling(n, s) when n > 0 and s < 0, do: err(:num)
  defp fn_ceiling(n, s) when is_integer(n) and is_integer(s), do: -Integer.floor_div(-n, s) * s
  defp fn_ceiling(n, s), do: safe_arith(fn -> :math.ceil(n / s) * s end)

  defp fn_floor(_n, s) when s == 0, do: err(:div0)
  defp fn_floor(n, s) when n > 0 and s < 0, do: err(:num)
  defp fn_floor(n, s) when is_integer(n) and is_integer(s), do: Integer.floor_div(n, s) * s
  defp fn_floor(n, s), do: safe_arith(fn -> :math.floor(n / s) * s end)

  # ISEVEN/ISODD: truncate toward zero, then test the remainder's parity
  # (`want` 0 = even, 1 = odd). rem is exact on bignum integers.
  defp even_odd(ast, ctx, want) do
    case eval_number(ast, ctx) do
      {:error, _} = e -> e
      n -> abs(rem(trunc(n), 2)) == want
    end
  end

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

  # A boolean argument through the IF truthiness rule: {:ok, bool}, or the
  # propagated error. (TEXTJOIN's ignore-empty flag, FIXED's no_commas.)
  defp bool_arg(ast, ctx) do
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

  # date_field's time-side twin (HOUR/MINUTE/SECOND): a pure date has no time
  # component and reads midnight — 0 for all three fields. A NUMBER reads as
  # an Excel time serial (TIME/2 produces one).
  defp time_field(ast, ctx, field) do
    case eval(ast, ctx) do
      {:error, _} = e -> e
      %Date{} -> 0
      %DateTime{} = dt -> Map.fetch!(dt, field)
      %NaiveDateTime{} = ndt -> Map.fetch!(ndt, field)
      n when is_number(n) -> serial_time_field(n, field)
      _ -> err(:value)
    end
  end

  # The Excel time-serial read: a number's FRACTIONAL day is the time of day
  # (HOUR(0.75) is 18; an integer reads midnight, so HOUR(5) is 0). Negative
  # is #NUM!. A bignum int subtracts to an exact 0 (pure integer math); the
  # float path degrades any overflow to #NUM! under safe_arith.
  defp serial_time_field(n, _field) when n < 0, do: err(:num)

  defp serial_time_field(n, field) do
    case safe_arith(fn -> Integer.mod(round((n - trunc(n)) * 86_400), 86_400) end) do
      {:error, _} = e ->
        e

      secs ->
        case field do
          :hour -> div(secs, 3600)
          :minute -> secs |> rem(3600) |> div(60)
          :second -> rem(secs, 60)
        end
    end
  end

  # The DATE component of a temporal value, for the calendar functions
  # (WEEKDAY/EDATE/EOMONTH); anything non-temporal is #VALUE!.
  defp eval_date(ast, ctx) do
    case eval(ast, ctx) do
      {:error, _} = e -> e
      %Date{} = d -> d
      %DateTime{} = dt -> DateTime.to_date(dt)
      %NaiveDateTime{} = ndt -> NaiveDateTime.to_date(ndt)
      _ -> err(:value)
    end
  end

  defp weekday_type(ast, ctx) do
    case eval_number(ast, ctx) do
      {:error, _} = e -> e
      n -> if trunc(n) in [1, 2, 3], do: trunc(n), else: err(:num)
    end
  end

  # Month arithmetic for EDATE (:clamp — the day clamps into a shorter target
  # month) and EOMONTH (:eom — the target month's last day). Pure integer math,
  # so a bignum month offset can't raise; it just lands outside the year
  # 0001..9999 window, which is #NUM! (the same ceiling spirit as
  # @max_date_days on date+number arithmetic).
  defp shift_months(%Date{year: y, month: m, day: day}, months, mode) do
    total = y * 12 + (m - 1) + months
    ny = Integer.floor_div(total, 12)
    nm = Integer.mod(total, 12) + 1

    if ny < 1 or ny > 9999 do
      err(:num)
    else
      {:ok, probe} = Date.new(ny, nm, 1)
      last = Date.days_in_month(probe)
      {:ok, out} = Date.new(ny, nm, if(mode == :eom, do: last, else: min(day, last)))
      out
    end
  end

  # DATEDIF's fully-elapsed month count: calendar months minus one when the
  # end day hasn't reached the start day yet.
  defp full_months(s, e) do
    months = (e.year - s.year) * 12 + (e.month - s.month)
    if e.day >= s.day, do: months, else: months - 1
  end

  defp datedif(s, e, "D"), do: Date.diff(e, s)
  defp datedif(s, e, "M"), do: full_months(s, e)
  defp datedif(s, e, "Y"), do: div(full_months(s, e), 12)
  defp datedif(s, e, "YM"), do: rem(full_months(s, e), 12)

  # Days ignoring the whole months/years: the distance from start advanced by
  # the elapsed months (EDATE's clamp — always lands between s and e, so the
  # shift is provably in range and returns a %Date{}).
  defp datedif(s, e, "MD"), do: Date.diff(e, shift_months(s, full_months(s, e), :clamp))

  defp datedif(s, e, "YD"),
    do: Date.diff(e, shift_months(s, div(full_months(s, e), 12) * 12, :clamp))

  defp datedif(_s, _e, _unit), do: err(:num)

  # WEEKNUM types: 1 (default) weeks start Sunday, 2 Monday — both system 1
  # (week 1 is the week containing Jan 1) — and 21 the ISO week. Excel's
  # exotic 11..17 variants are out of scope: an unsupported type is #NUM!.
  defp weeknum(d, 1), do: week_of(d, 7)
  defp weeknum(d, 2), do: week_of(d, 1)

  defp weeknum(d, 21) do
    {_iso_year, week} = :calendar.iso_week_number({d.year, d.month, d.day})
    week
  end

  defp weeknum(_d, _type), do: err(:num)

  # System-1 week number: days-into-year plus Jan 1's offset from the week
  # start (`start_dow` in Date.day_of_week numbering: 7 = Sunday, 1 = Monday).
  defp week_of(d, start_dow) do
    {:ok, jan1} = Date.new(d.year, 1, 1)
    offset = Integer.mod(Date.day_of_week(jan1) - start_dow, 7)
    div(Date.day_of_year(d) - 1 + offset, 7) + 1
  end

  # Weekday count over the CLOSED interval [s, e] (s <= e), minus the distinct
  # weekday holidays inside it — closed form, never a day-by-day walk.
  defp networkdays(s, e, holidays) do
    n = Date.diff(e, s) + 1
    start_idx = Date.day_of_week(s) - 1

    extra =
      case rem(n, 7) do
        0 -> 0
        r -> Enum.count(0..(r - 1), fn i -> rem(start_idx + i, 7) < 5 end)
      end

    hol =
      Enum.count(holidays, fn d ->
        Date.day_of_week(d) <= 5 and Date.compare(d, s) != :lt and Date.compare(d, e) != :gt
      end)

    div(n, 7) * 5 + extra - hol
  end

  # Walk |days| working days from d (the start itself is uncounted; days 0
  # returns the start even on a weekend, as Excel does). Bounded by
  # @max_workdays at the call site; a result outside year 0001..9999 is #NUM!
  # (the EDATE window).
  defp workday_walk(d, 0, _holidays) do
    if d.year in 1..9999, do: d, else: err(:num)
  end

  defp workday_walk(d, remaining, holidays) do
    step = if remaining > 0, do: 1, else: -1
    next = Date.add(d, step)

    if Date.day_of_week(next) <= 5 and not MapSet.member?(holidays, next),
      do: workday_walk(next, remaining - step, holidays),
      else: workday_walk(next, remaining, holidays)
  end

  # WORKDAY/NETWORKDAYS' optional holidays argument: absent → the empty set;
  # a range/ref → its temporal cells as a deduped Date set (blanks and
  # non-temporal values are ignored, an error cell propagates); any other
  # argument → :error (#VALUE!).
  defp holiday_set([], _ctx), do: {:ok, MapSet.new()}

  defp holiday_set([ast], ctx) do
    case as_range(ast) do
      :error ->
        :error

      {:ok, p1, p2} ->
        vals = Enum.map(occupied_positions(p1, p2, ctx), &cell_at(&1, ctx))

        case Enum.find(vals, &match?({:error, _}, &1)) do
          {:error, _} = e -> e
          nil -> {:ok, vals |> Enum.filter(&temporal?/1) |> Enum.map(&to_date/1) |> MapSet.new()}
        end
    end
  end

  defp to_date(%Date{} = d), do: d
  defp to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp to_date(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt)

  defp collect_agg_items([], _ctx, _strict?, acc), do: {:ok, acc}

  # A full-axis range (`SUM(A:A)`, `COUNT(B:B)`, `SUM(3:3)`, `SUM(Sheet2!A:A)`)
  # aggregates exactly like a bounded one — strip the bounds tag and reuse the
  # 3-tuple path. This is where the wish's aggregates land (SUM/COUNT/AVERAGE
  # flow through collect_agg_items, NOT as_range).
  defp collect_agg_items([{:range, p1, p2, _b} | rest], ctx, strict?, acc),
    do: collect_agg_items([{:range, p1, p2} | rest], ctx, strict?, acc)

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
    {p1, p2, ctx} = localize_range(p1, p2, ctx)

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
    {p1, p2, ctx} = localize_range(p1, p2, ctx)
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
      top = length(@sparkline_ramp) - 1

      # A bignum value/span coerces past float64 in `hi - lo` or
      # `(v - lo) / span` and raises — the span subtraction itself already
      # blows up on a bignum-int/float mix, so it lives INSIDE the guard.
      # Fall back to #NUM! (propagated by the SPARKLINE caller).
      safe_arith(fn ->
        span = hi - lo

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
    {p1, p2, ctx} = localize_range(p1, p2, ctx)

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

  # ── 2-D array helpers (TRANSPOSE / HSTACK / VSTACK / CONCAT) ────────────────
  #
  # `array_grid/2` is the 2-D counterpart of `raw_flat`/`array_vector`: it
  # materialises an argument as a RECTANGULAR row-major grid instead of a
  # vector, so the shape survives (that is the whole point of TRANSPOSE and the
  # stackers). Blanks stay as the `:blank` sentinel and element errors stay in
  # place; only a whole-argument error (an unevaluable non-range AST) short-
  # circuits, matching how `eval` already reports one. An empty range answers
  # `{:ok, []}` — the caller decides whether that is #VALUE! or simply nothing
  # to append.

  defp array_grid({:range, p1, p2, _bounds}, ctx), do: array_grid({:range, p1, p2}, ctx)

  defp array_grid({:range, p1, p2}, ctx), do: {:ok, range_grid(p1, p2, ctx)}

  defp array_grid({:ref, pos}, ctx), do: {:ok, [[cell_at(pos, ctx)]]}

  defp array_grid(ast, ctx) do
    case eval(ast, ctx) do
      {:error, _} = e -> e
      {:array, rows} -> {:ok, rows}
      :blank -> {:ok, [[:blank]]}
      other -> {:ok, [[other]]}
    end
  end

  defp grid_width([]), do: 0
  defp grid_width([row | _]), do: length(row)

  defp grid_area(rows), do: length(rows) * grid_width(rows)

  # HSTACK/VSTACK's shared core. Empty grids drop out (nothing to append), a
  # ragged edge pads with #N/A, and the assembled rectangle is cap-checked.
  defp stack(args, ctx, axis) do
    grids = Enum.map(args, &array_grid(&1, ctx))

    case Enum.find(grids, &match?({:error, _}, &1)) do
      {:error, _} = e ->
        e

      nil ->
        case grids |> Enum.map(fn {:ok, g} -> g end) |> Enum.reject(&(&1 == [])) do
          [] -> err(:value)
          kept -> assemble(kept, axis)
        end
    end
  end

  defp assemble(grids, :vertical) do
    width = grids |> Enum.map(&grid_width/1) |> Enum.max()
    capped(Enum.flat_map(grids, fn g -> Enum.map(g, &pad_row(&1, width)) end))
  end

  defp assemble(grids, :horizontal) do
    height = grids |> Enum.map(&length/1) |> Enum.max()

    grids
    |> Enum.map(fn g -> pad_grid(g, height) end)
    |> Enum.zip_with(&Enum.concat/1)
    |> capped()
  end

  defp capped(rows), do: if(grid_area(rows) > @array_cap, do: err(:num), else: {:array, rows})

  defp pad_row(row, width), do: row ++ List.duplicate(err(:na), width - length(row))

  defp pad_grid(grid, height) do
    grid ++ List.duplicate(List.duplicate(err(:na), grid_width(grid)), height - length(grid))
  end

  # CONCAT's per-argument text list: the argument's grid read ROW-MAJOR, blanks
  # rendered "" (never skipped), a source error short-circuiting the whole call.
  defp concat_texts(ast, ctx) do
    case array_grid(ast, ctx) do
      {:error, _} = e ->
        e

      {:ok, rows} ->
        vals = List.flatten(rows)

        case Enum.find(vals, &match?({:error, _}, &1)) do
          {:error, _} = e -> e
          nil -> Enum.map(vals, &to_text/1)
        end
    end
  end

  # SUBTOTAL's function-code table. 1-11 and 101-111 both land on the same
  # aggregate: the 100-band's hidden-row exclusion needs a row-visibility input
  # the engine does not have (documented gap, moduledoc §Aggregate selection).
  defp subtotal_target(code) when code in 101..111, do: subtotal_target(code - 100)
  defp subtotal_target(1), do: "AVERAGE"
  defp subtotal_target(2), do: "COUNT"
  defp subtotal_target(3), do: "COUNTA"
  defp subtotal_target(4), do: "MAX"
  defp subtotal_target(5), do: "MIN"
  defp subtotal_target(6), do: "PRODUCT"
  defp subtotal_target(7), do: "STDEV"
  defp subtotal_target(8), do: "STDEVP"
  defp subtotal_target(9), do: "SUM"
  defp subtotal_target(10), do: "VAR"
  defp subtotal_target(11), do: "VARP"
  defp subtotal_target(_), do: nil

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
  # Unified ctx: occupied is a %{tab => MapSet {col,row}} map; read the ambient
  # tab's set. Corners here are always 2-tuples (localize_range peeled the tab
  # and re-based ctx.tab already), so the result stays {col,row}.
  defp occupied_positions({c1, r1}, {c2, r2}, %{unified: true} = ctx) do
    occ = Map.get(ctx.occupied, ctx.tab, MapSet.new())
    area = (c2 - c1 + 1) * (r2 - r1 + 1)

    if area <= MapSet.size(occ) do
      for c <- c1..c2, r <- r1..r2, MapSet.member?(occ, {c, r}), do: {c, r}
    else
      Enum.filter(occ, fn {c, r} -> c >= c1 and c <= c2 and r >= r1 and r <= r2 end)
    end
  end

  defp occupied_positions({c1, r1}, {c2, r2}, ctx) do
    area = (c2 - c1 + 1) * (r2 - r1 + 1)

    if area <= MapSet.size(ctx.occupied) do
      for c <- c1..c2, r <- r1..r2, MapSet.member?(ctx.occupied, {c, r}), do: {c, r}
    else
      Enum.filter(ctx.occupied, fn {c, r} -> c >= c1 and c <= c2 and r >= r1 and r <= r2 end)
    end
  end

  # Peel the tab off a range's corners. A cross-tab range ({tab,col,row}
  # corners) returns {col,row} corners plus a ctx re-based to that tab, so the
  # downstream 2-tuple machinery (occupied_positions, cell_at, range_grid) runs
  # unchanged against the target tab. A same-tab range passes through untouched;
  # the 3-tuple clause only ever fires inside the unified ctx (which has :tab).
  defp localize_range({t, c1, r1}, {t, c2, r2}, ctx), do: {{c1, r1}, {c2, r2}, %{ctx | tab: t}}
  defp localize_range(p1, p2, ctx), do: {p1, p2, ctx}

  defp rect_area({c1, r1}, {c2, r2}), do: (c2 - c1 + 1) * (r2 - r1 + 1)

  # A range or single-ref AST node as a rectangle; anything else is not a
  # range (the caller maps it to #VALUE!).
  defp as_range({:range, {c1, r1}, {c2, r2}}), do: {:ok, {c1, r1}, {c2, r2}}
  # A same-tab full-axis range (2-tuple corners) is consumable by the as_range
  # family (VLOOKUP/INDEX/MATCH/…) — strip the bounds tag. A cross-tab full-axis
  # range (3-tuple corners) does NOT match here and falls to the `:error`
  # clause, mirroring wave-1's fail-closed cross-tab handling.
  defp as_range({:range, {c1, r1}, {c2, r2}, _b}), do: {:ok, {c1, r1}, {c2, r2}}
  defp as_range({:ref, {c, r}}), do: {:ok, {c, r}, {c, r}}
  # A cross-tab range/ref (3-tuple corners) is not consumable by the as_range
  # family in wave 1 — fail closed so the caller returns a clean error, never a
  # crash. Cross-tab aggregation flows through range_values/range_grid, which
  # localize the tab; the as_range consumers (VLOOKUP/INDEX/SUMIF/…) gain
  # cross-tab support in a later slice.
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

  # rest is the optional VLOOKUP/HLOOKUP 4th arg: [] (or truthy) → approximate.
  defp lookup_range_flag([], _ctx), do: true

  defp lookup_range_flag([ast], ctx) do
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

  # do_vlookup rotated 90°: the first ROW is the lookup vector, the answer
  # sits n-1 rows below the matched column.
  defp do_hlookup(val, r1, c1, c2, n, approx?, ctx) do
    col =
      if approx? do
        # Sorted-ascending assumption: keep the last value <= val.
        Enum.reduce(row_cells(r1, c1, c2, ctx), nil, fn {c, cell}, best ->
          if lookup_le?(cell, val), do: c, else: best
        end)
      else
        case Enum.find(row_cells(r1, c1, c2, ctx), fn {_c, cell} ->
               lookup_compare(cell, val)
             end) do
          {c, _cell} -> c
          nil -> nil
        end
      end

    case col do
      nil -> err(:na)
      c -> cell_at({c, r1 + n - 1}, ctx)
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

  # ── reference/array-tier helpers (XLOOKUP/SUMPRODUCT/ADDRESS) ───────────

  # The XLOOKUP lookup vector: a single-column or single-row range as
  # ascending {coordinate, value} cells (blanks dropped, MATCH-style) plus its
  # base coordinate. A 2-D rectangle is :error → #VALUE! (no spill tier).
  defp lookup_vector({c1, r1}, {c2, r2}, ctx) do
    cond do
      c1 == c2 -> {:ok, column_cells(c1, r1, r2, ctx), r1}
      r1 == r2 -> {:ok, row_cells(r1, c1, c2, ctx), c1}
      true -> :error
    end
  end

  # The return vector must be 1-D too, of the lookup vector's exact length —
  # either orientation; yields the offset → answer-coordinate mapper.
  defp return_vector({lc1, lr1}, {lc2, lr2}, {sc1, sr1}, {sc2, sr2}) do
    lookup_len = if lc1 == lc2, do: lr2 - lr1 + 1, else: lc2 - lc1 + 1

    cond do
      sc1 == sc2 and sr2 - sr1 + 1 == lookup_len -> {:ok, fn off -> {sc1, sr1 + off} end}
      sr1 == sr2 and sc2 - sc1 + 1 == lookup_len -> {:ok, fn off -> {sc1 + off, sr1} end}
      true -> :error
    end
  end

  # rest is [if_not_found] / [if_not_found, match_mode]; the mode defaults to
  # 0 (exact) and must land in [-1, 0, 1, 2] (:error → #VALUE! at the caller).
  defp xlookup_mode([_nf, mode_ast], ctx) do
    case eval_number(mode_ast, ctx) do
      {:error, _} = e ->
        e

      n ->
        mode = trunc(n)
        if mode in [-1, 0, 1, 2], do: mode, else: :error
    end
  end

  defp xlookup_mode(_rest, _ctx), do: 0

  defp xlookup_find(key, 0, cells) do
    case Enum.find(cells, fn {_coord, cell} -> lookup_compare(cell, key) end) do
      {coord, _cell} -> coord
      nil -> nil
    end
  end

  # Mode 2 rides MATCH's wildcard-aware exact scan (a wildcard-free key falls
  # back to the plain compare there).
  defp xlookup_find(key, 2, cells), do: match_exact(key, cells)

  defp xlookup_find(key, -1, cells), do: xlookup_nearest(cells, &lookup_le?(&1, key), :gt)
  defp xlookup_find(key, 1, cells), do: xlookup_nearest(cells, &lookup_ge?(&1, key), :lt)

  # The qualifying cell whose value sits closest to the key — mode -1 keeps
  # the LARGEST cell <= key (better = :gt), mode 1 the SMALLEST cell >= key
  # (better = :lt). No sortedness assumed; ties keep the earliest position.
  # Cross-type cells never qualify (lookup_le?/ge? → order → :mismatch), so
  # every candidate is comparable to every other.
  defp xlookup_nearest(cells, qualifies?, better) do
    cells
    |> Enum.filter(fn {_coord, cell} -> qualifies?.(cell) end)
    |> Enum.reduce(nil, fn {coord, cell}, best ->
      case best do
        nil -> {coord, cell}
        {_bc, bcell} -> if order(cell, bcell) == better, do: {coord, cell}, else: best
      end
    end)
    |> case do
      nil -> nil
      {coord, _cell} -> coord
    end
  end

  defp sumproduct(rects, ctx) do
    offsets =
      rects
      |> Enum.flat_map(fn {{c1, r1} = p1, p2} ->
        Enum.map(occupied_positions(p1, p2, ctx), fn {c, r} -> {c - c1, r - r1} end)
      end)
      |> Enum.uniq()

    Enum.reduce_while(offsets, 0, fn {dc, dr}, sum ->
      case sumproduct_factor(rects, dc, dr, ctx) do
        {:error, _} = e ->
          {:halt, e}

        p ->
          case safe_arith(fn -> sum + p end) do
            {:error, _} = e -> {:halt, e}
            s -> {:cont, s}
          end
      end
    end)
  end

  # The product of one aligned offset across every rectangle. A zero factor
  # does NOT short-circuit: later ranges still get scanned so an error cell
  # aligned with a blank/zero surfaces.
  defp sumproduct_factor(rects, dc, dr, ctx) do
    Enum.reduce_while(rects, 1, fn {{c1, r1}, _p2}, acc ->
      case cell_at({c1 + dc, r1 + dr}, ctx) do
        {:error, _} = e ->
          {:halt, e}

        v when is_number(v) ->
          case safe_arith(fn -> acc * v end) do
            {:error, _} = e -> {:halt, e}
            p -> {:cont, p}
          end

        # Text/booleans/dates/blanks count 0 (Excel's non-numeric rule).
        _other ->
          {:cont, 0}
      end
    end)
  end

  defp a1_address(row, col, abs_mode) do
    col_anchor = if abs_mode in [1, 3], do: "$", else: ""
    row_anchor = if abs_mode in [1, 2], do: "$", else: ""
    col_anchor <> col_letters(col) <> row_anchor <> Integer.to_string(row)
  end

  defp r1c1_address(row, col, abs_mode) do
    row_part = if abs_mode in [1, 2], do: "R#{row}", else: "R[#{row}]"
    col_part = if abs_mode in [1, 3], do: "C#{col}", else: "C[#{col}]"
    row_part <> col_part
  end

  # The column's letter run alone: format_ref's row-1 address minus its
  # trailing "1" (letters are A–Z only, so the one-byte drop is exact).
  defp col_letters(col) do
    addr = Sheets.format_ref({col, 1})
    binary_part(addr, 0, byte_size(addr) - 1)
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
        # Temporals ride along (agg_serial at the aggregation sites) — a date
        # sum-range must sum/extremize, never silently drop to 0.
        nil -> {:ok, Enum.filter(cells, &(is_number(&1) or temporal?(&1)))}
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
        # Same temporal keep as sumif_values (MAXIFS/MINIFS/SUMIFS over dates).
        nil -> {:ok, Enum.filter(cells, &(is_number(&1) or temporal?(&1)))}
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
    # Dates are numbers in the criteria mini-language: an ISO-temporal
    # operand (both the `">"&DATE(…)` concat idiom — to_text renders ISO —
    # and hand-typed ">2024-06-01") parses to the struct so date cells
    # compare through order/2. Anything else keeps text semantics.
    operand = parse_number(rest) || parse_temporal(rest) || rest

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

  # VALUE speaks the common user-facing numeric shapes on top of the plain
  # parse: a leading currency symbol ($ € £ kr), grouping commas (validated
  # as 3-digit groups — "1,2,3" stays #VALUE!), accountancy parens for
  # negation ("(5)" → -5), a bare exponent ("1e3" → 1000, via Float.parse),
  # and the trailing-% scale.
  defp parse_value(s) do
    if String.ends_with?(s, "%") do
      case parse_value_number(s |> String.trim_trailing("%") |> String.trim()) do
        nil -> err(:value)
        # divide/2 keeps VALUE("200%") an exact integer 2 AND guards the float
        # coercion of a bignum percent text (#NUM!, not a crash).
        n -> divide(n, 100)
      end
    else
      case parse_value_number(s) do
        nil -> err(:value)
        n -> n
      end
    end
  end

  # Grouping commas are only stripped when the whole string validates as
  # 3-digit groups; a comma anywhere else keeps the text unparseable.
  @value_grouped ~r/^[+-]?\d{1,3}(?:,\d{3})+(?:\.\d+)?(?:[eE][+-]?\d+)?$/
  # A currency symbol sits after an optional sign; "kr" is case-insensitive.
  @value_currency ~r/^([+-]?)\s*(?:\$|€|£|kr)\s*/iu

  defp parse_value_number("(" <> rest) do
    if String.ends_with?(rest, ")") do
      inner = rest |> binary_part(0, byte_size(rest) - 1) |> String.trim()

      case parse_value_number(inner) do
        nil -> nil
        n -> -n
      end
    else
      nil
    end
  end

  defp parse_value_number(s) do
    s = Regex.replace(@value_currency, s, "\\1", global: false)

    cond do
      not String.contains?(s, ",") -> parse_number(s)
      Regex.match?(@value_grouped, s) -> parse_number(String.replace(s, ",", ""))
      true -> nil
    end
  end

  # ── currency/fixed formatting helpers (DOLLAR / FIXED) ────────────────
  #
  # Integer-math decimal rendering (Kernel.round — ties away from zero, the
  # Excel half-up Fmt.display/2 also uses), so a bignum int formats exactly;
  # the float paths sit under the callers' safe_arith (overflow → #NUM!).

  defp money_string(n, dec) do
    safe_arith(fn ->
      {neg?, body} = decimal_body(rounded_at(n, dec), clamp_dec(dec), true)
      sign_str(neg?) <> "$" <> body
    end)
  end

  defp fixed_string(n, dec, group?) do
    safe_arith(fn ->
      {neg?, body} = decimal_body(rounded_at(n, dec), clamp_dec(dec), group?)
      sign_str(neg?) <> body
    end)
  end

  # dec >= 0 leaves rounding to decimal_body's scaling; dec < 0 pre-rounds to
  # the 10^-dec place (FIXED(1234.567, -2) → 1200).
  defp rounded_at(n, dec) when dec >= 0, do: n

  defp rounded_at(n, dec) do
    p = Integer.pow(10, min(-dec, 300))
    round(n / p) * p
  end

  # Excel caps FIXED/DOLLAR at 127 decimal places; a negative dec renders
  # zero decimals (rounded_at/2 already did the rounding).
  defp clamp_dec(dec), do: dec |> max(0) |> min(127)

  defp decimal_body(v, decimals, group?) do
    scale = Integer.pow(10, decimals)
    scaled = round(v * scale)
    neg? = scaled < 0
    scaled = abs(scaled)
    int_str = Integer.to_string(div(scaled, scale))
    int_str = if group?, do: group_thousands(int_str), else: int_str

    if decimals > 0 do
      frac = scaled |> rem(scale) |> Integer.to_string() |> String.pad_leading(decimals, "0")
      {neg?, int_str <> "." <> frac}
    else
      {neg?, int_str}
    end
  end

  defp group_thousands(digits) do
    digits
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &List.to_string/1)
  end

  defp sign_str(true), do: "-"
  defp sign_str(false), do: ""

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
    # Excel coerces numeric-looking text against numeric criteria — and
    # ISO-looking text against temporal criteria (dates ARE numbers there).
    v =
      cond do
        is_binary(v) and is_number(operand) -> parse_number(v) || v
        is_binary(v) and temporal?(operand) -> parse_temporal(v) || v
        true -> v
      end

    {v, operand} = align_temporals(v, operand)

    case compare(op, v, operand) do
      true -> true
      _ -> false
    end
  end

  # Cross-kind temporals (a datetime cell against a date criterion) compare
  # via the day serial; same-kind pairs keep their native compare in order/2.
  defp align_temporals(a, b) do
    if temporal?(a) and temporal?(b) and a.__struct__ != b.__struct__ do
      {temporal_serial(a), temporal_serial(b)}
    else
      {a, b}
    end
  end

  # Excel-style day serial (epoch 1899-12-30); datetimes add the fractional
  # day. This is how temporals join numeric aggregation (SUMIF over a date
  # sum-range) and mixed number+date extrema (MAXIFS/MINIFS).
  @serial_epoch ~D[1899-12-30]
  defp temporal_serial(%Date{} = d), do: Date.diff(d, @serial_epoch)

  defp temporal_serial(%DateTime{} = dt),
    do: Date.diff(DateTime.to_date(dt), @serial_epoch) + time_fraction(DateTime.to_time(dt))

  defp temporal_serial(%NaiveDateTime{} = ndt) do
    Date.diff(NaiveDateTime.to_date(ndt), @serial_epoch) +
      time_fraction(NaiveDateTime.to_time(ndt))
  end

  defp time_fraction(%Time{hour: h, minute: m, second: s}),
    do: (h * 3600 + m * 60 + s) / 86_400

  # Aggregation key for the *IF/*IFS value collections: numbers as-is,
  # temporals as their day serial.
  defp agg_serial(v) when is_number(v), do: v
  defp agg_serial(t), do: temporal_serial(t)

  # A stored bignum item coerces past float64 inside Enum.sum's `+` the moment
  # a float sibling joins it — a range overflow is #NUM!, not a crash.
  defp aggregate("SUM", items), do: safe_arith(fn -> Enum.sum(items) end)

  defp aggregate(avg, items) when avg in ["AVG", "AVERAGE"] do
    case items do
      [] ->
        err(:div0)

      nums ->
        case safe_arith(fn -> Enum.sum(nums) end) do
          {:error, _} = e -> e
          sum -> divide(sum, length(nums))
        end
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

  # ── batch-4 helpers (A-coercion / MROUND / NUMBERVALUE / time / yearfrac) ──

  # The A-variant (and N's) coercion table. Blanks only reach this from a
  # direct scalar N(blank) — range blanks were already dropped upstream.
  defp a_coerce(n) when is_number(n), do: n
  defp a_coerce(true), do: 1
  defp a_coerce(false), do: 0
  defp a_coerce(%Date{} = d), do: date_serial(d)
  defp a_coerce(%DateTime{} = dt), do: date_serial(dt)
  defp a_coerce(%NaiveDateTime{} = ndt), do: date_serial(ndt)
  defp a_coerce(_text_or_blank), do: 0

  # Excel's date serial: days since 1899-12-30 (the Lotus epoch — the 1900
  # leap-bug means the epoch is the 30th, and modern dates line up exactly);
  # a datetime adds its fraction of the day.
  @serial_epoch ~D[1899-12-30]
  defp date_serial(%Date{} = d), do: Date.diff(d, @serial_epoch)

  defp date_serial(%DateTime{} = dt),
    do: datetime_serial(DateTime.to_date(dt), dt.hour, dt.minute, dt.second)

  defp date_serial(%NaiveDateTime{} = ndt),
    do: datetime_serial(NaiveDateTime.to_date(ndt), ndt.hour, ndt.minute, ndt.second)

  defp datetime_serial(date, h, m, s) do
    secs = h * 3600 + m * 60 + s
    base = date_serial(date)
    if secs == 0, do: base, else: base + secs / 86_400
  end

  # MROUND's core. Sign checks first; integer pairs round half away from
  # zero in EXACT integer math (bignum-safe — the output boundary
  # canonicalises an overflowing result); the float path degrades an
  # overflowing coercion to #NUM! under safe_arith.
  defp fn_mround(_n, m) when m == 0, do: 0
  defp fn_mround(n, m) when (n > 0 and m < 0) or (n < 0 and m > 0), do: err(:num)

  defp fn_mround(n, m) when is_integer(n) and is_integer(m) do
    sign = if n < 0, do: -1, else: 1
    {a, mm} = {abs(n), abs(m)}
    sign * div(2 * a + mm, 2 * mm) * mm
  end

  defp fn_mround(n, m), do: safe_arith(fn -> round(n / m) * m end)

  # NUMBERVALUE's parse: strip whitespace, peel trailing percents, split on
  # the decimal separator, drop group separators from the integer part only
  # (a group sep past the decimal is #VALUE!, like Excel), then reuse
  # parse_number. Empty text is 0; percents divide by 100 each (exactly,
  # via divide/2).
  defp numbervalue(_t, dec, grp) when is_nil(dec) or is_nil(grp) or dec == grp,
    do: err(:value)

  defp numbervalue(t, dec, grp) do
    {body, pct} = t |> String.replace(~r/\s/u, "") |> strip_percents(0)

    cond do
      body == "" and pct == 0 -> 0
      body == "" -> err(:value)
      true -> numbervalue_parse(body, dec, grp, pct)
    end
  end

  defp numbervalue_parse(body, dec, grp, pct) do
    with [int_part | frac] when length(frac) <= 1 <- String.split(body, dec),
         false <- Enum.any?(frac, &String.contains?(&1, grp)),
         digits = Enum.join([String.replace(int_part, grp, "") | frac], "."),
         n when is_number(n) <- parse_number(digits) || err(:value) do
      if pct == 0, do: n, else: divide(n, Integer.pow(100, pct))
    else
      _ -> err(:value)
    end
  end

  defp strip_percents(t, pct) do
    case String.split_at(t, -1) do
      {rest, "%"} -> strip_percents(rest, pct + 1)
      _ -> {t, pct}
    end
  end

  # TIMEVALUE's parse: "H:MM[:SS]" rolls over past a day exactly like
  # TIME/3; ISO datetime text contributes only its time-of-day. A pure date
  # (no time component) is #VALUE!.
  defp timevalue(s) do
    case Regex.run(~r/^(\d{1,4}):(\d{1,2})(?::(\d{1,2}))?$/, s) do
      [_, h, m] ->
        time_fraction(String.to_integer(h), String.to_integer(m), 0)

      [_, h, m, sec] ->
        time_fraction(String.to_integer(h), String.to_integer(m), String.to_integer(sec))

      nil ->
        case parse_temporal(s) do
          %DateTime{} = dt -> time_fraction(dt.hour, dt.minute, dt.second)
          %NaiveDateTime{} = ndt -> time_fraction(ndt.hour, ndt.minute, ndt.second)
          _ -> err(:value)
        end
    end
  end

  defp time_fraction(h, m, s),
    do: divide(Integer.mod(h * 3600 + m * 60 + s, 86_400), 86_400)

  # YEARFRAC bases. divide/2 keeps exact quotients exact (a whole year on
  # basis 0 is the integer 1) and guards the float coercion.
  defp yearfrac(s, e, 0) do
    {d1, d2} = {s.day, e.day}

    # NASD order: the end-of-February clamps first, then the 31st rules
    # (which read d1 AFTER its February clamp).
    {d1, d2} =
      cond do
        last_feb_day?(s) and last_feb_day?(e) -> {30, 30}
        last_feb_day?(s) -> {30, d2}
        true -> {d1, d2}
      end

    d2 = if d2 == 31 and d1 >= 30, do: 30, else: d2
    d1 = if d1 == 31, do: 30, else: d1
    divide(days360(s, e, d1, d2), 360)
  end

  # actual/actual: actual days over the AVERAGE calendar-year length across
  # the spanned years — days / (span/nyears), computed as exact integers.
  defp yearfrac(s, e, 1) do
    nyears = e.year - s.year + 1

    span =
      Enum.reduce(s.year..e.year, 0, fn y, acc ->
        acc + if :calendar.is_leap_year(y), do: 366, else: 365
      end)

    divide(Date.diff(e, s) * nyears, span)
  end

  defp yearfrac(s, e, 2), do: divide(Date.diff(e, s), 360)
  defp yearfrac(s, e, 3), do: divide(Date.diff(e, s), 365)

  # European 30/360: both 31sts clamp unconditionally, no February rule.
  defp yearfrac(s, e, 4),
    do: divide(days360(s, e, min(s.day, 30), min(e.day, 30)), 360)

  defp yearfrac(_s, _e, _basis), do: err(:num)

  defp days360(s, e, d1, d2),
    do: (e.year - s.year) * 360 + (e.month - s.month) * 30 + (d2 - d1)

  defp last_feb_day?(%Date{month: 2, day: d} = date), do: d == Date.days_in_month(date)
  defp last_feb_day?(_date), do: false

  defp err(:value), do: {:error, "#VALUE!"}
  defp err(:div0), do: {:error, "#DIV/0!"}
  defp err(:ref), do: {:error, "#REF!"}
  defp err(:cycle), do: {:error, "#CYCLE!"}
  defp err(:na), do: {:error, "#N/A"}
  defp err(:num), do: {:error, "#NUM!"}
  defp err(:spill), do: {:error, "#SPILL!"}
  defp err(:name), do: {:error, "#NAME?"}
end
