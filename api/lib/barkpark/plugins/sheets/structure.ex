defmodule Barkpark.Plugins.Sheets.Structure do
  @moduledoc """
  Structural rewrites for sheet tabs (the grid editor's ops) — row/column
  insert/delete with Excel-style ref shifting, plus the small layout
  setters (column width, row height). Pure functions beside
  `Barkpark.Plugins.Sheets.Engine`: no Repo, no I/O and no recompute —
  `Barkpark.Plugins.Sheets.Session` serializes these through its mailbox and runs
  the engine on the rewritten tab afterwards.

  ## Shift semantics (Excel's bind rules)

  `insert_rows/3` / `insert_cols/3` at 1-based index `at`, `count >= 1`:

    * cell keys at/after `at` shift by `count`;
    * formula refs at/after `at` shift by `count`; a ref shifted past the
      grid bounds becomes the literal `#REF!`; range corners shift
      independently, so a range spanning the insert point EXPANDS;
    * merges shift the same way (a merge pushed past the grid drops);
    * `row_heights`/`col_widths` re-key; `frozen_rows`/`frozen_cols` are
      positional bands and stay put;
    * an insert that would push an OCCUPIED cell past the grid bounds
      errors (`grid_bounds_exceeded`) before touching anything.

  `delete_rows/3` / `delete_cols/3` of the span `at..at+count-1`:

    * cells inside the span drop; keys after it shift back by `count`;
    * a formula ref INTO the span becomes the literal `#REF!` in the
      formula STRING — exactly like Excel — and the engine then computes
      the cell to the `#REF!` error value;
    * a range fully inside the span becomes `#REF!`; a partially covered
      range CLIPS (re-emitted as canonical `$`-less corners);
    * merges clip the same way — fully-deleted and clipped-to-one-cell
      merges drop; `cond_formats` ranges rebase in the SAME pass, but a
      range clipped to a single cell KEEPS its rule (re-emitted as "B2") —
      a fully-deleted/pushed-off-grid range drops it, and when two rules
      clip onto the SAME normalized range only the first in list order
      survives (the save gate rejects duplicates — CF-D4/D7);
    * `row_heights`/`col_widths` drop in-span keys and re-key the rest;
    * `frozen_rows`/`frozen_cols` shrink by their overlap with the span
      (a string-typed count stays a string — the schema convention).

  ## Formula rewriting

  `rewrite_formula/3` walks the formula with a span-preserving scanner
  that mirrors the engine's lexer: quoted string literals (`""` escaping
  included) pass through verbatim — an `"A1"` inside a string is never a
  ref — and a ref-shaped word followed by `(` is a function name
  (`LOG10(…)`), also left alone. `$` markers do not pin a ref (`$A$1`
  shifts exactly like `A1` — the engine convention); a shifted ref keeps
  its `$` markers, an untouched ref keeps its exact original text, and
  everything that is not a ref (operators, numbers, whitespace, malformed
  words the engine would reject anyway) passes through untouched.

  ## Cross-tab references (CT-D1 — B-CT-5)

  Formulas may reference other tabs by NAME: `Sheet2!A1`, `SUM(Sheet2!A1:B5)`,
  `'My Sheet'!A1` (a name with a space/punctuation/leading digit or a
  ref-shaped name quotes as `'…'`, a literal apostrophe doubled `''` — Excel).
  The scanner recognizes these as single units, so the per-tab
  `rewrite_formula/3` leaves a qualified ref UNTOUCHED on an insert/delete (a
  bare `Sheet3` word is no longer mis-shifted as a ref). Three pure,
  whole-document sweeps carry the cross-tab structural rewrite the Session
  wires around the per-tab op:

    * `shift_cross_tab_refs/4` — after a row/col insert/delete on tab `i`,
      shift every OTHER (and self-qualified) formula's `Name_i!` ref/range;
      deleted axis → literal `#REF!`, partial range clips. Same shift/clip
      arithmetic as the local pass — only token recognition is new.
    * `rename_refs/3` — rewrite every `OldName!`/`'Old Name'!` qualifier to the
      new (re-quoted) name across all tabs.
    * `delete_tab_refs/2` — rewrite every ref to a deleted tab to `#REF!`.

  `move_tab` needs NO rewrite — name-based refs are position-stable (CT-D1).

  ## Full-axis ranges — `A:A` / `3:3` (B-AA-3, design §3.1 + §6)

  A full-COLUMN range (`A:A`, `$A:$C`) is unbounded on rows; a full-ROW range
  (`3:3`, `1:5`) is unbounded on columns. The scanner recognizes both as single
  ref tokens — byte-for-byte the string shapes the engine's lexer accepts: bare
  column letters with an optional leading `$` for a column axis, plain integers
  for a row axis, plus the tab-qualified forms `Sheet2!A:A` / `'My Sheet'!3:3`
  reusing the same qualifier path as a cross-tab cell ref. Each shifts ONLY on
  the axis it bounds and is INVARIANT on the perpendicular op (Excel): a column
  insert/delete moves `A:A` (→`B:B`, or literal `#REF!` when its column is
  deleted, clipping a multi-column range's endpoints) but leaves `3:3` untouched;
  a row op mirrors it. Only token RECOGNITION is new — the shift/clip arithmetic
  is the same `shift_index`/`shift_span` a bounded ref uses. There is no stored
  rectangle (CT-D2): the formula STRING is the truth, so `A:A` re-resolves to the
  occupied range at every recompute.

  ## Sort (SF-A — a pure row permutation)

  `sort_rows/3` reorders WHOLE rows within a rectangular range and nothing
  else. It is a pure permutation of the rect's row-slices: for every row in
  the rect, the cells in the rect's columns move together to their new row;
  cells OUTSIDE the rect (even on the same rows) never move. Every moved
  cell map travels BYTE-IDENTICAL — `v`/`f`/`fmt`/`s`/`t` untouched and the
  formula string `f` is NEVER rewritten. This is Excel semantics (SF-D1): a
  sorted `=A1` that lands on row 5 still reads `=A1`, pointing wherever `A1`
  now is. The Session recomputes the tab afterwards (the insert/delete
  precedent), which refreshes each moved formula's `v`.

  The comparator (SF-D4) reads the stored computed `v` (never the display
  string, never the formula text). Ascending total ladder, each tier fully
  preceding the next:

      1. numbers (numeric order)
      2. text (case-insensitive — `String.downcase`)
      3. FALSE
      4. TRUE
      5. errors (all errors compare EQUAL to one another)
      6. blanks — ALWAYS last, in BOTH directions

  A descending key reverses tiers 1..5 only; blanks stay last. The sort is
  STABLE — equal keys keep their original relative order. Error
  classification reads the single-sourced value vocabulary inline
  (`is_binary(v) and (t == "e" or v in Engine.error_values())`); it does NOT
  call into `CondFormat`. This cross-type total order is a DELIBERATE
  divergence from the engine, which returns `#VALUE!` on a cross-type
  comparison — do NOT "fix" it into engine parity; a mixed-type column needs
  a deterministic order and this is it.

  Guards (SF-D5): a merge intersecting the rect refuses with
  `sort_merge_overlap`; a rect intersecting the frozen head band
  (`frozen_rows`) refuses with `sort_frozen_overlap`; malformed keys (not a
  list, a `col` outside the rect, a `dir` other than `asc`/`desc`) refuse
  with `invalid_sort_keys`. These are SESSION-OP string codes (the
  `merge_degenerate` convention), NOT `Engine.error_values` entries
  (SF-AM1). `row_heights` do NOT travel with sorted rows; `merges` and
  `cond_formats` are geography-anchored and stay put.

  `permute_rows/3` re-applies an EXPLICIT permutation over a rect and
  returns its own inverse — the undo/redo applier for the `{:permute, …}`
  inverse entry (SF-D6). `sort_rows/3` returns `perm` (old-row-index → new
  position); `invert_perm/1` produces the inverse the undo entry stores.
  Because sort only permutes rows, undo is loss-free and tab-identity-stable.
  """

  alias Barkpark.Plugins.Sheets.Core, as: Sheets
  alias Barkpark.Plugins.Sheets.Engine

  # Excel grid bounds — deliberately duplicated (the established
  # convention: Engine, the plugin gate and the Session each keep their
  # own copy of the same two integers).
  @grid_max_col 16_384
  @grid_max_row 1_048_576

  @ref_re ~r/^(\$?)([A-Za-z]+)(\$?)([0-9]+)$/
  @split_re ~r/^([A-Z]+)([0-9]+)$/

  @type error :: {:error, String.t(), String.t()}

  @doc "Insert `count` rows at 1-based row `at` — see the moduledoc."
  @spec insert_rows(map(), term(), term()) :: {:ok, map()} | error()
  def insert_rows(tab, at, count), do: axis_op(tab, :row, {:insert, at, count})

  @doc "Delete the rows `at..at+count-1` — see the moduledoc."
  @spec delete_rows(map(), term(), term()) :: {:ok, map()} | error()
  def delete_rows(tab, at, count), do: axis_op(tab, :row, {:delete, at, count})

  @doc "Insert `count` columns at 1-based column `at` — see the moduledoc."
  @spec insert_cols(map(), term(), term()) :: {:ok, map()} | error()
  def insert_cols(tab, at, count), do: axis_op(tab, :col, {:insert, at, count})

  @doc "Delete the columns `at..at+count-1` — see the moduledoc."
  @spec delete_cols(map(), term(), term()) :: {:ok, map()} | error()
  def delete_cols(tab, at, count), do: axis_op(tab, :col, {:delete, at, count})

  @doc """
  Set the width of 1-based column `col` to `px` (a positive number,
  rounded to an integer) in the tab's sparse `"col_widths"` map, or
  remove the entry when `px` is `nil`.
  """
  @spec set_col_width(map(), term(), term()) :: {:ok, map()} | error()
  def set_col_width(tab, col, px), do: set_size(tab, "col_widths", "col", @grid_max_col, col, px)

  @doc """
  Set the height of 1-based row `row` to `px` (a positive number, rounded
  to an integer) in the tab's sparse `"row_heights"` map, or remove the
  entry when `px` is `nil`.
  """
  @spec set_row_height(map(), term(), term()) :: {:ok, map()} | error()
  def set_row_height(tab, row, px),
    do: set_size(tab, "row_heights", "row", @grid_max_row, row, px)

  @doc """
  Freeze the top `rows` rows and left `cols` columns — both non-negative
  integers below the grid bounds. Writes INTEGER band values; a band of
  `0` DELETES its key (mirroring the xlsx importer's sparse convention) so
  content stays sparse. Positional bands: no cell moves, so the Session
  recompute is skipped.
  """
  @spec set_frozen(map(), term(), term()) :: {:ok, map()} | error()
  def set_frozen(tab, rows, cols) when is_map(tab) do
    cond do
      not (is_integer(rows) and rows >= 0 and rows < @grid_max_row) ->
        {:error, "invalid_frozen",
         "rows must be an integer between 0 and #{@grid_max_row - 1}, got #{inspect(rows)}"}

      not (is_integer(cols) and cols >= 0 and cols < @grid_max_col) ->
        {:error, "invalid_frozen",
         "cols must be an integer between 0 and #{@grid_max_col - 1}, got #{inspect(cols)}"}

      true ->
        {:ok,
         tab
         |> write_frozen("frozen_rows", rows)
         |> write_frozen("frozen_cols", cols)}
    end
  end

  @doc """
  Rewrite every cell ref and range in a formula string for a structural
  change on one axis — `axis` is `:row` or `:col`, `change` is
  `{:insert, at, count}` or `{:delete, at, count}`. Pure and total: a
  string the engine would reject comes back with its non-ref parts
  untouched. See the moduledoc for the shift/clip/`#REF!` rules.
  """
  @spec rewrite_formula(
          String.t(),
          :row | :col,
          {:insert | :delete, pos_integer(), pos_integer()}
        ) ::
          String.t()
  def rewrite_formula(f, axis, change) when is_binary(f) and axis in [:row, :col] do
    scan(f, {:local, axis, change}, []) |> IO.iodata_to_binary()
  end

  @doc """
  Rebase every relative cell ref and range in a formula string by
  `{dcol, drow}` — the copy/fill semantics (as distinct from a structural
  insert/delete). `$`-anchored components are pinned: `$A$1` never moves,
  `$A1` shifts only its row, `A$1` only its column. A ref (or either range
  corner) that lands outside the grid collapses to a literal `#REF!`.
  Rides the same span-preserving scanner as `rewrite_formula/3`, so string
  literals and function names are protected identically.
  """
  @spec rebase_formula(String.t(), integer(), integer()) :: String.t()
  def rebase_formula(f, dcol, drow) when is_binary(f) and is_integer(dcol) and is_integer(drow) do
    scan(f, {:local, :col, {:rebase, dcol, drow}}, []) |> IO.iodata_to_binary()
  end

  # ── cross-tab references (CT-D1 — B-CT-5) ──────────────────────────────────
  #
  # A cross-tab ref is NAME-based and lives in the formula string, e.g.
  # `Sheet2!A1`, `Sheet2!A1:B5`, `'My Sheet'!A1` (a name with a space/
  # punctuation/leading digit or a ref-shaped name quotes as `'…'`, a literal
  # apostrophe doubled — Excel). These pure sweeps are the cross-tab
  # counterpart of the per-tab `insert_rows`/… ops (which rewrite ONLY the
  # mutated tab's OWN bare refs). The Session serializes and wires them.

  @doc """
  Shift cross-tab references after a structural row/column insert or delete on
  the tab at `target_index`. The per-tab op (`insert_rows`/`delete_rows`/…)
  rewrites that tab's OWN bare refs; this sweeps EVERY tab's formulas (the
  mutated tab included, to catch self-qualified `ThisTab!A1` refs) and shifts
  ONLY the qualified refs/ranges whose tab name matches the mutated tab's name.
  Bare refs and refs to other tabs pass through byte-for-byte. A qualified ref
  whose referenced axis is deleted collapses to the literal `#REF!` (the
  per-tab dead-ref spelling); a partially covered qualified range clips. Pure —
  reuses the same shift/clip arithmetic as `rewrite_formula/3`; only token
  recognition (the tab qualifier) is new.
  """
  @spec shift_cross_tab_refs(
          [map()],
          non_neg_integer(),
          :row | :col,
          {:insert | :delete, pos_integer(), pos_integer()}
        ) :: [map()]
  def shift_cross_tab_refs(tabs, target_index, axis, {kind, _at, _count} = change)
      when is_list(tabs) and is_integer(target_index) and axis in [:row, :col] and
             kind in [:insert, :delete] do
    case tab_name(Enum.at(tabs, target_index)) do
      name when is_binary(name) and name != "" ->
        Enum.map(tabs, &rewrite_tab_formulas(&1, {:sweep, name, axis, change}))

      _ ->
        tabs
    end
  end

  @doc """
  Rename every cross-tab qualifier `OldName!` / `'Old Name'!` to `new_name`
  across ALL tabs' formulas (Excel's rename-rewrite — CT-D1). The referenced
  cell/range is untouched; only the tab qualifier changes, re-quoted when
  `new_name` needs it (a space, punctuation, a leading digit or a ref-shaped
  name → `'…'`, a literal apostrophe doubled). Name matching is
  case-insensitive (Excel). Pure — `move_tab` has NO counterpart here because
  name-based refs are position-stable.
  """
  @spec rename_refs([map()], String.t(), String.t()) :: [map()]
  def rename_refs(tabs, old_name, new_name)
      when is_list(tabs) and is_binary(old_name) and is_binary(new_name) do
    Enum.map(tabs, &rewrite_tab_formulas(&1, {:rename, old_name, new_name}))
  end

  @doc """
  Rewrite every cross-tab reference to the deleted tab `deleted_name` to the
  literal `#REF!` across ALL tabs' formulas (Excel — CT-D1). The Session
  captures `deleted_name` before dropping the tab. Name matching is
  case-insensitive. Pure.
  """
  @spec delete_tab_refs([map()], String.t()) :: [map()]
  def delete_tab_refs(tabs, deleted_name) when is_list(tabs) and is_binary(deleted_name) do
    Enum.map(tabs, &rewrite_tab_formulas(&1, {:deltab, deleted_name}))
  end

  @doc """
  The cells of `tab` whose OWN (bare-ref) formula text the axis op `change`
  rewrites — keyed by their PRE-op address, carrying the PRE-op cell map
  (formula, computed value, style) VERBATIM.

  This is the lossless delete-undo capture. `delete_rows`/`delete_cols`
  collapses every dead ref to the literal `#REF!` and clips every partially
  covered range, and that rewrite is NOT invertible from the resulting text —
  the structural inverse has to carry the pre-rewrite cells or undo silently
  keeps the `#REF!`s. Cells INSIDE a deleted span are EXCLUDED: they vanish
  wholesale and the Session captures the span itself.

  Pure and BOUNDED — one entry per REWRITTEN formula, never a tab snapshot (a
  1000-cell tab with 3 rewritten formulas yields 3 entries). Cross-tab
  qualifiers are NOT this function's business (the local pass leaves them
  alone); `cross_tab_rewritten_cells/4` is their companion.
  """
  @spec rewritten_formula_cells(
          map(),
          :row | :col,
          {:insert | :delete, pos_integer(), pos_integer()}
        ) :: %{String.t() => map()}
  def rewritten_formula_cells(tab, axis, {kind, _at, _count} = change)
      when is_map(tab) and axis in [:row, :col] and kind in [:insert, :delete] do
    for {addr, cell} <- tab_cells(tab),
        is_map(cell),
        is_binary(Map.get(cell, "f")),
        {:ok, pos} <- [Sheets.parse_ref(addr)],
        shift_index(axis_index(pos, axis), axis, change) != :dead,
        rewrite_cell(cell, axis, change) != cell,
        into: %{} do
      {addr, cell}
    end
  end

  @doc """
  The cells whose CROSS-TAB refs `shift_cross_tab_refs/4` rewrites for the same
  arguments, as `%{tab_index => %{ref => pre-rewrite cell}}`.

  The companion capture to `rewritten_formula_cells/3`: a row/col delete on the
  tab at `target_index` collapses qualified refs to it (`Sheet2!A1`,
  `'My Tab'!A1:A9`) in EVERY tab's formulas — other tabs' and the mutated tab's
  own SELF-qualified ones, which the local pass passes through untouched. Undo
  cannot recover those from the text either.

  Addresses are each tab's own keys. Only the MUTATED tab's cells shift under
  the op, and the sweep keys on the tab NAME (address independent), so calling
  this on the PRE-op tabs yields the mutated tab's entry in PRE-op address
  space — the space the structural inverse restores into.

  Bounded the same way — one entry per rewritten formula, tabs with none
  omitted; `%{}` when the target tab has no usable name (nothing can reference
  it).
  """
  @spec cross_tab_rewritten_cells(
          [map()],
          non_neg_integer(),
          :row | :col,
          {:insert | :delete, pos_integer(), pos_integer()}
        ) :: %{non_neg_integer() => %{String.t() => map()}}
  def cross_tab_rewritten_cells(tabs, target_index, axis, {kind, _at, _count} = change)
      when is_list(tabs) and is_integer(target_index) and axis in [:row, :col] and
             kind in [:insert, :delete] do
    case tab_name(Enum.at(tabs, target_index)) do
      name when is_binary(name) and name != "" ->
        op = {:sweep, name, axis, change}

        for {tab, idx} <- Enum.with_index(tabs),
            is_map(tab),
            cells = swept_formula_cells(tab, op),
            map_size(cells) > 0,
            into: %{} do
          {idx, cells}
        end

      _ ->
        %{}
    end
  end

  defp swept_formula_cells(tab, op) do
    for {addr, cell} <- tab_cells(tab),
        is_map(cell),
        is_binary(Map.get(cell, "f")),
        rewrite_cell_formula(cell, op) != cell,
        into: %{} do
      {addr, cell}
    end
  end

  defp tab_name(tab) when is_map(tab), do: Map.get(tab, "name")
  defp tab_name(_), do: nil

  defp rewrite_tab_formulas(tab, op) when is_map(tab) do
    case Map.get(tab, "cells") do
      cells when is_map(cells) ->
        Map.put(
          tab,
          "cells",
          Map.new(cells, fn {addr, cell} -> {addr, rewrite_cell_formula(cell, op)} end)
        )

      _ ->
        tab
    end
  end

  defp rewrite_tab_formulas(tab, _op), do: tab

  defp rewrite_cell_formula(%{"f" => f} = cell, op) when is_binary(f),
    do: Map.put(cell, "f", scan(f, op, []) |> IO.iodata_to_binary())

  defp rewrite_cell_formula(cell, _op), do: cell

  # ── sort (SF-A) ────────────────────────────────────────────────────────────

  @type rect :: {pos_integer(), pos_integer(), pos_integer(), pos_integer()}
  @type sort_key :: %{required(String.t()) => term()}

  @doc """
  Sort the rows of `rect` in `tab` by `keys`, a PURE row permutation — see
  the moduledoc for the full contract (verbatim moves, the comparator
  ladder, the guards). `rect` is a 1-based `{c1, r1, c2, r2}` tuple
  (normalized, `c1 <= c2` / `r1 <= r2`); `keys` is a list of
  `%{"col" => absolute-0-based-col, "dir" => "asc" | "desc"}` evaluated
  left-to-right (multi-key). Returns `{:ok, new_tab, perm}` where `perm` is
  a list of the same length as the rect's rows mapping each old
  row-offset to its new position, or `{:error, code, message}` for a
  merge/frozen/keys guard refusal. An already-sorted rect returns the
  identity `perm` (the caller records no undo entry).
  """
  @spec sort_rows(map(), rect(), term()) :: {:ok, map(), [non_neg_integer()]} | error()
  def sort_rows(tab, {c1, r1, c2, r2} = rect, keys)
      when is_map(tab) and is_integer(c1) and is_integer(r1) and is_integer(c2) and
             is_integer(r2) and c1 <= c2 and r1 <= r2 do
    with :ok <- guard_merge(tab, rect),
         :ok <- guard_frozen(tab, rect),
         {:ok, keys} <- validate_keys(keys, rect) do
      perm = compute_perm(tab, rect, keys)
      {:ok, do_permute(tab, rect, perm), perm}
    end
  end

  @doc """
  Re-apply an EXPLICIT row permutation `perm` over `rect` in `tab` (the
  undo/redo applier for a stored sort). Returns `{:ok, new_tab, inverse}`
  where `inverse` re-applied over the same rect restores `tab` — verbatim
  moves both ways. Total: no guard re-run, a cell that has since moved out
  of the rect simply stays put (the merges lossy-undo contract).
  """
  @spec permute_rows(map(), rect(), [non_neg_integer()]) ::
          {:ok, map(), [non_neg_integer()]}
  def permute_rows(tab, rect, perm) when is_map(tab) and is_list(perm) do
    {:ok, do_permute(tab, rect, perm), invert_perm(perm)}
  end

  @doc """
  Invert a row permutation: given `perm` (old-offset → new-position),
  produce the list `inv` (new-position → old-offset) such that applying one
  after the other is the identity.
  """
  @spec invert_perm([non_neg_integer()]) :: [non_neg_integer()]
  def invert_perm(perm) when is_list(perm) do
    n = length(perm)
    m = perm |> Enum.with_index() |> Map.new(fn {new, old} -> {new, old} end)
    for i <- 0..(n - 1)//1, do: Map.fetch!(m, i)
  end

  # A merge intersecting the rect refuses the sort — a merged region can't be
  # split by a row permutation (SF-D5).
  defp guard_merge(tab, rect) do
    merges = Map.get(tab, "merges") || []

    if Enum.any?(merges, &merge_intersects?(&1, rect)) do
      {:error, "sort_merge_overlap",
       "the sort range intersects a merged region — unmerge it before sorting"}
    else
      :ok
    end
  end

  defp merge_intersects?(merge, {c1, r1, c2, r2}) when is_binary(merge) do
    case parse_rect(merge) do
      {:ok, {mc1, mr1, mc2, mr2}} -> not (mc2 < c1 or mc1 > c2 or mr2 < r1 or mr1 > r2)
      # An unparseable stored merge can only arrive via a malformed import the
      # before_save gate already rejects — treat it as disjoint.
      :error -> false
    end
  end

  defp merge_intersects?(_merge, _rect), do: false

  defp parse_rect(range) do
    with [a, b] <- String.split(range, ":"),
         {:ok, {ca, ra}} <- Sheets.parse_ref(a),
         {:ok, {cb, rb}} <- Sheets.parse_ref(b) do
      {:ok, {min(ca, cb), min(ra, rb), max(ca, cb), max(ra, rb)}}
    else
      _ -> :error
    end
  end

  # A rect reaching into the frozen head band refuses — callers pass rects
  # that start BELOW the band (EXCLUDE-BY-REFUSAL, SF-D5).
  defp guard_frozen(tab, {_c1, r1, _c2, _r2}) do
    frozen = frozen_rows_count(Map.get(tab, "frozen_rows"))

    if frozen > 0 and r1 <= frozen do
      {:error, "sort_frozen_overlap",
       "the sort range intersects the #{frozen} frozen header row(s) — start the range below them"}
    else
      :ok
    end
  end

  defp frozen_rows_count(n) when is_integer(n) and n >= 0, do: n

  defp frozen_rows_count(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp frozen_rows_count(_), do: 0

  # keys must be a list; every key a %{"col","dir"} with an absolute 0-based
  # col inside the rect and dir in asc/desc. An empty list is valid — it
  # yields the identity permutation (a stable no-op).
  defp validate_keys(keys, {c1, _r1, c2, _r2}) when is_list(keys) do
    if Enum.all?(keys, &valid_key?(&1, c1, c2)) do
      {:ok, keys}
    else
      {:error, "invalid_sort_keys",
       "keys must be a list of %{\"col\" => 0-based-col-inside-the-range, \"dir\" => \"asc\"|\"desc\"}"}
    end
  end

  defp validate_keys(_keys, _rect),
    do:
      {:error, "invalid_sort_keys",
       "keys must be a list of %{\"col\" => 0-based-col-inside-the-range, \"dir\" => \"asc\"|\"desc\"}"}

  defp valid_key?(%{"col" => col, "dir" => dir}, c1, c2)
       when is_integer(col) and (dir == "asc" or dir == "desc"),
       do: col >= c1 - 1 and col <= c2 - 1

  defp valid_key?(_key, _c1, _c2), do: false

  # Build the permutation: precompute each row-offset's rank per key (O(1)
  # tuple lookup), stably sort the offsets, then re-key offset → position.
  defp compute_perm(tab, {_c1, r1, _c2, r2}, keys) do
    n = r2 - r1 + 1
    cells = Map.get(tab, "cells") || %{}
    key_cols = Enum.map(keys, fn %{"col" => col, "dir" => dir} -> {col + 1, dir} end)
    dirs = Enum.map(key_cols, fn {_col1, dir} -> dir end)

    ranks =
      for i <- 0..(n - 1)//1 do
        Enum.map(key_cols, fn {col1, _dir} ->
          rank_cell(Map.get(cells, Sheets.format_ref({col1, r1 + i})))
        end)
      end
      |> List.to_tuple()

    order =
      0..(n - 1)//1
      |> Enum.to_list()
      |> Enum.sort(fn a, b -> compare_ranks(elem(ranks, a), elem(ranks, b), dirs) != :gt end)

    order_to_perm(order)
  end

  # order[new] = old  →  perm[old] = new
  defp order_to_perm(order) do
    m = order |> Enum.with_index() |> Map.new(fn {old, new} -> {old, new} end)
    for i <- 0..(map_size(m) - 1)//1, do: Map.fetch!(m, i)
  end

  # Multi-key: first non-:eq key decides; all-:eq keeps original order (the
  # stable sort does the rest).
  defp compare_ranks(ranks_a, ranks_b, dirs) do
    [ranks_a, ranks_b, dirs]
    |> Enum.zip()
    |> Enum.reduce_while(:eq, fn {a, b, dir}, _acc ->
      case key_cmp(a, b, dir) do
        :eq -> {:cont, :eq}
        cmp -> {:halt, cmp}
      end
    end)
  end

  # Blanks are ALWAYS last (both directions); everything else runs the
  # ascending ladder, flipped for a descending key.
  defp key_cmp(:blank, :blank, _dir), do: :eq
  defp key_cmp(:blank, _b, _dir), do: :gt
  defp key_cmp(_a, :blank, _dir), do: :lt

  defp key_cmp(a, b, "desc"), do: flip(ladder_cmp(a, b))
  defp key_cmp(a, b, _asc), do: ladder_cmp(a, b)

  defp ladder_cmp(a, b) do
    ta = tier(a)
    tb = tier(b)

    cond do
      ta < tb -> :lt
      ta > tb -> :gt
      true -> within_tier(a, b)
    end
  end

  defp tier({:num, _}), do: 1
  defp tier({:text, _}), do: 2
  defp tier(:false_), do: 3
  defp tier(:true_), do: 4
  defp tier(:error), do: 5

  defp within_tier({:num, x}, {:num, y}), do: scalar_cmp(x, y)
  defp within_tier({:text, x}, {:text, y}), do: scalar_cmp(x, y)
  # FALSE vs FALSE, TRUE vs TRUE, error vs error — same tier, all equal.
  defp within_tier(_a, _b), do: :eq

  defp scalar_cmp(x, y) do
    cond do
      x < y -> :lt
      x > y -> :gt
      true -> :eq
    end
  end

  defp flip(:lt), do: :gt
  defp flip(:gt), do: :lt
  defp flip(:eq), do: :eq

  # Classify a cell's computed value into a comparator rank (SF-D4). Error is
  # tested FIRST (the CF-D5 predicate expression, single-sourced inline);
  # then blank; then the value type. Cells store JSON scalars only.
  defp rank_cell(nil), do: :blank

  defp rank_cell(cell) when is_map(cell) do
    v = Map.get(cell, "v")
    t = Map.get(cell, "t")

    cond do
      is_binary(v) and (t == "e" or v in Engine.error_values()) -> :error
      is_nil(v) or v == "" -> :blank
      is_number(v) -> {:num, v}
      v == false -> :false_
      v == true -> :true_
      is_binary(v) -> {:text, String.downcase(v)}
      true -> :blank
    end
  end

  defp rank_cell(_cell), do: :blank

  # Apply an explicit permutation to the rect's row-slices. Only cells inside
  # the rect (cols c1..c2, rows r1..r2) re-key; every other cell stays. `perm`
  # is a bijection on the rect's rows, so moved cells never collide with each
  # other or with the untouched cells outside the region. The cell MAP value
  # is carried verbatim — v/f/fmt/s/t byte-identical, f never rewritten.
  defp do_permute(tab, {c1, r1, c2, r2}, perm) do
    perm_tup = List.to_tuple(perm)
    cells = Map.get(tab, "cells") || %{}

    new_cells =
      Map.new(cells, fn {addr, cell} ->
        case Sheets.parse_ref(addr) do
          {:ok, {col, row}} when col >= c1 and col <= c2 and row >= r1 and row <= r2 ->
            {Sheets.format_ref({col, r1 + elem(perm_tup, row - r1)}), cell}

          _ ->
            {addr, cell}
        end
      end)

    Map.put(tab, "cells", new_cells)
  end

  # ── axis ops ─────────────────────────────────────────────────────────────

  defp axis_op(tab, axis, {_kind, at, count} = change) when is_map(tab) do
    with :ok <- validate_at(at, axis),
         :ok <- validate_count(count),
         :ok <- check_insert_bounds(tab, axis, change) do
      {:ok,
       tab
       |> rewrite_cells(axis, change)
       |> rewrite_merges(axis, change)
       |> rewrite_cond_formats(axis, change)
       |> rekey_sizes(axis, change)
       |> adjust_frozen(axis, change)}
    end
  end

  defp validate_at(at, axis) do
    bound = axis_max(axis)

    if is_integer(at) and at >= 1 and at <= bound do
      :ok
    else
      {:error, "invalid_at", "at must be an integer between 1 and #{bound}, got #{inspect(at)}"}
    end
  end

  defp validate_count(count) do
    if is_integer(count) and count >= 1 do
      :ok
    else
      {:error, "invalid_count", "count must be a positive integer, got #{inspect(count)}"}
    end
  end

  # Cap-aware insert: the highest OCCUPIED index at/after the insert point
  # must still fit on the grid after shifting — otherwise the whole op
  # errors before touching anything (deletes can never overflow).
  defp check_insert_bounds(tab, axis, {:insert, at, count}) do
    bound = axis_max(axis)

    highest =
      for {addr, _cell} <- tab_cells(tab),
          {:ok, pos} <- [Sheets.parse_ref(addr)],
          axis_index(pos, axis) >= at,
          reduce: 0 do
        acc -> max(acc, axis_index(pos, axis))
      end

    if highest + count > bound do
      {:error, "grid_bounds_exceeded",
       "inserting #{count} would push occupied cells past the grid bound (#{bound})"}
    else
      :ok
    end
  end

  defp check_insert_bounds(_tab, _axis, {:delete, _at, _count}), do: :ok

  defp rewrite_cells(tab, axis, change) do
    case Map.get(tab, "cells") do
      cells when is_map(cells) ->
        rewritten =
          Enum.reduce(cells, %{}, fn {addr, cell}, acc ->
            case Sheets.parse_ref(addr) do
              {:ok, pos} ->
                case shift_index(axis_index(pos, axis), axis, change) do
                  :unchanged ->
                    Map.put(acc, addr, rewrite_cell(cell, axis, change))

                  :dead ->
                    acc

                  {:ok, idx} ->
                    Map.put(
                      acc,
                      Sheets.format_ref(put_axis(pos, axis, idx)),
                      rewrite_cell(cell, axis, change)
                    )
                end

              # Invalid keys never reach storage (the plugin gate); keep
              # whatever is there verbatim — totality over judgment.
              :error ->
                Map.put(acc, addr, cell)
            end
          end)

        Map.put(tab, "cells", rewritten)

      _ ->
        tab
    end
  end

  defp rewrite_cell(%{"f" => f} = cell, axis, change) when is_binary(f),
    do: Map.put(cell, "f", rewrite_formula(f, axis, change))

  defp rewrite_cell(cell, _axis, _change), do: cell

  defp rewrite_merges(tab, axis, change) do
    case Map.get(tab, "merges") do
      merges when is_list(merges) ->
        Map.put(tab, "merges", Enum.flat_map(merges, &rewrite_merge(&1, axis, change)))

      _ ->
        tab
    end
  end

  defp rewrite_merge(merge, axis, change) when is_binary(merge) do
    with [a, b] <- String.split(merge, ":"),
         {:ok, {c1, r1}} <- Sheets.parse_ref(a),
         {:ok, {c2, r2}} <- Sheets.parse_ref(b) do
      {lo_c, hi_c} = {min(c1, c2), max(c1, c2)}
      {lo_r, hi_r} = {min(r1, r2), max(r1, r2)}
      {lo, hi} = if axis == :row, do: {lo_r, hi_r}, else: {lo_c, hi_c}

      case shift_span(lo, hi, axis, change) do
        :dead ->
          []

        {:ok, {nlo, nhi}} ->
          {p1, p2} =
            case axis do
              :row -> {{lo_c, nlo}, {hi_c, nhi}}
              :col -> {{nlo, lo_r}, {nhi, hi_r}}
            end

          # A merge that clips down to a single cell carries no
          # information — drop it (the snapshot convention).
          if p1 == p2, do: [], else: [Sheets.format_ref(p1) <> ":" <> Sheets.format_ref(p2)]
      end
    else
      _ -> [merge]
    end
  end

  defp rewrite_merge(merge, _axis, _change), do: [merge]

  # Conditional-formatting rules rebase in this same axis_op pass, mirroring
  # rewrite_merge's arithmetic with ONE divergence (CF-D7): a range that
  # clips down to a single cell KEEPS its rule (a single-cell CF range is
  # meaningful — re-emit the "B2" single-cell form), where a merge would
  # drop. Fully-deleted or pushed-past-grid ranges drop the rule. Rules keep
  # list order and every non-range key verbatim. Malformed entries pass
  # through untouched (total, never raise). Undo stays the merges lossy
  # contract — dropped/clipped rules are NOT resurrected, no new inverse
  # shapes (byte-identical to rewrite_merge's undo story).
  defp rewrite_cond_formats(tab, axis, change) do
    case Map.get(tab, "cond_formats") do
      cfs when is_list(cfs) ->
        rewritten =
          cfs
          |> Enum.flat_map(&rewrite_cond_format(&1, axis, change))
          |> dedupe_cond_format_ranges()

        Map.put(tab, "cond_formats", rewritten)

      _ ->
        tab
    end
  end

  # A delete can clip two DISTINCT ranges down to the same normalized range
  # (B2:B3 and B2:B4 both collapse to "B2" when rows 3-4 go). The gate
  # rejects duplicate normalized ranges (CF-D4), so leaving both would make
  # the doc unpersistable — the session's debounced flush would halt on its
  # own save gate forever. Keep the FIRST rule per normalized range (list
  # order — the rule first-match-wins eval prefers anyway) and drop later
  # collisions: one more facet of the documented lossy rebase contract.
  # Entries whose range does not parse never join the dedupe (totality).
  # Insert is injective on surviving spans, so this is a no-op there.
  defp dedupe_cond_format_ranges(cfs) do
    {out, _seen} =
      Enum.reduce(cfs, {[], MapSet.new()}, fn rule, {acc, seen} ->
        with %{"range" => range} when is_binary(range) <- rule,
             {:ok, corners} <- cf_range_corners(range) do
          if MapSet.member?(seen, corners) do
            {acc, seen}
          else
            {[rule | acc], MapSet.put(seen, corners)}
          end
        else
          _ -> {[rule | acc], seen}
        end
      end)

    Enum.reverse(out)
  end

  defp rewrite_cond_format(%{"range" => range} = rule, axis, change) when is_binary(range) do
    case cf_range_corners(range) do
      {:ok, {c1, r1, c2, r2}} ->
        {lo, hi} = if axis == :row, do: {r1, r2}, else: {c1, c2}

        case shift_span(lo, hi, axis, change) do
          :dead ->
            []

          {:ok, {nlo, nhi}} ->
            {p1, p2} =
              case axis do
                :row -> {{c1, nlo}, {c2, nhi}}
                :col -> {{nlo, r1}, {nhi, r2}}
              end

            [Map.put(rule, "range", cf_emit_range(p1, p2))]
        end

      :error ->
        [rule]
    end
  end

  defp rewrite_cond_format(rule, _axis, _change), do: [rule]

  # Normalize a CF range string to {lo_col, lo_row, hi_col, hi_row}; "B2"
  # folds to the same corners as "B2:B2".
  defp cf_range_corners(range) do
    case String.split(range, ":") do
      [a] -> cf_corner_pair(a, a)
      [a, b] -> cf_corner_pair(a, b)
      _ -> :error
    end
  end

  defp cf_corner_pair(a, b) do
    with {:ok, {c1, r1}} <- Sheets.parse_ref(a),
         {:ok, {c2, r2}} <- Sheets.parse_ref(b) do
      {:ok, {min(c1, c2), min(r1, r2), max(c1, c2), max(r1, r2)}}
    else
      _ -> :error
    end
  end

  # A 1×1 result re-emits the single-cell form (the CF divergence); anything
  # larger stays an A1:B2 range.
  defp cf_emit_range(p1, p2) do
    if p1 == p2,
      do: Sheets.format_ref(p1),
      else: Sheets.format_ref(p1) <> ":" <> Sheets.format_ref(p2)
  end

  defp rekey_sizes(tab, axis, change) do
    key = if axis == :row, do: "row_heights", else: "col_widths"

    case Map.get(tab, key) do
      sizes when is_map(sizes) ->
        rekeyed =
          Enum.reduce(sizes, %{}, fn {k, v}, acc ->
            case Integer.parse(k) do
              {idx, ""} when idx >= 1 ->
                case shift_index(idx, axis, change) do
                  :unchanged -> Map.put(acc, k, v)
                  :dead -> acc
                  {:ok, n} -> Map.put(acc, Integer.to_string(n), v)
                end

              _ ->
                Map.put(acc, k, v)
            end
          end)

        Map.put(tab, key, rekeyed)

      _ ->
        tab
    end
  end

  # Frozen bands are positional: inserts leave them put; a delete shrinks
  # the band by its overlap with the deleted span.
  defp adjust_frozen(tab, _axis, {:insert, _at, _count}), do: tab

  defp adjust_frozen(tab, axis, {:delete, at, count}) do
    key = if axis == :row, do: "frozen_rows", else: "frozen_cols"

    case frozen_count(Map.get(tab, key)) do
      {n, type} when n > 0 ->
        overlap = max(0, min(at + count - 1, n) - at + 1)
        put_frozen(tab, key, n - overlap, type)

      _ ->
        tab
    end
  end

  defp frozen_count(n) when is_integer(n), do: {n, :int}

  defp frozen_count(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {n, :string}
      _ -> :none
    end
  end

  defp frozen_count(_), do: :none

  defp put_frozen(tab, key, n, :int), do: Map.put(tab, key, n)
  defp put_frozen(tab, key, n, :string), do: Map.put(tab, key, Integer.to_string(n))

  # set_frozen band write: 0 deletes the key (sparse convention), a
  # positive band writes the integer.
  defp write_frozen(tab, key, 0), do: Map.delete(tab, key)
  defp write_frozen(tab, key, n), do: Map.put(tab, key, n)

  # ── layout setters ───────────────────────────────────────────────────────

  defp set_size(tab, key, axis_name, bound, idx, px) when is_map(tab) do
    cond do
      not (is_integer(idx) and idx >= 1 and idx <= bound) ->
        {:error, "invalid_index",
         "#{axis_name} must be an integer between 1 and #{bound}, got #{inspect(idx)}"}

      not (is_nil(px) or (is_number(px) and px > 0)) ->
        {:error, "invalid_px", "px must be a positive number or null, got #{inspect(px)}"}

      true ->
        sizes =
          case Map.get(tab, key) do
            m when is_map(m) -> m
            _ -> %{}
          end

        sizes =
          case px do
            nil -> Map.delete(sizes, Integer.to_string(idx))
            px -> Map.put(sizes, Integer.to_string(idx), round(px))
          end

        {:ok, Map.put(tab, key, sizes)}
    end
  end

  # ── index shifting ───────────────────────────────────────────────────────
  #
  # shift_index/3 → :unchanged | :dead | {:ok, new_index} for one 1-based
  # index on the changed axis; shift_span/4 adjusts a normalized lo..hi
  # span (range corner pair, merge rectangle) with Excel's clip rules.

  defp shift_index(idx, axis, {:insert, at, count}) do
    cond do
      idx < at -> :unchanged
      idx + count > axis_max(axis) -> :dead
      true -> {:ok, idx + count}
    end
  end

  defp shift_index(idx, _axis, {:delete, at, count}) do
    cond do
      idx < at -> :unchanged
      idx <= at + count - 1 -> :dead
      true -> {:ok, idx - count}
    end
  end

  defp shift_span(lo, hi, axis, {:insert, _at, _count} = change) do
    with {:ok, nlo} <- span_point(lo, axis, change),
         {:ok, nhi} <- span_point(hi, axis, change) do
      {:ok, {nlo, nhi}}
    else
      _ -> :dead
    end
  end

  defp shift_span(lo, hi, _axis, {:delete, at, count}) do
    span_end = at + count - 1

    if lo >= at and hi <= span_end do
      :dead
    else
      nlo =
        cond do
          lo > span_end -> lo - count
          lo >= at -> at
          true -> lo
        end

      nhi =
        cond do
          hi > span_end -> hi - count
          hi >= at -> at - 1
          true -> hi
        end

      {:ok, {nlo, nhi}}
    end
  end

  defp span_point(idx, axis, change) do
    case shift_index(idx, axis, change) do
      :unchanged -> {:ok, idx}
      :dead -> :dead
      {:ok, n} -> {:ok, n}
    end
  end

  defp axis_max(:row), do: @grid_max_row
  defp axis_max(:col), do: @grid_max_col

  defp axis_index({_col, row}, :row), do: row
  defp axis_index({col, _row}, :col), do: col

  defp put_axis({col, _row}, :row, idx), do: {col, idx}
  defp put_axis({_col, row}, :col, idx), do: {idx, row}

  defp tab_cells(tab) do
    case Map.get(tab, "cells") do
      cells when is_map(cells) -> cells
      _ -> %{}
    end
  end

  # ── formula scanner ──────────────────────────────────────────────────────
  #
  # Mirrors the engine's lexer surface: double-quoted string literals with ""
  # escaping, single-quoted tab-name qualifiers with '' escaping, the `!` tab
  # separator, word charset [A-Za-z0-9_$], a ref-shaped word followed by "(" is
  # a function name. Emits iodata; everything not rewritten stays verbatim.
  #
  # `op` selects what each recognized ref/range becomes:
  #   {:local, axis, change}       — the mutated tab's OWN rewrite
  #        (rewrite_formula / rebase_formula): a BARE ref shifts/rebases; a
  #        tab-QUALIFIED ref passes through untouched on an insert/delete (the
  #        cross-tab sweep owns those) and rebases its cell part on a copy/fill.
  #   {:sweep, name, axis, change} — a structural insert/delete on the tab
  #        `name`: shift ONLY qualified refs to that tab; bare refs and refs to
  #        other tabs pass through.
  #   {:rename, old, new}          — rewrite the qualifier of every ref to `old`
  #        into `new` (re-quoted as needed); the cell part is verbatim.
  #   {:deltab, name}              — a ref to the deleted tab `name` becomes the
  #        literal #REF!; everything else is verbatim.

  defp scan(<<>>, _op, out), do: Enum.reverse(out)

  defp scan(<<?", rest::binary>>, op, out) do
    {lit, rest2} = take_string(rest, ["\""])
    scan(rest2, op, [lit | out])
  end

  # A single quote opens a quoted tab-name qualifier (`'My Sheet'!A1`). If it
  # does not form a complete qualified ref, the quote is emitted verbatim and
  # scanning resumes after it (fail-soft — byte-identical to the old pass).
  defp scan(<<?', rest::binary>>, op, out) do
    case take_quoted_qualifier(rest) do
      {name, qsrc, ref_spec, rest2} ->
        scan(rest2, op, [handle_qualified(op, name, qsrc, ref_spec) | out])

      :none ->
        scan(rest, op, ["'" | out])
    end
  end

  defp scan(<<c, _::binary>> = bin, op, out)
       when c in ?a..?z or c in ?A..?Z or c == ?_ or c == ?$ do
    {word, rest} = take_word(bin, "")

    case take_qualified_tail(rest) do
      # A bare tab name immediately followed by `!ref` / `!ref:ref`.
      {ref_spec, rest2} ->
        scan(rest2, op, [handle_qualified(op, word, word, ref_spec) | out])

      :none ->
        cond do
          ref_like?(word) and next_is_lparen?(rest) ->
            scan(rest, op, [word | out])

          ref_like?(word) ->
            case take_range_tail(rest) do
              {:range, sep, word2, rest2} ->
                scan(rest2, op, [bare_range(op, word, sep, word2) | out])

              :single ->
                scan(rest, op, [bare_ref(op, word) | out])
            end

          # A full-COLUMN range: `A:A`, `$A:$C` — bare letters, optional `$`, NO
          # digit (so it can never collide with a `ref_like?` cell ref). Only a
          # real `col :colon col` tail makes it a range; a lone column word
          # (`A`, a function name, a defined name) emits verbatim, exactly as the
          # old `not ref_like?` bail did.
          col_axis?(word) ->
            case take_axis_tail(rest, &col_axis?/1) do
              {sep, word2, rest2} ->
                scan(rest2, op, [bare_axis(op, :col, word, sep, word2) | out])

              :none ->
                scan(rest, op, [word | out])
            end

          true ->
            scan(rest, op, [word | out])
        end
    end
  end

  # A full-ROW range starts with a DIGIT (`3:3`, `1:5`), so it never reaches the
  # letter clause above. Recognize `num :colon num` as a single row-range token;
  # anything else (a bare number, `1+2`, `3.5`, `3E10`) falls through
  # byte-identically to the utf8 catch-all — emit the first char and resume.
  defp scan(<<c, _::binary>> = bin, op, out) when c in ?0..?9 do
    {word, rest} = take_word(bin, "")

    with true <- row_axis?(word),
         {sep, word2, rest2} <- take_axis_tail(rest, &row_axis?/1) do
      scan(rest2, op, [bare_axis(op, :row, word, sep, word2) | out])
    else
      _ ->
        <<ch::utf8, tail::binary>> = bin
        scan(tail, op, [<<ch::utf8>> | out])
    end
  end

  defp scan(<<c::utf8, rest::binary>>, op, out),
    do: scan(rest, op, [<<c::utf8>> | out])

  # A bare (unqualified) ref/range only shifts under a {:local, …} op; under
  # the cross-tab ops it is another tab's business — pass it through verbatim.
  defp bare_ref({:local, axis, change}, word), do: rewrite_ref(word, axis, change)
  defp bare_ref(_op, word), do: word

  defp bare_range({:local, axis, change}, w1, sep, w2),
    do: rewrite_range(w1, sep, w2, axis, change)

  defp bare_range(_op, w1, sep, w2), do: [w1, sep, w2]

  # A bare (unqualified) full-axis range (`A:A` / `3:3`). Shifts only under the
  # mutated tab's OWN op ({:local, …}) AND only when the range's axis matches the
  # mutated axis — a full COLUMN is invariant under row ops and a full ROW is
  # invariant under column ops (Excel). Under a cross-tab sweep/rename/deltab it
  # is another tab's business — pass through verbatim.
  defp bare_axis({:local, _mut_axis, {:rebase, dc, dr}}, kind, w1, sep, w2),
    do: rebase_axis(kind, w1, sep, w2, dc, dr)

  defp bare_axis({:local, mut_axis, change}, kind, w1, sep, w2),
    do: shift_axis(kind, mut_axis, w1, sep, w2, change)

  defp bare_axis(_op, _kind, w1, sep, w2), do: [w1, sep, w2]

  # `!ref` / `!ref:ref` tail immediately after a (bare or quoted) tab name.
  # Returns the ref spec + the remaining input, or :none when what follows is
  # not a valid reference (leave the name as an ordinary word).
  defp take_qualified_tail(<<?!, rest::binary>>) do
    {word, rest2} = take_word(rest, "")

    cond do
      word != "" and ref_like?(word) and not next_is_lparen?(rest2) ->
        case take_range_tail(rest2) do
          # A range whose second corner is ITSELF a qualifier (`Sheet2!A1:Sheet3!B2`)
          # is a two-tab range — not the single-tab range this scanner shifts (the
          # design makes two-tab ranges `#REF!` at eval; formula text is stored
          # verbatim under CT-D1, so such a string can reach Structure). Qualify
          # only the FIRST corner and hand the `:` + second qualifier back to the
          # scanner: each side then shifts under its own tab. Without this, the
          # bare second corner (`Sheet3`) parses as a ref and mis-shifts (e.g. a
          # row op turns `Sheet3` into `SHEET4`), corrupting the stored formula.
          {:range, _sep, _word2, <<?!, _::binary>>} -> {{:single, word}, rest2}
          {:range, sep, word2, rest3} -> {{:range, word, sep, word2}, rest3}
          :single -> {{:single, word}, rest2}
        end

      # A tab-qualified full-COLUMN range: `Sheet2!A:A`, `'My Sheet'!$A:$C`.
      word != "" and col_axis?(word) ->
        case take_axis_tail(rest2, &col_axis?/1) do
          {sep, word2, rest3} -> {{:arange, :col, word, sep, word2}, rest3}
          :none -> :none
        end

      # A tab-qualified full-ROW range: `Sheet2!3:3`.
      word != "" and row_axis?(word) ->
        case take_axis_tail(rest2, &row_axis?/1) do
          {sep, word2, rest3} -> {{:arange, :row, word, sep, word2}, rest3}
          :none -> :none
        end

      true ->
        :none
    end
  end

  defp take_qualified_tail(_), do: :none

  # A `'…'!ref` qualifier: parse the quoted name body ('' → literal '), require
  # a `!ref`/`!ref:ref` tail. Returns {decoded_name, original_qualifier_source,
  # ref_spec, rest} or :none.
  defp take_quoted_qualifier(bin) do
    case take_quoted_body(bin, "") do
      {:ok, raw, rest} ->
        case take_qualified_tail(rest) do
          {ref_spec, rest2} ->
            {String.replace(raw, "''", "'"), "'" <> raw <> "'", ref_spec, rest2}

          :none ->
            :none
        end

      :error ->
        :none
    end
  end

  # Quoted-name body up to the closing quote; `''` is an escaped apostrophe.
  # `raw` keeps the source spelling verbatim (doubled quotes intact) so an
  # untouched qualifier re-emits byte-identically. An unterminated body fails.
  defp take_quoted_body(<<?', ?', rest::binary>>, raw),
    do: take_quoted_body(rest, <<raw::binary, "''">>)

  defp take_quoted_body(<<?', rest::binary>>, raw), do: {:ok, raw, rest}

  defp take_quoted_body(<<c::utf8, rest::binary>>, raw),
    do: take_quoted_body(rest, <<raw::binary, c::utf8>>)

  defp take_quoted_body(<<>>, _raw), do: :error

  # Transform one qualified ref/range per the active op. `qsrc` is the original
  # qualifier source (bare word or `'…'`), `name` its decoded form.
  defp handle_qualified({:local, _axis, {:rebase, dc, dr}}, _name, qsrc, ref_spec),
    do: qualified_transform(qsrc, ref_spec, :col, {:rebase, dc, dr})

  defp handle_qualified({:local, _axis, _insert_or_delete}, _name, qsrc, ref_spec),
    do: qualified_emit(qsrc, ref_spec)

  defp handle_qualified({:sweep, target, axis, change}, name, qsrc, ref_spec) do
    if names_match?(name, target),
      do: qualified_transform(qsrc, ref_spec, axis, change),
      else: qualified_emit(qsrc, ref_spec)
  end

  defp handle_qualified({:rename, old, new}, name, qsrc, ref_spec) do
    if names_match?(name, old),
      do: qualified_emit(emit_qualifier(new), ref_spec),
      else: qualified_emit(qsrc, ref_spec)
  end

  defp handle_qualified({:deltab, del}, name, qsrc, ref_spec) do
    if names_match?(name, del),
      do: "#REF!",
      else: qualified_emit(qsrc, ref_spec)
  end

  # Re-emit a qualified ref verbatim (only the qualifier text `qual` varies —
  # the referenced cell/range keeps its exact source spelling). The full-axis
  # (`Name!A:A`) part is verbatim too — rename/deltab must never corrupt it.
  defp qualified_emit(qual, {:single, w}), do: [qual, "!", w]
  defp qualified_emit(qual, {:range, w1, sep, w2}), do: [qual, "!", w1, sep, w2]
  defp qualified_emit(qual, {:arange, _kind, w1, sep, w2}), do: [qual, "!", w1, sep, w2]

  # Shift/rebase a qualified ref's cell part, keeping the qualifier; a dead ref
  # or fully-deleted range collapses the WHOLE token to the literal #REF!.
  defp qualified_transform(qual, {:single, w}, axis, change) do
    case rewrite_ref(w, axis, change) do
      "#REF!" -> "#REF!"
      ref -> [qual, "!", ref]
    end
  end

  defp qualified_transform(qual, {:range, w1, sep, w2}, axis, change) do
    case rewrite_range(w1, sep, w2, axis, change) do
      "#REF!" -> "#REF!"
      part -> [qual, "!", part]
    end
  end

  # A qualified full-axis range shifts (or rebases) its axis part under the same
  # rules as a bare one: a full COLUMN shifts on col ops / is invariant on row
  # ops, a full ROW mirrors. A fully-deleted axis collapses the WHOLE token to
  # #REF!; the qualifier is preserved otherwise.
  defp qualified_transform(qual, {:arange, kind, w1, sep, w2}, mut_axis, change) do
    part =
      case change do
        {:rebase, dc, dr} -> rebase_axis(kind, w1, sep, w2, dc, dr)
        _ -> shift_axis(kind, mut_axis, w1, sep, w2, change)
      end

    case part do
      "#REF!" -> "#REF!"
      part -> [qual, "!", part]
    end
  end

  # Sheet names match case-insensitively (Excel).
  defp names_match?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp names_match?(_a, _b), do: false

  # Canonical qualifier text for a tab name: bare when it is a simple,
  # non-ref-shaped identifier; otherwise `'…'` with any apostrophe doubled.
  defp emit_qualifier(name) do
    if name_needs_quote?(name),
      do: "'" <> String.replace(name, "'", "''") <> "'",
      else: name
  end

  defp name_needs_quote?(name),
    do: not (Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, name) and not ref_like?(name))

  # String literal body, verbatim (quotes and "" escapes included); an
  # unterminated literal runs to the end — the engine rejects it anyway.
  defp take_string(<<?", ?", rest::binary>>, acc), do: take_string(rest, [acc, "\"\""])
  defp take_string(<<?", rest::binary>>, acc), do: {[acc, "\""], rest}
  defp take_string(<<c::utf8, rest::binary>>, acc), do: take_string(rest, [acc, <<c::utf8>>])
  defp take_string(<<>>, acc), do: {acc, ""}

  defp take_word(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ or c == ?$,
       do: take_word(rest, <<acc::binary, c>>)

  defp take_word(bin, acc), do: {acc, bin}

  defp ref_like?(word), do: Regex.match?(~r/^\$?[A-Za-z]+\$?[0-9]+$/, word)

  # A full-column word — bare letters with an optional leading `$`, NO digit
  # (`A`, `$A`, `AA`). Disjoint from `ref_like?` (which requires a digit), so a
  # cell ref like `A1` never lexes as a column word.
  defp col_axis?(word), do: Regex.match?(~r/^\$?[A-Za-z]+$/, word)

  # A full-row word — bare digits (`3`, `1048576`). The engine grammar spells a
  # row axis as a plain integer (no `$`); `$3` is left as ordinary text — it is
  # not corrupted, only not shifted.
  defp row_axis?(word), do: Regex.match?(~r/^[0-9]+$/, word)

  defp next_is_lparen?(<<?\s, rest::binary>>), do: next_is_lparen?(rest)
  defp next_is_lparen?(<<?(, _::binary>>), do: true
  defp next_is_lparen?(_), do: false

  # `ref ws* : ws* ref` is a range (the engine's tokenizer skips the
  # whitespace) — unless the second word is a call (`A1:LOG10(...)`).
  defp take_range_tail(rest) do
    {ws1, r1} = take_ws(rest, "")

    case r1 do
      <<?:, r2::binary>> ->
        {ws2, r3} = take_ws(r2, "")
        {word2, r4} = take_word(r3, "")

        if word2 != "" and ref_like?(word2) and not next_is_lparen?(r4) do
          {:range, [ws1, ":", ws2], word2, r4}
        else
          :single
        end

      _ ->
        :single
    end
  end

  # `word ws* : ws* word2` where BOTH sides satisfy `acceptor` (both column
  # words, or both row words) — a full-axis range. Whitespace is preserved in
  # the separator (the engine's tokenizer skips it). A second word that is a
  # call (`A:LOG10(...)`) is NOT a range.
  defp take_axis_tail(rest, acceptor) do
    {ws1, r1} = take_ws(rest, "")

    case r1 do
      <<?:, r2::binary>> ->
        {ws2, r3} = take_ws(r2, "")
        {word2, r4} = take_word(r3, "")

        if word2 != "" and acceptor.(word2) and not next_is_lparen?(r4) do
          {[ws1, ":", ws2], word2, r4}
        else
          :none
        end

      _ ->
        :none
    end
  end

  defp take_ws(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\r, ?\n],
    do: take_ws(rest, <<acc::binary, c>>)

  defp take_ws(bin, acc), do: {acc, bin}

  defp rewrite_ref(word, _axis, {:rebase, dc, dr}) do
    case parse_word(word) do
      :error ->
        word

      {{col, row}, {col_abs, row_abs} = flags} ->
        ncol = if col_abs, do: col, else: col + dc
        nrow = if row_abs, do: row, else: row + dr

        if ncol in 1..@grid_max_col and nrow in 1..@grid_max_row,
          do: emit_ref({ncol, nrow}, flags),
          else: "#REF!"
    end
  end

  defp rewrite_ref(word, axis, change) do
    case parse_word(word) do
      :error ->
        word

      {pos, flags} ->
        case shift_index(axis_index(pos, axis), axis, change) do
          :unchanged -> word
          :dead -> "#REF!"
          {:ok, idx} -> emit_ref(put_axis(pos, axis, idx), flags)
        end
    end
  end

  defp rewrite_range(w1, sep, w2, axis, {:rebase, _, _} = change) do
    r1 = rewrite_ref(w1, axis, change)
    r2 = rewrite_ref(w2, axis, change)
    if r1 == "#REF!" or r2 == "#REF!", do: "#REF!", else: [r1, sep, r2]
  end

  defp rewrite_range(w1, sep, w2, axis, change) do
    with {p1, _f1} <- parse_word(w1),
         {p2, _f2} <- parse_word(w2) do
      i1 = axis_index(p1, axis)
      i2 = axis_index(p2, axis)
      {lo, hi} = {min(i1, i2), max(i1, i2)}

      case change do
        # Exactly one corner inside the deleted span — the range CLIPS;
        # re-emit canonical $-less corners against the normalized rect.
        {:delete, at, count}
        when (lo >= at and lo <= at + count - 1) or (hi >= at and hi <= at + count - 1) ->
          case shift_span(lo, hi, axis, {:delete, at, count}) do
            :dead -> "#REF!"
            {:ok, {nlo, nhi}} -> emit_clipped(p1, p2, axis, nlo, nhi)
          end

        # Pure per-corner shifting (every insert; a delete that only
        # shifts) — each corner keeps its own text when untouched.
        _ ->
          r1 = rewrite_ref(w1, axis, change)
          r2 = rewrite_ref(w2, axis, change)
          if r1 == "#REF!" or r2 == "#REF!", do: "#REF!", else: [r1, sep, r2]
      end
    else
      _ -> [w1, sep, w2]
    end
  end

  defp emit_clipped({c1, r1}, {c2, r2}, axis, nlo, nhi) do
    {p1, p2} =
      case axis do
        :row -> {{min(c1, c2), nlo}, {max(c1, c2), nhi}}
        :col -> {{nlo, min(r1, r2)}, {nhi, max(r1, r2)}}
      end

    Sheets.format_ref(p1) <> ":" <> Sheets.format_ref(p2)
  end

  # ── full-axis (A:A / 3:3) shifting ─────────────────────────────────────────
  #
  # A full-COLUMN range (`A:A`, `$A:$C`) is unbounded on rows; a full-ROW range
  # (`3:3`) is unbounded on columns. Each shifts ONLY on the axis it bounds —
  # `shift_axis/6` returns the argument verbatim on the perpendicular op (the
  # Excel invariant). The bounded axis reuses the SAME `shift_index`/`shift_span`
  # arithmetic as a cell ref/range: per-corner shift on inserts and pure-shift
  # deletes, a clip (re-emitted as canonical `$`-less corners) when exactly one
  # corner sits inside a deleted span, `#REF!` when the axis is fully deleted.

  defp shift_axis(:col, :col, w1, sep, w2, change), do: rewrite_col_axis(w1, sep, w2, change)
  defp shift_axis(:row, :row, w1, sep, w2, change), do: rewrite_row_axis(w1, sep, w2, change)
  defp shift_axis(_kind, _mut_axis, w1, sep, w2, _change), do: [w1, sep, w2]

  defp rewrite_col_axis(w1, sep, w2, change) do
    with {:ok, c1, _a1} <- parse_col_word(w1),
         {:ok, c2, _a2} <- parse_col_word(w2) do
      {lo, hi} = {min(c1, c2), max(c1, c2)}

      case change do
        {:delete, at, count}
        when (lo >= at and lo <= at + count - 1) or (hi >= at and hi <= at + count - 1) ->
          case shift_span(lo, hi, :col, change) do
            :dead -> "#REF!"
            {:ok, {nlo, nhi}} -> col_letters(nlo) <> ":" <> col_letters(nhi)
          end

        _ ->
          shift_col_corners(w1, sep, w2, change)
      end
    else
      _ -> [w1, sep, w2]
    end
  end

  defp shift_col_corners(w1, sep, w2, change) do
    r1 = rewrite_col_word(w1, change)
    r2 = rewrite_col_word(w2, change)
    if r1 == "#REF!" or r2 == "#REF!", do: "#REF!", else: [r1, sep, r2]
  end

  defp rewrite_col_word(word, change) do
    case parse_col_word(word) do
      {:ok, col, abs?} ->
        case shift_index(col, :col, change) do
          :unchanged -> word
          :dead -> "#REF!"
          {:ok, ncol} -> emit_col_word(ncol, abs?)
        end

      :error ->
        word
    end
  end

  defp rewrite_row_axis(w1, sep, w2, change) do
    with {:ok, r1i} <- parse_row_word(w1),
         {:ok, r2i} <- parse_row_word(w2) do
      {lo, hi} = {min(r1i, r2i), max(r1i, r2i)}

      case change do
        {:delete, at, count}
        when (lo >= at and lo <= at + count - 1) or (hi >= at and hi <= at + count - 1) ->
          case shift_span(lo, hi, :row, change) do
            :dead -> "#REF!"
            {:ok, {nlo, nhi}} -> "#{nlo}:#{nhi}"
          end

        _ ->
          shift_row_corners(w1, sep, w2, change)
      end
    else
      _ -> [w1, sep, w2]
    end
  end

  defp shift_row_corners(w1, sep, w2, change) do
    r1 = rewrite_row_word(w1, change)
    r2 = rewrite_row_word(w2, change)
    if r1 == "#REF!" or r2 == "#REF!", do: "#REF!", else: [r1, sep, r2]
  end

  defp rewrite_row_word(word, change) do
    case parse_row_word(word) do
      {:ok, row} ->
        case shift_index(row, :row, change) do
          :unchanged -> word
          :dead -> "#REF!"
          {:ok, nrow} -> Integer.to_string(nrow)
        end

      :error ->
        word
    end
  end

  # Copy/fill rebase for a full-axis range: a full COLUMN shifts by `dc` (rows
  # ignored — it is row-unbounded), a full ROW shifts by `dr`. An absolute
  # (`$`-anchored) column is pinned; a shift out of bounds collapses to #REF!.
  defp rebase_axis(:col, w1, sep, w2, dc, _dr) do
    r1 = rebase_col_word(w1, dc)
    r2 = rebase_col_word(w2, dc)
    if r1 == "#REF!" or r2 == "#REF!", do: "#REF!", else: [r1, sep, r2]
  end

  defp rebase_axis(:row, w1, sep, w2, _dc, dr) do
    r1 = rebase_row_word(w1, dr)
    r2 = rebase_row_word(w2, dr)
    if r1 == "#REF!" or r2 == "#REF!", do: "#REF!", else: [r1, sep, r2]
  end

  defp rebase_col_word(word, dc) do
    case parse_col_word(word) do
      {:ok, _col, true} ->
        word

      {:ok, col, false} ->
        if (col + dc) in 1..@grid_max_col, do: col_letters(col + dc), else: "#REF!"

      :error ->
        word
    end
  end

  defp rebase_row_word(word, dr) do
    case parse_row_word(word) do
      {:ok, row} ->
        if (row + dr) in 1..@grid_max_row, do: Integer.to_string(row + dr), else: "#REF!"

      :error ->
        word
    end
  end

  # A column word (`A`, `$A`) → {:ok, col, absolute?}; a row word → {:ok, row}.
  # Out-of-bounds words fail so the token re-emits verbatim (never corrupted).
  defp parse_col_word(word) do
    {abs?, letters} =
      case word do
        <<?$, rest::binary>> -> {true, rest}
        _ -> {false, word}
      end

    case Sheets.parse_ref(letters <> "1") do
      {:ok, {col, 1}} when col <= @grid_max_col -> {:ok, col, abs?}
      _ -> :error
    end
  end

  defp parse_row_word(word) do
    case Integer.parse(word) do
      {n, ""} when n >= 1 and n <= @grid_max_row -> {:ok, n}
      _ -> :error
    end
  end

  defp col_letters(col) do
    [_, letters, _digits] = Regex.run(@split_re, Sheets.format_ref({col, 1}))
    letters
  end

  defp emit_col_word(col, true), do: "$" <> col_letters(col)
  defp emit_col_word(col, false), do: col_letters(col)

  defp parse_word(word) do
    with [_, d1, _letters, d2, _digits] <- Regex.run(@ref_re, word),
         {:ok, pos} <- Sheets.parse_ref(String.replace(word, "$", "")) do
      {pos, {d1 == "$", d2 == "$"}}
    else
      _ -> :error
    end
  end

  defp emit_ref(pos, {dc, dr}) do
    [_, letters, digits] = Regex.run(@split_re, Sheets.format_ref(pos))
    dollar(dc) <> letters <> dollar(dr) <> digits
  end

  defp dollar(true), do: "$"
  defp dollar(false), do: ""
end
