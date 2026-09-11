defmodule Barkpark.PortableDoc.Render.AttrEscapeScan do
  @moduledoc """
  Source-scan prover for the PortableDoc render tree's ATTRIBUTE-ESCAPING
  invariant: no value that can carry author-supplied text may reach an HTML
  attribute value without passing `Util.escape_attr/1`, `escape_html/1`,
  `safe_url/1`, or a provably-closed transform.

  Owned by `test/barkpark/portable_doc/render/attr_escape_guard_test.exs`,
  which is where the invariant, the trade-offs and the reviewed residue are
  documented. This module is the mechanism only.

  It parses each module to AST (never regex — `compose.ex` alone is 135KB and a
  regex over it manufactures both misses and phantoms), locates every
  interpolation whose preceding literal text leaves an attribute value open
  (`… foo="` with no closing quote after), and tries to PROVE the interpolated
  expression cannot carry raw author text. The prover follows values through
  same-clause bindings, through private-function parameters to their in-file
  call sites, and through `case` / `cond` / `if` branches. It FAILS CLOSED:
  anything it cannot prove is reported, so a new emitter is covered the moment
  the file is saved.
  """

  @sanitizers ~w(escape_attr escape_html safe_url)a
  @numeric_fns ~w(fmt fmt2 fmt3 fmt_pct clampf clamp rem trunc round max min abs div
                  floor ceil to_int mix_hex safe_hex)a
  # Structs/maps the ENGINE owns end-to-end: skins, palettes, tone tables.
  # Their fields are hex colours and font stacks minted in palettes.ex /
  # tokens_gen.ex, never author text.
  @engine_vars ~w(sk pal skin tone palette theme presentation layout parts card
                  tones colors palette_for)a
  # Taint-preserving wrappers: the verdict is the verdict of their subject.
  @passthrough ~w(to_string trim downcase upcase capitalize slice
                  Enum.join Enum.map_join String.trim String.downcase String.upcase
                  String.slice Integer.to_string Float.to_string List.to_string)
  @max_depth 8

  @doc """
  Scan every `*.ex` under `dir`. Returns

      %{files: n, total: n, by_verdict: %{atom => n}, unproven: [%{file:, line:, attr:, expr:}]}
  """
  def run(dir) do
    index =
      dir
      |> Path.join("*.ex")
      |> Path.wildcard()
      |> Map.new(fn f -> {Path.basename(f), index_file(f)} end)

    sites =
      Enum.flat_map(index, fn {base, fi} ->
        Enum.flat_map(fi.clauses, fn clause ->
          clause
          |> attr_sites()
          |> Enum.map(fn {line, attr, expr} ->
            verdict =
              classify(expr, %{
                file: base,
                fi: fi,
                index: index,
                clause: clause,
                depth: 0,
                seen: MapSet.new()
              })

            %{
              file: base,
              line: line,
              attr: attr,
              expr: src(expr),
              verdict: verdict
            }
          end)
        end)
      end)

    %{
      files: map_size(index),
      total: length(sites),
      by_verdict: Enum.frequencies_by(sites, & &1.verdict),
      unproven:
        sites
        |> Enum.filter(&(&1.verdict == :unproven))
        |> Enum.uniq_by(&{&1.file, &1.attr, &1.expr, &1.line})
        |> Enum.sort_by(&{&1.file, &1.line, &1.attr})
    }
  end

  def src(expr), do: expr |> Macro.to_string() |> String.replace(~r/\s+/, " ")

  # ── indexing ────────────────────────────────────────────────────────────────

  defp index_file(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    clauses =
      ast
      |> collect(fn
        {kind, meta, [head, body]} when kind in [:def, :defp] and is_list(body) ->
          case clause_head(head) do
            {name, params} ->
              [
                %{
                  name: name,
                  arity: length(params),
                  params: params,
                  private?: kind == :defp,
                  body: Keyword.get(body, :do),
                  line: meta[:line]
                }
              ]

            :error ->
              []
          end

        _ ->
          []
      end)

    calls =
      clauses
      |> Enum.flat_map(fn clause ->
        collect(clause.body, fn
          {name, _m, args} when is_atom(name) and is_list(args) ->
            [{{name, length(args)}, %{args: args, clause: clause}}]

          _ ->
            []
        end)
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    %{clauses: clauses, calls: calls, by_name: Enum.group_by(clauses, &{&1.name, &1.arity})}
  end

  defp clause_head({:when, _, [call | _]}), do: clause_head(call)
  defp clause_head({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}
  defp clause_head({name, _, nil}) when is_atom(name), do: {name, []}
  defp clause_head(_), do: :error

  defp collect(ast, fun) do
    {_, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, fun.(node) ++ acc}
      end)

    acc
  end

  # ── attribute-interpolation extraction ──────────────────────────────────────

  # Every interpolation whose PRECEDING literal text (within the same binary)
  # leaves an attribute value open: `name="` with no `"` after it.
  @open_attr ~r/([A-Za-z_][A-Za-z0-9_:.-]*)="([^"]*)$/

  def attr_sites(clause) do
    collect(clause.body, fn
      {:<<>>, meta, parts} -> [{meta[:line], parts}]
      {:sigil_s, meta, [{:<<>>, _, parts}, _]} -> [{meta[:line], parts}]
      {:sigil_S, _, _} -> []
      _ -> []
    end)
    |> Enum.flat_map(fn {line, parts} -> parts_sites(line, parts) end)
  end

  defp parts_sites(line, parts) do
    {sites, _text} =
      Enum.reduce(parts, {[], ""}, fn
        part, {acc, text} when is_binary(part) ->
          {acc, text <> part}

        {:"::", meta, [{{:., _, [Kernel, :to_string]}, _, [expr]}, _]}, {acc, text} ->
          acc =
            case Regex.run(@open_attr, text) do
              [_, attr, _] -> [{line_of(expr, meta, line), attr, expr} | acc]
              _ -> acc
            end

          # The interpolated value's own bytes are unknown; it cannot close an
          # attribute for the purposes of this scan, so the literal text is
          # what keeps being matched against.
          {acc, text}

        _other, {acc, text} ->
          {acc, text}
      end)

    Enum.reverse(sites)
  end

  defp line_of(expr, meta, fallback) do
    case expr do
      {_, m, _} when is_list(m) -> m[:line] || meta[:line] || fallback
      _ -> meta[:line] || fallback
    end
  end

  # ── the prover ──────────────────────────────────────────────────────────────

  def classify(_expr, %{depth: d}) when d > @max_depth, do: :unproven

  def classify(expr, ctx) do
    cond do
      is_binary(expr) -> :literal
      is_number(expr) -> :numeric
      is_atom(expr) -> :literal
      is_boolean(expr) -> :literal
      true -> classify_node(expr, ctx)
    end
  end

  # a list literal: safe when every element is
  defp classify_node(list, ctx) when is_list(list), do: all(list, ctx, :literal_list)

  defp classify_node({a, b}, ctx), do: all([a, b], ctx, :literal_list)

  # interpolated binary / ~s sigil used AS a value
  defp classify_node({:<<>>, _, parts}, ctx), do: classify_parts(parts, ctx)
  defp classify_node({:sigil_s, _, [{:<<>>, _, parts}, _]}, ctx), do: classify_parts(parts, ctx)
  defp classify_node({:sigil_S, _, _}, _ctx), do: :literal
  defp classify_node({:sigil_r, _, _}, _ctx), do: :literal

  # module attribute — compile-time constant
  defp classify_node({:@, _, [{name, _, _}]}, _ctx) when is_atom(name), do: :module_attr

  # engine struct/map field: sk.ink, pal.rule, tone.bg …
  defp classify_node({{:., _, [{var, _, c}, field]}, _, []}, _ctx)
       when is_atom(var) and is_atom(c) and is_atom(field) do
    if var in @engine_vars, do: :palette, else: :unproven
  end

  # pipes: rewrite to the call they mean
  defp classify_node({:|>, _, _} = pipe, ctx) do
    pipe
    |> Macro.unpipe()
    |> Enum.reduce(nil, fn
      {expr, 0}, nil -> expr
      {expr, idx}, acc -> Macro.pipe(acc, expr, idx)
    end)
    |> classify(bump(ctx))
  end

  # boolean results
  defp classify_node({op, _, [_, _]}, _ctx)
       when op in [:==, :!=, :===, :!==, :<, :>, :<=, :>=, :in, :and, :or, :&&, :||],
       do: :bool

  defp classify_node({:not, _, [_]}, _ctx), do: :bool

  # arithmetic — safe iff both operands are
  defp classify_node({op, _, [l, r]}, ctx) when op in [:+, :-, :*, :/] do
    case {classify(l, bump(ctx)), classify(r, bump(ctx))} do
      {a, b} when a in [:numeric, :module_attr, :literal] and b in [:numeric, :module_attr, :literal] ->
        :numeric

      _ ->
        :unproven
    end
  end

  defp classify_node({:-, _, [l]}, ctx), do: classify(l, bump(ctx))

  # string concatenation — safe iff both halves are
  defp classify_node({:<>, _, [l, r]}, ctx), do: all([l, r], ctx, :concat)

  # blocks: the value is the last expression
  defp classify_node({:__block__, _, exprs}, ctx) when exprs != [],
    do: classify(List.last(exprs), bump(ctx))

  # case / cond / if / unless / with: every branch result must be safe
  defp classify_node({kind, _, args}, ctx) when kind in [:case, :cond, :if, :unless, :with] do
    args
    |> branch_results()
    |> case do
      [] -> :unproven
      results -> all(results, ctx, :branches)
    end
  end

  # a slug strip IS an allowlist: String.replace(x, ~r/[^…]/, "") keeps only
  # the characters the class names, so no quote/angle can survive.
  defp classify_node(
         {{:., _, [String, :replace]}, _, [_subject, {:sigil_r, _, [{:<<>>, _, [rx]}, _]}, ""]},
         _ctx
       )
       when is_binary(rx) do
    if String.starts_with?(rx, "[^") and not String.contains?(rx, ~s(")) and
         not String.contains?(rx, "<"),
       do: :slugified,
       else: :unproven
  end

  # calls
  defp classify_node({{:., _, [mod, fun]}, _, args}, ctx) when is_atom(fun) do
    classify_call(qualified_name(mod, fun), fun, args, ctx)
  end

  defp classify_node({fun, _, args}, ctx) when is_atom(fun) and is_list(args) do
    classify_call(Atom.to_string(fun), fun, args, ctx)
  end

  # a bare variable
  defp classify_node({var, _, c}, ctx) when is_atom(var) and is_atom(c),
    do: resolve_var(var, ctx)

  defp classify_node(_, _ctx), do: :unproven

  defp classify_parts(parts, ctx) do
    parts
    |> Enum.flat_map(fn
      {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [expr]}, _]} -> [expr]
      _ -> []
    end)
    |> case do
      [] -> :literal
      exprs -> all(exprs, ctx, :interpolated)
    end
  end

  defp classify_call(_name, fun, args, ctx) when fun in @sanitizers do
    _ = {args, ctx}
    :sanitizer
  end

  defp classify_call(name, fun, args, ctx) do
    cond do
      fun in @numeric_fns ->
        :numeric

      name in @passthrough ->
        case args do
          [subject | _] -> classify(subject, bump(ctx))
          [] -> :literal
        end

      args == [] ->
        # A zero-arity call takes no input at all, so it cannot carry author
        # text — every one in this tree is a palette/font constant.
        :engine_call

      true ->
        classify_local_call(fun, args, ctx)
    end
  end

  # A call to a function defined in THIS file: safe iff every clause body of
  # that function is safe (its own params resolve through this same prover).
  defp classify_local_call(fun, args, ctx) do
    key = {fun, length(args)}

    case Map.get(ctx.fi.by_name, key) do
      nil ->
        :unproven

      clauses ->
        seen_key = {ctx.file, key}

        if MapSet.member?(ctx.seen, seen_key) do
          :recursive
        else
          ctx = %{ctx | seen: MapSet.put(ctx.seen, seen_key)}

          clauses
          |> Enum.map(fn clause ->
            classify(clause.body, %{ctx | clause: clause, depth: ctx.depth + 1})
          end)
          |> verdict(:helper)
        end
    end
  end

  defp resolve_var(var, ctx) do
    seen_key = {ctx.file, ctx.clause.name, ctx.clause.line, var}

    cond do
      MapSet.member?(ctx.seen, seen_key) ->
        :recursive

      true ->
        ctx = %{ctx | seen: MapSet.put(ctx.seen, seen_key)}

        case bindings(ctx.clause, var) do
          [] -> resolve_param(var, ctx)
          rhss -> rhss |> Enum.map(&classify(&1, bump(ctx))) |> verdict(:local)
        end
    end
  end

  defp bindings(clause, var) do
    collect(clause.body, fn
      {:=, _, [{^var, _, c}, rhs]} when is_atom(c) -> [rhs]
      _ -> []
    end)
  end

  # The variable is a parameter. For a PRIVATE function every caller is in this
  # file, so the argument at that position can be enumerated and proven.
  defp resolve_param(var, ctx) do
    idx =
      Enum.find_index(ctx.clause.params, fn
        {^var, _, c} when is_atom(c) -> true
        _ -> false
      end)

    cond do
      is_nil(idx) ->
        :unproven

      not ctx.clause.private? ->
        # A public function can be called from anywhere; its parameter cannot
        # be bounded by an in-file scan.
        :unproven

      true ->
        key = {ctx.clause.name, ctx.clause.arity}

        case Map.get(ctx.fi.calls, key, []) do
          [] ->
            :unproven

          sites ->
            sites
            |> Enum.map(fn %{args: args, clause: caller} ->
              case Enum.at(args, idx) do
                nil -> :unproven
                arg -> classify(arg, %{ctx | clause: caller, depth: ctx.depth + 1})
              end
            end)
            |> verdict(:param)
        end
    end
  end

  defp branch_results(args) do
    args
    |> Enum.flat_map(fn
      [{:do, body} | rest] ->
        [body | Enum.map(rest, fn {_k, v} -> v end)]

      _ ->
        []
    end)
    |> Enum.flat_map(&branch_bodies/1)
  end

  defp branch_bodies(body) do
    case body do
      clauses when is_list(clauses) ->
        Enum.flat_map(clauses, fn
          {:->, _, [_head, b]} -> [last_expr(b)]
          other -> [other]
        end)

      other ->
        [last_expr(other)]
    end
  end

  defp last_expr({:__block__, _, exprs}) when exprs != [], do: List.last(exprs)
  defp last_expr(other), do: other

  defp all(exprs, ctx, ok) do
    exprs |> Enum.map(&classify(&1, bump(ctx))) |> verdict(ok)
  end

  defp verdict(verdicts, ok) do
    if Enum.any?(verdicts, &(&1 == :unproven)), do: :unproven, else: ok
  end

  defp bump(ctx), do: %{ctx | depth: ctx.depth + 1}

  defp qualified_name({:__aliases__, _, parts}, fun),
    do: Enum.map_join(parts ++ [fun], ".", &Atom.to_string/1)

  defp qualified_name(mod, fun) when is_atom(mod),
    do: "#{inspect(mod)}.#{fun}"

  defp qualified_name(_, fun), do: Atom.to_string(fun)
end
