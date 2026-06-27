defmodule Barkpark.Plugins.Sheets.Engine do
  @moduledoc """
  The Sheets formula engine — recomputes cached `"v"` values for every
  formula cell of a sheet document's content, AHEAD of snapshot synthesis
  (`Barkpark.Plugins.Sheets.Core.snapshot_for/2`). `Barkpark.Content` calls `recompute/1`
  on every `"sheet"` save, so HTTP mutations persist computed values and the
  write-through snapshots project them into embeds with zero renderer
  changes. Pure functions: no Repo, no I/O.

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

  ## Errors, cycles, stale

  Four error values, written with `"t" => "e"`:

    * `#CYCLE!` — every formula on a reference cycle, and every formula that
      (transitively) depends on one. Dependencies are collected from the full
      AST, both `IF` branches included.
    * `#REF!` — a formula outside the grammar (parse/lex failure, a bare
      identifier, cross-tab syntax) or a ref beyond the grid bounds.
    * `#VALUE!` — type mismatch (`"abc"+1`), a range used as a scalar, a bad
      condition/arity, or a numeric domain error (e.g. `(-8)^0.5`).
    * `#DIV/0!` — division by zero (also `0^negative`, and `AVG` of nothing).

  Errors propagate through references: a formula reading a cell whose value
  is an error yields that error. A literal cell whose `"v"` is one of the
  four error strings (or whose `"t"` is `"e"`) propagates the same way.

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
  """

  alias Barkpark.Plugins.Sheets.Core, as: Sheets

  # Excel grid bounds: column XFD, row 1_048_576.
  @max_col 16_384
  @max_row 1_048_576

  @functions ~w(SUM AVG AVERAGE MIN MAX COUNT COUNTA IF ROUND ABS)
  @aggregates ~w(SUM AVG AVERAGE MIN MAX COUNT COUNTA)
  @cmp_ops [:eq, :ne, :lt, :le, :gt, :ge]
  @error_values ~w(#CYCLE! #REF! #VALUE! #DIV/0!)

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

  defp output({:error, code}), do: {code, "e"}
  defp output(%Date{} = d), do: {Date.to_iso8601(d), "date"}
  defp output(%DateTime{} = dt), do: {DateTime.to_iso8601(dt), "datetime"}
  defp output(%NaiveDateTime{} = ndt), do: {NaiveDateTime.to_iso8601(ndt), "datetime"}
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
        case Float.parse(s) do
          {f, ""} -> f
          _ -> nil
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
          {"", _} -> :error
          {frac, rest3} -> {:ok, {:num, String.to_float(zero_pad(int) <> "." <> frac)}, rest3}
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
    case eval(l, ctx) do
      {:error, _} = e ->
        e

      lv ->
        case eval(r, ctx) do
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
    case eval(ast, ctx) do
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
      number_like?(a) and number_like?(b) -> num(a) + num(b)
      true -> err(:value)
    end
  end

  defp arith(:sub, a, b) do
    cond do
      temporal?(a) and temporal?(b) -> day_diff(a, b)
      temporal?(a) and number_like?(b) -> advance(a, -num(b))
      number_like?(a) and number_like?(b) -> num(a) - num(b)
      true -> err(:value)
    end
  end

  defp arith(:mul, a, b) do
    if number_like?(a) and number_like?(b), do: num(a) * num(b), else: err(:value)
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
    if rem(a, b) == 0, do: div(a, b), else: a / b
  end

  defp divide(a, b), do: a / b

  defp power(a, b) when is_integer(a) and is_integer(b) and b >= 0, do: Integer.pow(a, b)

  defp power(a, b) do
    if a == 0 and b < 0 do
      err(:div0)
    else
      try do
        :math.pow(a, b)
      rescue
        ArithmeticError -> err(:value)
      end
    end
  end

  defp number_like?(v), do: is_number(v) or v == :blank

  defp num(v) when is_number(v), do: v
  defp num(:blank), do: 0

  defp temporal?(%Date{}), do: true
  defp temporal?(%DateTime{}), do: true
  defp temporal?(%NaiveDateTime{}), do: true
  defp temporal?(_), do: false

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

  defp call(name, args, ctx) when name in @aggregates do
    strict? = name not in ["COUNT", "COUNTA"]

    case collect_agg_items(args, ctx, strict?, []) do
      {:error, _} = e -> e
      {:ok, items} -> aggregate(name, items)
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
    p = Integer.pow(10, n)
    round(x * p) / p
  end

  defp fn_round(x, n) do
    p = Integer.pow(10, -n)
    round(x / p) * p
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
      :blank -> collect_agg_items(rest, ctx, strict?, acc)
      n when is_number(n) -> collect_agg_items(rest, ctx, strict?, [n | acc])
      _other when strict? -> err(:value)
      other -> collect_agg_items(rest, ctx, strict?, [other | acc])
    end
  end

  defp range_values({c1, r1}, {c2, r2}, ctx) do
    area = (c2 - c1 + 1) * (r2 - r1 + 1)

    positions =
      if area <= MapSet.size(ctx.occupied) do
        for c <- c1..c2, r <- r1..r2, MapSet.member?(ctx.occupied, {c, r}), do: {c, r}
      else
        Enum.filter(ctx.occupied, fn {c, r} -> c >= c1 and c <= c2 and r >= r1 and r <= r2 end)
      end

    positions
    |> Enum.map(&cell_at(&1, ctx))
    |> Enum.reject(&(&1 == :blank))
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

  defp err(:value), do: {:error, "#VALUE!"}
  defp err(:div0), do: {:error, "#DIV/0!"}
  defp err(:ref), do: {:error, "#REF!"}
  defp err(:cycle), do: {:error, "#CYCLE!"}
end
