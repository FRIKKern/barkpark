defmodule Barkpark.Groq.Parser do
  @moduledoc """
  Parses a GROQ query string into an expression tree for `Barkpark.Groq.Evaluator`.

  The grammar and the precedence table follow the GROQ specification
  (https://spec.groq.dev, GROQ-1.revision1) and the reference parser in groq-js,
  so a query that Sanity's Content Lake accepts parses here into the same shape.
  Traversals (`.a`, `[...]`, `->`, `{...}`, `[]`) are folded with the
  specification's four traversal kinds, which decide where a projection or an
  attribute access is mapped over an array.

  Parameters are substituted while parsing, as groq-js does, so a slice such as
  `[$start...$end]` sees constant numbers. A parameter the caller did not send is
  a parse error, which is how Sanity's API answers it.

  `parse/2` returns `{:ok, tree}` or `{:error, %{description, start, end}}` with
  byte offsets into the query.

  ## Tree nodes

      {:everything} | {:this} | {:parent, n} | {:value, v}
      {:attr, base | nil, name} | {:elem, base, index}
      {:slice, base, left, right, inclusive?}
      {:filter, base, expr} | {:projection, base, object}
      {:deref, base} | {:map, base, expr} | {:flat_map, base, expr}
      {:array_coerce, base} | {:group, base}
      {:object, [{:attr_value, name, expr} | {:splat, expr} | {:cond_splat, cond, expr}]}
      {:array, [{expr, splat?}]} | {:tuple, [expr]}
      {:and, l, r} | {:or, l, r} | {:not, e} | {:neg, e} | {:pos, e}
      {:op, op, l, r} | {:in_range, base, l, r, inclusive?}
      {:func, namespace, name, args} | {:select, [{cond, value}], fallback | nil}
      {:pipe, base, name, args} | {:asc, e} | {:desc, e}
  """

  @prec_pair 1
  @prec_or 2
  @prec_and 3
  @prec_comp 4
  @prec_order 4
  @prec_add 6
  @prec_mul 7
  @prec_pow 8
  @prec_neg 8
  @prec_not 10
  @prec_pos 10

  # Function names per namespace with their arity rule: an integer, `{:min, n}`,
  # `{:range, a, b}` or `:any`. Mirrors groq-js `shared/functionRegistry.ts`.
  @functions %{
    "global" => %{
      "anywhere" => 1,
      "coalesce" => :any,
      "count" => 1,
      "dateTime" => 1,
      "defined" => 1,
      "identity" => 0,
      "length" => 1,
      "path" => 1,
      "string" => 1,
      "references" => {:min, 1},
      "round" => {:range, 1, 2},
      "now" => 0,
      "boost" => 2,
      "lower" => 1,
      "upper" => 1
    },
    "string" => %{"lower" => 1, "upper" => 1, "split" => 2, "startsWith" => 2},
    "array" => %{"join" => 2, "compact" => 1, "unique" => 1, "intersects" => 2},
    "pt" => %{"text" => 1},
    "delta" => %{"operation" => :any},
    "diff" => %{"changedAny" => 3, "changedOnly" => 3},
    "media" => %{"aspect" => 2},
    "sanity" => %{
      "projectId" => :any,
      "dataset" => :any,
      "versionOf" => 1,
      "partOfRelease" => 1
    },
    "math" => %{"min" => 1, "max" => 1, "sum" => 1, "avg" => 1},
    "dateTime" => %{"now" => 0},
    "releases" => %{"all" => 0},
    "text" => %{"query" => 1, "semanticSimilarity" => 1},
    "geo" => %{"latLng" => :any, "contains" => :any, "intersects" => :any, "distance" => :any},
    "documents" => %{
      "get" => :any,
      "incomingRefCount" => :any,
      "incomingGlobalDocumentReferenceCount" => :any
    },
    "user" => %{"attributes" => :any}
  }

  @pipe_functions %{"order" => {:min, 1}, "score" => {:min, 1}}

  @escapes %{
    ?' => "'",
    ?" => "\"",
    ?\\ => "\\",
    ?/ => "/",
    ?b => "\b",
    ?f => "\f",
    ?n => "\n",
    ?r => "\r",
    ?t => "\t"
  }

  @type tree :: tuple()
  @type parse_error :: %{
          description: String.t(),
          start: non_neg_integer(),
          end: non_neg_integer()
        }

  @doc """
  Parses `query` with the JSON-decoded `params` map (keys without the `$`).
  """
  @spec parse(String.t(), map()) :: {:ok, tree()} | {:error, parse_error()}
  def parse(query, params \\ %{}) when is_binary(query) and is_map(params) do
    ctx = %{params: params, allow_boost: false}
    pos = skip_ws(query, 0)

    if at(query, pos) == ?f and at(query, pos + 1) == ?n and not ident_char?(at(query, pos + 2)) do
      throw({:groq_parse_error, "custom functions (fn) are not supported", pos, pos + 2})
    end

    {node, pos, fail_pos} = parse_expr(query, pos, 0, ctx)
    pos = skip_ws(query, pos)

    if pos != byte_size(query) do
      at_pos = if fail_pos, do: max(fail_pos - 1, 0), else: pos
      throw({:groq_parse_error, "unexpected input after the end of the expression", at_pos})
    end

    {:ok, node |> validate() |> memoize_closed()}
  catch
    {:groq_parse_error, message, position} ->
      {:error, %{description: message, start: position, end: min(position + 1, byte_size(query))}}

    # A span, as Sanity reports it: the bad token or the unclosed construct, so
    # an editor underlines the whole of it (task-8a6e47612d2987c6).
    {:groq_parse_error, message, start, stop} ->
      {:error, %{description: message, start: start, end: stop}}
  end

  # ── Expressions ──────────────────────────────────────────────────────────

  defp parse_expr(s, pos, level, ctx) do
    {lhs, pos} = parse_primary(s, pos, ctx)
    parse_loop(s, pos, level, 12, lhs, nil, ctx)
  end

  defp parse_primary(s, pos, ctx) do
    case at(s, pos) do
      ?+ ->
        {rhs, p, _} = parse_expr(s, skip_ws(s, pos + 1), @prec_pos, ctx)
        {{:pos, rhs}, p}

      ?- ->
        {rhs, p, _} = parse_expr(s, skip_ws(s, pos + 1), @prec_neg, ctx)
        {{:neg, rhs}, p}

      ?( ->
        parse_group_or_tuple(s, pos, ctx)

      ?! ->
        {rhs, p, _} = parse_expr(s, skip_ws(s, pos + 1), @prec_not, ctx)
        {{:not, rhs}, p}

      ?{ ->
        parse_object(s, pos, ctx)

      ?[ ->
        parse_array(s, pos, ctx)

      q when q in [?', ?"] ->
        {str, p} = parse_string(s, pos)
        {{:value, str}, p}

      ?^ ->
        parse_parent(s, pos + 1, 1)

      ?@ ->
        {{:this}, pos + 1}

      ?* ->
        {{:everything}, pos + 1}

      ?$ ->
        case ident_len(s, pos + 1) do
          0 ->
            throw({:groq_parse_error, "expected a parameter name after \"$\"", pos})

          n ->
            name = binary_part(s, pos + 1, n)

            case Map.fetch(ctx.params, name) do
              {:ok, value} ->
                {{:value, value}, pos + 1 + n}

              :error ->
                # Sanity's span: from the `$` for the name's length.
                throw(
                  {:groq_parse_error, "param $#{name} referenced, but not provided", pos, pos + n}
                )
            end
        end

      nil ->
        throw({:groq_parse_error, "expected an expression", pos})

      c ->
        cond do
          c in ?0..?9 -> parse_number(s, pos)
          ident_start?(c) -> parse_identifier(s, pos, ctx)
          true -> throw({:groq_parse_error, "expected an expression", pos})
        end
    end
  end

  defp parse_parent(s, pos, n) do
    if at(s, pos) == ?. and at(s, pos + 1) == ?^ do
      parse_parent(s, pos + 2, n + 1)
    else
      {{:parent, n}, pos}
    end
  end

  defp parse_identifier(s, pos, ctx) do
    n = ident_len(s, pos)
    name = binary_part(s, pos, n)
    p = pos + n

    case at(s, p) do
      ?( ->
        parse_func_call(s, "global", name, pos, p, ctx)

      ?: ->
        if at(s, p + 1) == ?: do
          fpos = skip_ws(s, p + 2)

          case ident_len(s, fpos) do
            0 ->
              throw({:groq_parse_error, "expected a function name", fpos})

            m ->
              fname = binary_part(s, fpos, m)
              open = skip_ws(s, fpos + m)

              if at(s, open) != ?( do
                throw({:groq_parse_error, "expected \"(\" after the function name", open})
              end

              parse_func_call(s, name, fname, pos, open, ctx)
          end
        else
          throw({:groq_parse_error, "unexpected \":\"", p})
        end

      _ ->
        node =
          case name do
            "null" -> {:value, nil}
            "true" -> {:value, true}
            "false" -> {:value, false}
            _ -> {:attr, nil, name}
          end

        {node, p}
    end
  end

  defp parse_number(s, pos) do
    int_len = digits_len(s, pos)
    p = pos + int_len

    {kind, p} =
      if at(s, p) == ?. and digits_len(s, p + 1) > 0 do
        {:float, p + 1 + digits_len(s, p + 1)}
      else
        {:integer, p}
      end

    {kind, p} =
      if at(s, p) in [?e, ?E] do
        p = p + 1
        p = if at(s, p) in [?+, ?-], do: p + 1, else: p

        case digits_len(s, p) do
          0 -> throw({:groq_parse_error, "the exponent must be a number", p})
          d -> {:sci, p + d}
        end
      else
        {kind, p}
      end

    text = binary_part(s, pos, p - pos)

    value =
      case kind do
        :integer ->
          text |> String.to_integer() |> Barkpark.Groq.Values.num()

        _ ->
          # Past the double range (`1e400`) Float.parse refuses the text;
          # JavaScript reads Infinity, which GROQ answers as null
          # (task-97b8d14ea3d44330).
          case Float.parse(normalize_float_text(text)) do
            {f, ""} -> f
            _ -> nil
          end
      end

    {{:value, value}, p}
  end

  # Float.parse wants a digit after the decimal point when an exponent follows
  # ("1e5" parses, but so does "1.0e5"); GROQ's grammar already guarantees the
  # shapes, so only the bare-exponent form needs help.
  defp normalize_float_text(text) do
    if String.contains?(text, ".") do
      text
    else
      String.replace(text, ~r/[eE]/, ".0e", global: false)
    end
  end

  defp parse_loop(s, pos, level, lhs_level, lhs, fail_pos, ctx) do
    inner = skip_ws(s, pos)

    if inner >= byte_size(s) do
      {lhs, inner, fail_pos}
    else
      case try_traversals(s, inner, ctx) do
        {:ok, [_ | _] = travs, p} ->
          parse_loop(s, p, level, lhs_level, apply_traversals(lhs, travs), fail_pos, ctx)

        {:none, trav_fail} ->
          parse_operator(s, pos, inner, level, lhs_level, lhs, trav_fail || fail_pos, ctx)
      end
    end
  end

  defp parse_operator(s, pos, inner, level, lhs_level, lhs, fail_pos, ctx) do
    c = at(s, inner)
    c2 = at(s, inner + 1)
    done = {lhs, pos, fail_pos}

    cond do
      c == ?= and c2 == ?> ->
        if level > @prec_pair or lhs_level <= @prec_pair do
          done
        else
          {rhs, p, _} = parse_expr(s, skip_ws(s, inner + 2), @prec_pair, ctx)
          parse_loop(s, p, level, @prec_pair, {:pair, lhs, rhs}, fail_pos, ctx)
        end

      c == ?= and c2 == ?= ->
        binary_comp(s, inner, 2, "==", level, lhs_level, lhs, fail_pos, ctx, done)

      c == ?! and c2 == ?= ->
        binary_comp(s, inner, 2, "!=", level, lhs_level, lhs, fail_pos, ctx, done)

      c in [?<, ?>] ->
        {op, width} = if c2 == ?=, do: {<<c, ?=>>, 2}, else: {<<c>>, 1}
        binary_comp(s, inner, width, op, level, lhs_level, lhs, fail_pos, ctx, done)

      c == ?+ ->
        left_assoc(
          s,
          inner,
          1,
          @prec_add,
          level,
          lhs_level,
          lhs,
          fail_pos,
          ctx,
          done,
          &{:op, "+", &1, &2}
        )

      c == ?- ->
        left_assoc(
          s,
          inner,
          1,
          @prec_add,
          level,
          lhs_level,
          lhs,
          fail_pos,
          ctx,
          done,
          &{:op, "-", &1, &2}
        )

      c == ?* and c2 == ?* ->
        if level > @prec_pow or lhs_level <= @prec_pow do
          done
        else
          {rhs, p, _} = parse_expr(s, skip_ws(s, inner + 2), @prec_pow, ctx)
          parse_loop(s, p, level, @prec_pow, {:op, "**", lhs, rhs}, fail_pos, ctx)
        end

      c == ?* ->
        left_assoc(
          s,
          inner,
          1,
          @prec_mul,
          level,
          lhs_level,
          lhs,
          fail_pos,
          ctx,
          done,
          &{:op, "*", &1, &2}
        )

      c == ?/ ->
        left_assoc(
          s,
          inner,
          1,
          @prec_mul,
          level,
          lhs_level,
          lhs,
          fail_pos,
          ctx,
          done,
          &{:op, "/", &1, &2}
        )

      c == ?% ->
        left_assoc(
          s,
          inner,
          1,
          @prec_mul,
          level,
          lhs_level,
          lhs,
          fail_pos,
          ctx,
          done,
          &{:op, "%", &1, &2}
        )

      c == ?| and c2 == ?| ->
        left_assoc(
          s,
          inner,
          2,
          @prec_or,
          level,
          lhs_level,
          lhs,
          fail_pos,
          ctx,
          done,
          &{:or, &1, &2}
        )

      c == ?| ->
        if level > 11 or lhs_level < 11 do
          done
        else
          parse_pipe_call(s, inner, level, lhs, fail_pos, ctx)
        end

      c == ?& and c2 == ?& ->
        left_assoc(
          s,
          inner,
          2,
          @prec_and,
          level,
          lhs_level,
          lhs,
          fail_pos,
          ctx,
          done,
          &{:and, &1, &2}
        )

      keyword?(s, inner, "desc") ->
        if level > @prec_order or lhs_level < @prec_order do
          done
        else
          parse_loop(s, inner + 4, level, @prec_order, {:desc, lhs}, fail_pos, ctx)
        end

      keyword?(s, inner, "asc") ->
        if level > @prec_order or lhs_level < @prec_order do
          done
        else
          parse_loop(s, inner + 3, level, @prec_order, {:asc, lhs}, fail_pos, ctx)
        end

      keyword?(s, inner, "in") ->
        if level > @prec_comp or lhs_level <= @prec_comp do
          done
        else
          parse_in(s, inner, level, lhs, fail_pos, ctx)
        end

      keyword?(s, inner, "match") ->
        binary_comp(s, inner, 5, "match", level, lhs_level, lhs, fail_pos, ctx, done)

      true ->
        done
    end
  end

  defp binary_comp(s, inner, width, op, level, lhs_level, lhs, fail_pos, ctx, done) do
    if level > @prec_comp or lhs_level <= @prec_comp do
      done
    else
      {rhs, p, _} = parse_expr(s, skip_ws(s, inner + width), @prec_comp + 1, ctx)
      parse_loop(s, p, level, @prec_comp, {:op, op, lhs, rhs}, fail_pos, ctx)
    end
  end

  defp left_assoc(s, inner, width, prec, level, lhs_level, lhs, fail_pos, ctx, done, build) do
    if level > prec or lhs_level < prec do
      done
    else
      {rhs, p, _} = parse_expr(s, skip_ws(s, inner + width), prec + 1, ctx)
      parse_loop(s, p, level, prec, build.(lhs, rhs), fail_pos, ctx)
    end
  end

  defp parse_in(s, inner, level, lhs, fail_pos, ctx) do
    p = skip_ws(s, inner + 2)
    {group?, p} = if at(s, p) == ?(, do: {true, skip_ws(s, p + 1)}, else: {false, p}

    {first, p, _} = parse_expr(s, p, @prec_comp + 1, ctx)
    p = skip_ws(s, p)

    {node, p} =
      if at(s, p) == ?. and at(s, p + 1) == ?. do
        {inclusive?, p} =
          if at(s, p + 2) == ?., do: {false, skip_ws(s, p + 3)}, else: {true, skip_ws(s, p + 2)}

        {second, p, _} = parse_expr(s, p, @prec_comp + 1, ctx)
        {{:in_range, lhs, first, second, inclusive?}, p}
      else
        {{:op, "in", lhs, first}, p}
      end

    p =
      if group? do
        p = skip_ws(s, p)
        if at(s, p) != ?), do: throw({:groq_parse_error, "expected \")\" in group", p})
        p + 1
      else
        p
      end

    parse_loop(s, p, level, @prec_comp, node, fail_pos, ctx)
  end

  defp parse_pipe_call(s, inner, level, lhs, fail_pos, ctx) do
    {name, ipos, p} = pipe_function_name(s, skip_ws(s, inner + 1))

    if at(s, p) != ?( do
      throw({:groq_parse_error, "expected a function call after \"|\"", ipos})
    end

    arity =
      Map.get(@pipe_functions, name) ||
        throw({:groq_parse_error, "undefined pipe function: #{name}", ipos})

    arg_ctx = if name == "score", do: %{ctx | allow_boost: true}, else: ctx
    {args, p} = parse_args(s, p, arg_ctx)
    check_arity!(name, arity, length(args), ipos)

    args = if name == "order", do: args, else: Enum.map(args, &reject_marks!(&1, ipos))

    if name == "score" and not score_base?(lhs) do
      throw({:groq_parse_error, "score() must follow a filter over *", ipos})
    end

    parse_loop(s, p, level, 11, {:pipe, lhs, name, args}, fail_pos, ctx)
  end

  # score() ranks documents, so it applies to `*`, a filter or slice of it, or
  # another pipe over one of those (the GROQ suite's "Illegal use" cases).
  defp score_base?({:everything}), do: true
  defp score_base?({:filter, base, _}), do: score_base?(base)
  defp score_base?({:slice, base, _, _, _}), do: score_base?(base)
  defp score_base?({:pipe, base, _, _}), do: score_base?(base)
  defp score_base?(_), do: false

  # `| order(...)` and `| global::order(...)` name the same function; pipe
  # functions live in the global namespace only.
  defp pipe_function_name(s, ipos) do
    n = ident_len(s, ipos)
    if n == 0, do: throw({:groq_parse_error, "expected a function name after \"|\"", ipos})
    name = binary_part(s, ipos, n)
    p = ipos + n

    if at(s, p) == ?: and at(s, p + 1) == ?: do
      if name != "global", do: throw({:groq_parse_error, "undefined namespace: #{name}", ipos})
      fpos = skip_ws(s, p + 2)
      m = ident_len(s, fpos)
      if m == 0, do: throw({:groq_parse_error, "expected a function name", fpos})
      {binary_part(s, fpos, m), fpos, fpos + m}
    else
      {name, ipos, p}
    end
  end

  defp parse_func_call(s, namespace, name, start, open, ctx) do
    {args, p} = parse_args(s, open, ctx)

    cond do
      namespace == "global" and name == "select" ->
        {build_select(args, start), p}

      true ->
        funcs =
          Map.get(@functions, namespace) ||
            throw({:groq_parse_error, "undefined namespace: #{namespace}", start, open})

        arity =
          Map.get(funcs, name) ||
            throw({:groq_parse_error, undefined_function(namespace, name), start, open})

        check_arity!(name, arity, length(args), start)

        if namespace == "global" and name == "boost" and not ctx.allow_boost do
          throw(
            {:groq_parse_error, "boost() function cannot be used outside score()", start, open}
          )
        end

        {{:func, namespace, name, Enum.map(args, &reject_marks!(&1, start))}, p}
    end
  end

  defp build_select(args, start) do
    {alts, fallback} =
      Enum.reduce(args, {[], nil}, fn arg, {alts, fallback} ->
        if fallback != nil,
          do: throw({:groq_parse_error, "unexpected argument to select()", start})

        case arg do
          {:pair, cond_expr, value} -> {[{cond_expr, value} | alts], nil}
          other -> {alts, other}
        end
      end)

    {:select, Enum.reverse(alts), fallback}
  end

  # Sanity's wording: `Undefined function "lowr"`, and the namespace when one
  # was written (`Undefined function "changedAny" in namespace "delta"`).
  defp undefined_function("global", name), do: "Undefined function \"#{name}\""

  defp undefined_function(namespace, name),
    do: "Undefined function \"#{name}\" in namespace \"#{namespace}\""

  defp parse_args(s, open, ctx) do
    p = skip_ws(s, open + 1)

    if at(s, p) == ?) do
      {[], p + 1}
    else
      collect_args(s, p, [], ctx, open)
    end
  end

  # `open` is the `(`: an unclosed call is underlined from it (Sanity's span).
  defp collect_args(s, p, acc, ctx, open) do
    {arg, p, _} = parse_expr(s, p, 0, ctx)
    p = skip_ws(s, p)

    case at(s, p) do
      ?, ->
        p = skip_ws(s, p + 1)

        if at(s, p) == ?),
          do: {Enum.reverse([arg | acc]), p + 1},
          else: collect_args(s, p, [arg | acc], ctx, open)

      ?) ->
        {Enum.reverse([arg | acc]), p + 1}

      _ ->
        throw({:groq_parse_error, "expected \")\" after the function arguments", open, p + 1})
    end
  end

  defp check_arity!(name, arity, count, pos) do
    ok? =
      case arity do
        :any -> true
        n when is_integer(n) -> count == n
        {:min, n} -> count >= n
        {:range, a, b} -> count >= a and count <= b
      end

    unless ok? do
      throw({:groq_parse_error, "incorrect number of arguments to function #{name}()", pos})
    end
  end

  defp parse_group_or_tuple(s, pos, ctx) do
    {first, p, _} = parse_expr(s, skip_ws(s, pos + 1), 0, ctx)
    p = skip_ws(s, p)

    case at(s, p) do
      ?) ->
        {{:group, first}, p + 1}

      ?, ->
        collect_tuple(s, skip_ws(s, p + 1), [first], ctx)

      _ ->
        throw({:groq_parse_error, "expected \")\"", p})
    end
  end

  defp collect_tuple(s, p, acc, ctx) do
    {member, p, _} = parse_expr(s, p, 0, ctx)
    p = skip_ws(s, p)

    case at(s, p) do
      ?, -> collect_tuple(s, skip_ws(s, p + 1), [member | acc], ctx)
      ?) -> {{:tuple, Enum.reverse([member | acc])}, p + 1}
      _ -> throw({:groq_parse_error, "expected \")\" after the tuple", p})
    end
  end

  defp parse_array(s, pos, ctx) do
    p = skip_ws(s, pos + 1)

    if at(s, p) == ?] do
      {{:array, []}, p + 1}
    else
      collect_array(s, p, [], ctx, pos)
    end
  end

  defp collect_array(s, p, acc, ctx, open) do
    {splat?, p} =
      if binary_part_safe(s, p, 3) == "...", do: {true, skip_ws(s, p + 3)}, else: {false, p}

    {elem, p, _} = parse_expr(s, p, 0, ctx)
    acc = [{reject_marks!(elem, p), splat?} | acc]
    p = skip_ws(s, p)

    case at(s, p) do
      ?, ->
        p = skip_ws(s, p + 1)

        if at(s, p) == ?],
          do: {{:array, Enum.reverse(acc)}, p + 1},
          else: collect_array(s, p, acc, ctx, open)

      ?] ->
        {{:array, Enum.reverse(acc)}, p + 1}

      _ ->
        throw({:groq_parse_error, "expected \"]\" after the array", open, p})
    end
  end

  defp parse_object(s, pos, ctx) do
    collect_object(s, skip_ws(s, pos + 1), [], ctx, pos)
  end

  defp collect_object(s, p, acc, ctx, open) do
    if at(s, p) == ?} do
      {{:object, Enum.reverse(acc)}, p + 1}
    else
      {attr, p} = parse_object_member(s, p, ctx)
      p = skip_ws(s, p)

      case at(s, p) do
        ?, -> collect_object(s, skip_ws(s, p + 1), [attr | acc], ctx, open)
        ?} -> {{:object, Enum.reverse([attr | acc])}, p + 1}
        _ -> throw({:groq_parse_error, "expected \"}\" after the object", open, p + 1})
      end
    end
  end

  defp parse_object_member(s, p, ctx) do
    if binary_part_safe(s, p, 3) == "..." do
      after_dots = skip_ws(s, p + 3)

      if at(s, after_dots) in [?}, ?,] do
        {{:splat, {:this}}, after_dots}
      else
        {expr, np, _} = parse_expr(s, after_dots, 0, ctx)
        {{:splat, reject_marks!(expr, p)}, np}
      end
    else
      string_start? = at(s, p) in [?", ?']
      {expr, np, _} = parse_expr(s, p, 0, ctx)
      next = skip_ws(s, np)
      colon? = at(s, next) == ?:

      case expr do
        {:value, key} when string_start? and colon? and is_binary(key) ->
          # Only a bare string literal can be a key: anything wrapped in an
          # operator or traversal parses as a larger expression first.
          {value, vp, _} = parse_expr(s, skip_ws(s, next + 1), 0, ctx)
          {{:attr_value, key, reject_marks!(value, next)}, vp}

        {:pair, cond_expr, value} ->
          {{:cond_splat, reject_marks!(cond_expr, p), reject_marks!(value, p)}, np}

        other ->
          {{:attr_value, property_key!(other, p), reject_marks!(other, p)}, np}
      end
    end
  end

  defp property_key!({:attr, nil, name}, _pos), do: name

  defp property_key!({kind, base, _}, pos)
       when kind in [:filter, :projection, :elem, :map, :flat_map],
       do: property_key!(base, pos)

  defp property_key!({:pipe, base, _, _}, pos), do: property_key!(base, pos)
  defp property_key!({:slice, base, _, _, _}, pos), do: property_key!(base, pos)

  defp property_key!({kind, base}, pos) when kind in [:deref, :array_coerce, :group],
    do: property_key!(base, pos)

  defp property_key!(_node, pos),
    do: throw({:groq_parse_error, "cannot determine the property key of this object member", pos})

  # ── Strings ──────────────────────────────────────────────────────────────

  defp parse_string(s, pos) do
    quote_char = at(s, pos)
    read_string(s, pos + 1, quote_char, [], pos)
  end

  defp read_string(s, p, q, acc, start) do
    case at(s, p) do
      nil ->
        throw({:groq_parse_error, "unterminated string", start, p})

      ^q ->
        {acc |> Enum.reverse() |> Enum.map(&cp_to_binary/1) |> IO.iodata_to_binary(), p + 1}

      ?\\ ->
        case at(s, p + 1) do
          ?u ->
            {cp, np} = read_unicode_escape(s, p + 2, start)
            read_string(s, np, q, [{:cp, cp} | acc] |> collapse_cp(), start)

          c ->
            case Map.fetch(@escapes, c) do
              {:ok, str} -> read_string(s, p + 2, q, [str | acc], start)
              :error -> throw({:groq_parse_error, "invalid escape sequence", p})
            end
        end

      _ ->
        # Copy the whole run up to the next quote or backslash in one step.
        run = run_len(s, p, q)
        read_string(s, p + run, q, [binary_part(s, p, run) | acc], start)
    end
  end

  defp run_len(s, p, q) do
    rest = binary_part(s, p, byte_size(s) - p)

    case :binary.match(rest, [<<q>>, "\\"]) do
      {idx, _} -> max(idx, 1)
      :nomatch -> byte_size(rest)
    end
  end

  defp read_unicode_escape(s, p, start) do
    if at(s, p) == ?{ do
      close =
        case :binary.match(s, "}", scope: {p, byte_size(s) - p}) do
          {idx, _} -> idx
          :nomatch -> throw({:groq_parse_error, "unterminated unicode escape", start})
        end

      {hex_to_int(binary_part(s, p + 1, close - p - 1), start), close + 1}
    else
      {hex_to_int(binary_part_safe(s, p, 4), start), p + 4}
    end
  end

  defp hex_to_int(hex, start) do
    case Integer.parse(hex, 16) do
      {n, ""} -> n
      _ -> throw({:groq_parse_error, "invalid unicode escape", start})
    end
  end

  # Two `\uXXXX` escapes forming a UTF-16 surrogate pair become one code point.
  defp collapse_cp([{:cp, low}, {:cp, high} | rest])
       when high in 0xD800..0xDBFF and low in 0xDC00..0xDFFF do
    [{:cp, 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)} | rest]
  end

  defp collapse_cp(acc), do: acc

  # A lone UTF-16 surrogate has no UTF-8 encoding; it becomes U+FFFD.
  defp cp_to_binary({:cp, cp}) when cp in 0xD800..0xDFFF or cp > 0x10FFFF, do: <<0xFFFD::utf8>>
  defp cp_to_binary({:cp, cp}), do: <<cp::utf8>>
  defp cp_to_binary(bin), do: bin

  # ── Traversals ───────────────────────────────────────────────────────────

  defp try_traversals(s, pos, ctx) do
    collect_traversals(s, pos, [], ctx)
  end

  defp collect_traversals(s, pos, acc, ctx) do
    case parse_traversal(s, pos, ctx) do
      {:ok, trav, p} ->
        collect_traversals(s, skip_ws(s, p), [trav | acc], ctx)

      {:error, fail} ->
        case acc do
          [] -> {:none, fail}
          # `pos` is past the whitespace after the last traversal; the caller
          # skips whitespace again, so ending there is equivalent.
          _ -> {:ok, Enum.reverse(acc), pos}
        end
    end
  end

  # A traversal that started with `[` or `{` cannot be anything else, so an
  # error inside it is the query's error (its message names the real problem,
  # such as a missing parameter). `.`, `-` and `|` that do not start a
  # traversal return `{:error, pos}` and are tried as operators instead.
  defp parse_traversal(s, pos, ctx), do: parse_traversal!(s, pos, ctx)

  defp parse_traversal!(s, pos, ctx) do
    case at(s, pos) do
      ?. ->
        p = skip_ws(s, pos + 1)

        if at(s, p) == ?( do
          throw({:groq_parse_error, "selectors are not supported", p})
        end

        case ident_len(s, p) do
          0 -> {:error, p}
          n -> {:ok, {:attr_access, binary_part(s, p, n)}, p + n}
        end

      ?- ->
        if at(s, pos + 1) == ?> do
          p = pos + 2
          ip = skip_ws(s, p)

          case ident_len(s, ip) do
            0 -> {:ok, {:deref, nil}, p}
            n -> {:ok, {:deref, binary_part(s, ip, n)}, ip + n}
          end
        else
          {:error, pos}
        end

      ?[ ->
        p = skip_ws(s, pos + 1)

        if at(s, p) == ?] do
          {:ok, :array_postfix, p + 1}
        else
          {expr, p, _} = parse_expr(s, p, 0, ctx)
          p = skip_ws(s, p)

          if at(s, p) == ?. and at(s, p + 1) == ?. do
            {inclusive?, p} = if at(s, p + 2) == ?., do: {false, p + 3}, else: {true, p + 2}
            {right, p, _} = parse_expr(s, skip_ws(s, p), 0, ctx)
            p = skip_ws(s, p)

            if at(s, p) != ?],
              do: throw({:groq_parse_error, "expected \"]\" after the slice", pos, p})

            left_value =
              const_integer(expr) ||
                throw({:groq_parse_error, "slicing must use constant integers", pos, p + 1})

            right_value =
              const_integer(right) ||
                throw({:groq_parse_error, "slicing must use constant integers", pos, p + 1})

            {:ok, {:slice, left_value, right_value, inclusive?}, p + 1}
          else
            if at(s, p) != ?], do: throw({:groq_parse_error, "expected \"]\"", pos, p})
            {:ok, {:square_bracket, reject_marks!(expr, pos)}, p + 1}
          end
        end

      ?| ->
        p = skip_ws(s, pos + 1)

        if at(s, p) == ?{ do
          {obj, np} = parse_object(s, p, ctx)
          {:ok, {:projection, obj}, np}
        else
          {:error, pos}
        end

      ?{ ->
        {obj, np} = parse_object(s, pos, ctx)
        {:ok, {:projection, obj}, np}

      _ ->
        {:error, pos}
    end
  end

  # Fold a chain of traversals onto `base`, exactly as groq-js `traverse` does:
  # build the traversal right-to-left, then start array-typed bases
  # (`*`, an array literal, a pipe call) in array mode.
  defp apply_traversals(base, travs) do
    traversal =
      travs
      |> Enum.reverse()
      |> Enum.reduce(nil, fn trav, right -> traversal_fun(trav).(right) end)

    traversal =
      if array_base?(base),
        do: traverse_array(fn b -> b end, traversal),
        else: traversal

    {_kind, build} = traversal
    build.(base)
  end

  defp array_base?({:everything}), do: true
  defp array_base?({:array, _}), do: true
  defp array_base?({:pipe, _, _, _}), do: true
  defp array_base?(_), do: false

  defp traversal_fun({:attr_access, name}),
    do: fn right -> traverse_plain(fn base -> {:attr, base, name} end, right) end

  defp traversal_fun({:deref, nil}),
    do: fn right -> traverse_plain(fn base -> {:deref, base} end, right) end

  defp traversal_fun({:deref, name}),
    do: fn right -> traverse_plain(fn base -> {:attr, {:deref, base}, name} end, right) end

  defp traversal_fun(:array_postfix),
    do: fn right -> traverse_array(fn base -> {:array_coerce, base} end, right) end

  defp traversal_fun({:slice, left, right_idx, inclusive?}),
    do: fn right ->
      traverse_array(fn base -> {:slice, base, left, right_idx, inclusive?} end, right)
    end

  defp traversal_fun({:projection, obj}),
    do: fn right -> traverse_projection(fn base -> {:projection, base, obj} end, right) end

  defp traversal_fun({:square_bracket, expr}) do
    case const_eval(expr) do
      {:ok, n} when is_number(n) ->
        index = Barkpark.Groq.Values.num(n)

        unless is_integer(index),
          do: throw({:groq_parse_error, "an array index must be an integer", 0})

        fn right -> traverse_element(fn base -> {:elem, base, index} end, right) end

      {:ok, name} when is_binary(name) ->
        fn right -> traverse_plain(fn base -> {:attr, base, name} end, right) end

      _ ->
        fn right -> traverse_array(fn base -> {:filter, base, expr} end, right) end
    end
  end

  defp join(a, b), do: fn base -> b.(a.(base)) end
  defp map_t(inner), do: fn base -> {:map, base, inner.({:this})} end
  defp flat_map_t(inner), do: fn base -> {:flat_map, base, inner.({:this})} end

  defp traverse_array(build, nil), do: {:aa, build}
  defp traverse_array(build, {:aa, rb}), do: {:aa, join(build, rb)}
  defp traverse_array(build, {:ab, rb}), do: {:ab, join(build, rb)}
  defp traverse_array(build, {:bb, rb}), do: {:aa, join(build, map_t(rb))}
  defp traverse_array(build, {:ba, rb}), do: {:aa, join(build, flat_map_t(rb))}

  defp traverse_plain(mapper, nil), do: {:bb, mapper}
  defp traverse_plain(mapper, {kind, rb}) when kind in [:aa, :ba], do: {:ba, join(mapper, rb)}
  defp traverse_plain(mapper, {kind, rb}) when kind in [:ab, :bb], do: {:bb, join(mapper, rb)}

  defp traverse_element(mapper, nil), do: {:ab, mapper}
  defp traverse_element(mapper, {kind, rb}) when kind in [:aa, :ba], do: {:aa, join(mapper, rb)}
  defp traverse_element(mapper, {kind, rb}) when kind in [:ab, :bb], do: {:ab, join(mapper, rb)}

  defp traverse_projection(mapper, nil), do: {:bb, mapper}
  defp traverse_projection(mapper, {:aa, rb}), do: {:aa, join(map_t(mapper), rb)}
  defp traverse_projection(mapper, {:ab, rb}), do: {:ab, join(map_t(mapper), rb)}
  defp traverse_projection(mapper, {:ba, rb}), do: {:ba, join(mapper, rb)}
  defp traverse_projection(mapper, {:bb, rb}), do: {:bb, join(mapper, rb)}

  # ── Constant evaluation (groq-js shared/constantEvaluate.ts) ─────────────

  @doc false
  def const_eval({:value, v}), do: {:ok, v}
  def const_eval({:group, b}), do: const_eval(b)

  def const_eval({:pos, b}) do
    case const_eval(b) do
      {:ok, n} when is_number(n) -> {:ok, n}
      {:ok, _} -> {:ok, nil}
      :error -> :error
    end
  end

  def const_eval({:neg, b}) do
    case const_eval(b) do
      {:ok, n} when is_number(n) -> {:ok, -n}
      {:ok, _} -> {:ok, nil}
      :error -> :error
    end
  end

  def const_eval({:op, op, l, r}) when op in ["+", "-", "*", "/", "%", "**"] do
    with {:ok, a} <- const_eval(l), {:ok, b} <- const_eval(r) do
      {:ok, Barkpark.Groq.Values.arith(op, a, b)}
    end
  end

  def const_eval(_), do: :error

  defp const_integer(expr) do
    case const_eval(expr) do
      {:ok, n} when is_number(n) ->
        case Barkpark.Groq.Values.num(n) do
          i when is_integer(i) -> i
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ── Validation of context-only nodes ─────────────────────────────────────

  # `=>` is legal only inside select() and as an object member; `asc`/`desc`
  # only as an order() argument. Those builders consume them, so any left in
  # the tree is misplaced.
  defp reject_marks!({:pair, _, _}, pos), do: throw({:groq_parse_error, "unexpected =>", pos})
  defp reject_marks!({:asc, _}, pos), do: throw({:groq_parse_error, "unexpected asc", pos})
  defp reject_marks!({:desc, _}, pos), do: throw({:groq_parse_error, "unexpected desc", pos})
  defp reject_marks!(node, _pos), do: node

  defp validate(node) do
    walk_validate(node, false)
    node
  end

  defp walk_validate({:pair, _, _}, _), do: throw({:groq_parse_error, "unexpected =>", 0})

  defp walk_validate({kind, inner}, in_order?) when kind in [:asc, :desc] do
    unless in_order?, do: throw({:groq_parse_error, "unexpected #{kind}", 0})
    walk_validate(inner, false)
  end

  defp walk_validate({:pipe, base, "order", args}, _) do
    walk_validate(base, false)
    Enum.each(args, &walk_validate(&1, true))
  end

  defp walk_validate({:select, alts, fallback}, _) do
    Enum.each(alts, fn {c, v} ->
      walk_validate(c, false)
      walk_validate(v, false)
    end)

    if fallback, do: walk_validate(fallback, false)
  end

  defp walk_validate({:object, attrs}, _) do
    Enum.each(attrs, fn
      {:attr_value, _name, v} -> walk_validate(v, false)
      {:splat, v} -> walk_validate(v, false)
      {:cond_splat, c, v} -> walk_validate(c, false) && walk_validate(v, false)
    end)
  end

  defp walk_validate({:array, elems}, _),
    do: Enum.each(elems, fn {e, _} -> walk_validate(e, false) end)

  defp walk_validate({:value, _}, _), do: :ok

  defp walk_validate(node, _) when is_tuple(node) do
    node
    |> Tuple.to_list()
    |> tl()
    |> Enum.each(fn
      child when is_tuple(child) -> walk_validate(child, false)
      list when is_list(list) -> Enum.each(list, &if(is_tuple(&1), do: walk_validate(&1, false)))
      _ -> :ok
    end)

    true
  end

  # ── Memoization of closed subqueries ─────────────────────────────────────

  # A subquery rooted at `*` that never reads `^` gives the same value wherever
  # it is evaluated, so `_id in *[_type == "x"]._id` inside a filter is computed
  # once per query instead of once per element. Such subtrees (other than the
  # root) are wrapped in `{:memo, node}`, nested ones included.
  defp memoize_closed(root), do: map_children(root, &memo_walk/1)

  defp memo_walk({:value, _} = node), do: node
  # A bare `*` stays bare: the evaluator reads `*[filter]` as one unit so the
  # filter's constraints reach the document source.
  defp memo_walk({:everything} = node), do: node

  defp memo_walk(node) when is_tuple(node) do
    inner = map_children(node, &memo_walk/1)
    if closed_query?(node), do: {:memo, inner}, else: inner
  end

  defp memo_walk(list) when is_list(list), do: Enum.map(list, &memo_walk/1)
  defp memo_walk(other), do: other

  defp map_children({:value, _} = node, _fun), do: node

  defp map_children(node, fun) when is_tuple(node) do
    [tag | rest] = Tuple.to_list(node)
    List.to_tuple([tag | Enum.map(rest, &map_child(&1, fun))])
  end

  defp map_child(child, fun) when is_tuple(child) or is_list(child), do: fun.(child)
  defp map_child(child, _fun), do: child

  defp closed_query?(node), do: rooted_at_everything?(node) and not reads_parent?(node)

  defp rooted_at_everything?({:everything}), do: true

  defp rooted_at_everything?({kind, base, _})
       when kind in [:filter, :projection, :map, :flat_map, :elem] and is_tuple(base),
       do: rooted_at_everything?(base)

  defp rooted_at_everything?({:attr, base, _}) when is_tuple(base),
    do: rooted_at_everything?(base)

  defp rooted_at_everything?({:slice, base, _, _, _}), do: rooted_at_everything?(base)
  defp rooted_at_everything?({:pipe, base, _, _}), do: rooted_at_everything?(base)

  defp rooted_at_everything?({kind, base}) when kind in [:deref, :array_coerce, :group],
    do: rooted_at_everything?(base)

  defp rooted_at_everything?(_), do: false

  defp reads_parent?({:parent, _}), do: true
  defp reads_parent?({:value, _}), do: false

  defp reads_parent?(node) when is_tuple(node),
    do: node |> Tuple.to_list() |> Enum.any?(&reads_parent?/1)

  defp reads_parent?(list) when is_list(list), do: Enum.any?(list, &reads_parent?/1)
  defp reads_parent?(_), do: false

  # ── Lexical helpers ──────────────────────────────────────────────────────

  defp at(s, pos) when pos >= 0 and pos < byte_size(s), do: :binary.at(s, pos)
  defp at(_s, _pos), do: nil

  defp binary_part_safe(s, pos, len) do
    if pos + len <= byte_size(s), do: binary_part(s, pos, len), else: ""
  end

  defp ident_start?(c), do: c in ?a..?z or c in ?A..?Z or c == ?_
  defp ident_char?(nil), do: false
  defp ident_char?(c), do: ident_start?(c) or c in ?0..?9

  defp ident_len(s, pos) do
    case at(s, pos) do
      c when is_integer(c) ->
        if ident_start?(c), do: count_while(s, pos + 1, &ident_char?/1) + 1, else: 0

      nil ->
        0
    end
  end

  defp digits_len(s, pos), do: count_while(s, pos, &(&1 in ?0..?9))

  defp count_while(s, pos, pred, n \\ 0) do
    case at(s, pos) do
      nil -> n
      c -> if pred.(c), do: count_while(s, pos + 1, pred, n + 1), else: n
    end
  end

  defp keyword?(s, pos, word) do
    size = byte_size(word)
    binary_part_safe(s, pos, size) == word and not ident_char?(at(s, pos + size))
  end

  @doc false
  def skip_ws(s, pos) do
    case at(s, pos) do
      c when c in [?\t, ?\n, ?\v, ?\f, ?\r, ?\s] ->
        skip_ws(s, pos + 1)

      0xC2 ->
        if at(s, pos + 1) in [0x85, 0xA0], do: skip_ws(s, pos + 2), else: pos

      ?/ ->
        if at(s, pos + 1) == ?/ do
          case :binary.match(s, "\n", scope: {pos, byte_size(s) - pos}) do
            {idx, _} -> skip_ws(s, idx + 1)
            :nomatch -> byte_size(s)
          end
        else
          pos
        end

      _ ->
        pos
    end
  end
end
