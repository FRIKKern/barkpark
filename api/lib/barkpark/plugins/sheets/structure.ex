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
      merges drop;
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
  """

  alias Barkpark.Plugins.Sheets.Core, as: Sheets

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
    scan(f, axis, change, []) |> IO.iodata_to_binary()
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
    scan(f, :col, {:rebase, dcol, drow}, []) |> IO.iodata_to_binary()
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
  # Mirrors the engine's lexer surface: string literals with "" escaping,
  # word charset [A-Za-z0-9_$], a ref-shaped word followed by "(" is a
  # function name. Emits iodata; everything not rewritten stays verbatim.

  defp scan(<<>>, _axis, _change, out), do: Enum.reverse(out)

  defp scan(<<?", rest::binary>>, axis, change, out) do
    {lit, rest2} = take_string(rest, ["\""])
    scan(rest2, axis, change, [lit | out])
  end

  defp scan(<<c, _::binary>> = bin, axis, change, out)
       when c in ?a..?z or c in ?A..?Z or c == ?_ or c == ?$ do
    {word, rest} = take_word(bin, "")

    cond do
      not ref_like?(word) ->
        scan(rest, axis, change, [word | out])

      next_is_lparen?(rest) ->
        scan(rest, axis, change, [word | out])

      true ->
        case take_range_tail(rest) do
          {:range, sep, word2, rest2} ->
            scan(rest2, axis, change, [rewrite_range(word, sep, word2, axis, change) | out])

          :single ->
            scan(rest, axis, change, [rewrite_ref(word, axis, change) | out])
        end
    end
  end

  defp scan(<<c::utf8, rest::binary>>, axis, change, out),
    do: scan(rest, axis, change, [<<c::utf8>> | out])

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
