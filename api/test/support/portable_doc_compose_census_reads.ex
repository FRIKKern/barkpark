defmodule Barkpark.PortableDoc.ComposeCensus.Reads do
  @moduledoc """
  The top-level fields the reader reads on each block type, read off the reader's
  own source.

  An entry is a function clause whose first parameter is a map pattern with a
  `"type"` key (a literal, a module attribute, or a variable its guard narrows with
  `in` or `==`), or a `case`/`fn`/`=`/`<-` pattern with one. Its other literal keys
  are reads of those types, and so is every read of the variable the clause binds:
  `Map.get/fetch/has_key?/take`, `b["k"]`, `get_in`, a `case`, `=` or `<-` match,
  and every call the variable is passed to, followed into the callee's clauses
  whose own `"type"` pattern admits the type, with string arguments carried in
  (`blank_field?(b, "src")` reads `src`). A key bound by `Enum.*` or `for` over a
  literal list or attribute is each of its strings. A block passed on through
  `Map.put(b, "type", t)` is followed as `t`, and a key it `Map.put`s is not read.

  A function or `case` whose clauses also match a type the reader does not render
  (an inline node: `text`, `link`, `code` marks) dispatches on something else, so
  it is no entry.

  `reads/2` takes the source strings and the rendered types (`ComposeCensus.types/1`)
  and returns `%{type => [key]}`.
  """

  @map_reads [:get, :fetch, :fetch!, :has_key?, :pop, :get_lazy]
  @map_passes [:put, :put_new, :delete, :merge, :drop]
  @forms [:=, :., :__aliases__, :fn, :->, :when, :%{}, :{}, :__block__, :@, :&, :<<>>, :"::"]

  def reads(sources, types) do
    index = sources |> Enum.flat_map(&modules/1) |> Map.new()

    (heads(index, types) ++ inline(index, types))
    |> Enum.reduce(%{}, fn {type, keys}, acc ->
      Map.update(acc, type, MapSet.new(keys), &MapSet.union(&1, MapSet.new(keys)))
    end)
    |> Map.new(fn {type, keys} -> {type, keys |> MapSet.delete("type") |> Enum.sort()} end)
  end

  defp heads(index, types) do
    for {mod, %{defs: defs}} <- index,
        {_, clauses} <- defs,
        not foreign?(Enum.map(clauses, &first_param/1), types),
        {[first | _] = args, guard, body} <- clauses,
        {matched, keys, vars} = param(first, guard, mod, index),
        is_list(matched),
        type <- matched do
      w = %{vars: vars, env: %{}, type: type, mod: mod, index: index, seen: MapSet.new()}
      {type, keys ++ walk(body, %{w | env: literal_env(args, guard, w)})}
    end
  end

  defp inline(index, types) do
    for {mod, %{defs: defs}} <- index,
        {_, clauses} <- defs,
        {_, _, body} <- clauses,
        group <- collect(body, &patterns/1),
        not foreign?(group, types),
        pattern <- group,
        {call, guard} = split_head(pattern),
        {matched, keys, _} = param(call, guard, mod, index),
        is_list(matched),
        type <- matched,
        do: {type, keys}
  end

  defp patterns({op, _, [pattern, _]}) when op in [:=, :<-], do: [[pattern]]

  defp patterns({:case, _, [_, [do: clauses]]}),
    do: [for({:->, _, [[pattern], _]} <- clauses, do: pattern)]

  defp patterns({:fn, _, clauses}),
    do: [for({:->, _, [[pattern | _], _]} <- clauses, do: pattern)]

  defp patterns(_node), do: nil

  defp first_param({[first | _], _, _}), do: first
  defp first_param(_clause), do: nil

  defp foreign?(patterns, types) do
    Enum.any?(patterns, fn pattern ->
      Enum.any?(literal_types(pattern), &(&1 not in types))
    end)
  end

  defp literal_types({:when, _, [pattern, _]}), do: literal_types(pattern)
  defp literal_types({:=, _, parts}), do: Enum.flat_map(parts, &literal_types/1)

  defp literal_types({:%{}, _, pairs}) when is_list(pairs) do
    case List.keyfind(pairs, "type", 0) do
      {"type", type} when is_binary(type) -> [type]
      _ -> []
    end
  end

  defp literal_types(_pattern), do: []

  defp modules(source) do
    ast = source |> Code.string_to_quoted!() |> Macro.postwalk(&unpipe/1)

    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, parts}, [do: body]]} = node, acc ->
          {node, [{Module.concat(parts), module(body)} | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp unpipe({:|>, _, [left, {call, meta, args}]}) when is_list(args),
    do: {call, meta, [left | args]}

  defp unpipe(node), do: node

  defp module(body) do
    forms =
      case body do
        {:__block__, _, forms} -> forms
        form -> [form]
      end

    Enum.reduce(forms, %{attrs: %{}, defs: %{}, imports: []}, fn
      {:@, _, [{name, _, [value]}]}, acc when is_atom(name) ->
        put_in(acc, [:attrs, name], value)

      {:import, _, [{:__aliases__, _, parts} | _]}, acc ->
        update_in(acc.imports, &[List.last(parts) | &1])

      {kind, _, [head, [{:do, body} | _]]}, acc when kind in [:def, :defp] ->
        {call, guard} = split_head(head)

        case call do
          {name, _, nil} when is_atom(name) ->
            put_def(acc, name, [], guard, body)

          {name, _, args} when is_atom(name) and is_list(args) ->
            Enum.reduce(arities(args), acc, &put_def(&2, name, &1, guard, body))

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  defp put_def(acc, name, args, guard, body) do
    clause = {args, guard, body}

    update_in(
      acc.defs,
      &Map.update(&1, {name, length(args)}, [clause], fn cs -> cs ++ [clause] end)
    )
  end

  defp split_head({:when, _, [call, guard]}), do: {call, guard}
  defp split_head(call), do: {call, nil}

  defp arities(args) do
    full = Enum.map(args, &strip_default/1)
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    for drop <- 0..defaults, do: Enum.take(full, length(full) - drop)
  end

  defp strip_default({:\\, _, [param, _default]}), do: param
  defp strip_default(param), do: param

  defp param({:=, _, [a, b]}, guard, mod, index) do
    {ta, ka, va} = param(a, guard, mod, index)
    {tb, kb, vb} = param(b, guard, mod, index)
    {if(ta == :untyped, do: tb, else: ta), ka ++ kb, va ++ vb}
  end

  defp param({:%{}, _, pairs}, guard, mod, index) when is_list(pairs) do
    keys = for {k, _} <- pairs, is_binary(k), do: k

    types =
      case List.keyfind(pairs, "type", 0) do
        nil -> :untyped
        {"type", value} -> type_set(value, guard, mod, index)
      end

    {types, keys, []}
  end

  defp param({var, _, ctx}, _guard, _mod, _index) when is_atom(var) and is_atom(ctx),
    do: {:untyped, [], if(String.starts_with?(Atom.to_string(var), "_"), do: [], else: [var])}

  defp param(_other, _guard, _mod, _index), do: {:untyped, [], []}

  defp type_set({var, _, ctx}, guard, mod, index) when is_atom(var) and is_atom(ctx) do
    case guard_strings(guard, var, mod, index) do
      [] -> :any
      types -> types
    end
  end

  defp type_set(value, _guard, mod, index), do: List.wrap(strings(value, mod, index))

  defp guard_strings(guard, var, mod, index) do
    collect(guard, fn
      {:in, _, [{^var, _, _}, list]} -> List.wrap(strings(list, mod, index))
      {:==, _, [{^var, _, _}, value]} -> List.wrap(strings(value, mod, index))
      _ -> nil
    end)
  end

  defp strings(value, _mod, _index) when is_binary(value), do: value

  defp strings({:sigil_w, _, [{:<<>>, _, [words]}, []]}, _mod, _index),
    do: String.split(words)

  defp strings({:@, _, [{name, _, _}]}, mod, index) do
    case index[mod].attrs do
      %{^name => value} -> strings(value, mod, index)
      _ -> nil
    end
  end

  defp strings({:++, _, [a, b]}, mod, index),
    do: List.wrap(strings(a, mod, index)) ++ List.wrap(strings(b, mod, index))

  defp strings({{:., _, [{:__aliases__, _, parts}, fun]}, _, []}, _mod, index) do
    case short(index, List.last(parts)) do
      {target, %{defs: %{{^fun, 0} => [{[], nil, body}]}}} -> strings(body, target, index)
      _ -> nil
    end
  end

  defp strings(list, mod, index) when is_list(list) do
    {init, tail} =
      case List.last(list) do
        {:|, _, [h, t]} -> {Enum.drop(list, -1) ++ [h], List.wrap(strings(t, mod, index))}
        _ -> {list, []}
      end

    Enum.flat_map(init, &List.wrap(strings(&1, mod, index))) ++ tail
  end

  defp strings(_value, _mod, _index), do: nil

  defp literal_env(args, guard, w) do
    bound =
      for {var, _, ctx} <- args,
          is_atom(var) and is_atom(ctx),
          not Map.has_key?(w.env, var),
          values = guard_strings(guard, var, w.mod, w.index),
          values != [],
          into: %{},
          do: {var, values}

    Map.merge(w.env, bound)
  end

  defp walk(body, w) do
    w = %{w | vars: aliases(body, MapSet.new(w.vars))}
    collect(body, &read(&1, w))
  end

  defp aliases(body, vars) do
    more =
      collect(body, fn
        {op, _, [pattern, value]} when op in [:=, :<-] ->
          if tracked?(value, vars), do: bound(pattern), else: nil

        _ ->
          nil
      end)

    grown = MapSet.union(vars, MapSet.new(more))
    if grown == vars, do: vars, else: aliases(body, grown)
  end

  defp bound({:=, _, [a, b]}), do: bound(a) ++ bound(b)
  defp bound({var, _, ctx}) when is_atom(var) and is_atom(ctx), do: [var]
  defp bound(_pattern), do: []

  defp read({{:., _, [{:__aliases__, _, [:Map]}, fun]}, _, [value, key | _]}, w)
       when fun in @map_reads,
       do: if(tracked?(value, w.vars), do: keys(key, w.env))

  defp read({{:., _, [{:__aliases__, _, [:Map]}, :take]}, _, [value, list]}, w),
    do: if(tracked?(value, w.vars), do: Enum.filter(List.wrap(list), &is_binary/1))

  defp read({{:., _, [Access, :get]}, _, [value, key]}, w),
    do: if(tracked?(value, w.vars), do: keys(key, w.env))

  defp read({:get_in, _, [value, [key | _]]}, w),
    do: if(tracked?(value, w.vars), do: keys(key, w.env))

  defp read({:case, _, [value, [do: clauses]]}, w) do
    if tracked?(value, w.vars) do
      for {:->, _, [[pattern], _]} <- clauses,
          {call, guard} = split_head(pattern),
          {types, keys, _} = param(call, guard, w.mod, w.index),
          admits?(types, w.type),
          key <- keys,
          do: key
    end
  end

  defp read({op, _, [pattern, value]}, w) when op in [:=, :<-] do
    if tracked?(value, w.vars), do: elem(param(pattern, nil, w.mod, w.index), 1)
  end

  defp read({{:., _, [{:__aliases__, _, [:Enum]}, _]}, _, [list | rest]}, w) do
    for {:fn, _, [{:->, _, [[{key, _, ctx} | _], body]}]} <- rest,
        is_atom(key) and is_atom(ctx),
        found <- List.wrap(bound_walk(list, key, body, w)),
        do: found
  end

  defp read({:for, _, [{:<-, _, [{key, _, ctx}, list]} | rest]}, w)
       when is_atom(key) and is_atom(ctx),
       do: bound_walk(list, key, rest, w)

  defp read({{:., _, [{:__aliases__, _, parts}, fun]}, _, args}, w) when is_list(args) do
    case short(w.index, List.last(parts)) do
      {target, _} -> call(target, fun, args, w)
      nil -> nil
    end
  end

  defp read({fun, _, args}, w) when is_atom(fun) and is_list(args) and fun not in @forms do
    imported = for i <- w.index[w.mod].imports, {m, _} <- [short(w.index, i)], do: m

    target =
      Enum.find([w.mod | imported], &Map.has_key?(w.index[&1].defs, {fun, length(args)}))

    if target, do: call(target, fun, args, w)
  end

  defp read(_node, _w), do: nil

  defp bound_walk(list, key, body, w) do
    case strings(list, w.mod, w.index) do
      [_ | _] = values -> walk(body, %{w | env: Map.put(w.env, key, values)})
      _ -> nil
    end
  end

  defp call(target, fun, args, w) do
    tracks =
      for {arg, pos} <- Enum.with_index(args), track = track(arg, w.vars), track, do: {pos, track}

    passed = Enum.map(tracks, &elem(&1, 0))
    type = Enum.find_value(tracks, w.type, fn {_, {override, _}} -> override end)
    forced = Enum.flat_map(tracks, fn {_, {_, forced}} -> forced end)
    given = Enum.map(args, &given(&1, w.env))
    visit = {target, fun, length(args), passed, given, type}

    if passed != [] and not MapSet.member?(w.seen, visit) do
      w = %{w | type: type, mod: target, seen: MapSet.put(w.seen, visit)}

      for {params, guard, body} <- Map.get(w.index[target].defs, {fun, length(args)}, []),
          applies?(params, given),
          key <- clause(params, guard, body, passed, given, w),
          key not in forced,
          do: key
    end
  end

  defp track({var, _, ctx} = value, vars) when is_atom(var) and is_atom(ctx),
    do: if(tracked?(value, vars), do: {nil, []})

  defp track({{:., _, [{:__aliases__, _, [:Map]}, fun]}, _, [inner | rest]}, vars)
       when fun in @map_passes do
    with {override, forced} <- track(inner, vars) do
      case {fun, rest} do
        {:put, ["type", new]} when is_binary(new) -> {new, forced}
        {:put, [key, _]} when is_binary(key) -> {override, [key | forced]}
        _ -> {override, forced}
      end
    end
  end

  defp track(_value, _vars), do: nil

  defp given(value, _env) when is_binary(value), do: [value]
  defp given({var, _, ctx}, env) when is_atom(var) and is_atom(ctx), do: Map.get(env, var)
  defp given(_value, _env), do: nil

  defp applies?(params, given) do
    params
    |> Enum.zip(given)
    |> Enum.all?(fn
      {literal, values} when is_binary(literal) and is_list(values) -> literal in values
      _ -> true
    end)
  end

  defp clause(params, guard, body, passed, given, w) do
    tracked = for pos <- passed, do: param(Enum.at(params, pos), guard, w.mod, w.index)

    if Enum.all?(tracked, fn {types, _, _} -> admits?(types, w.type) end) do
      carried =
        for {{var, _, ctx}, values} <- Enum.zip(params, given),
            is_atom(var) and is_atom(ctx) and is_list(values),
            into: %{},
            do: {var, values}

      w = %{w | env: carried, vars: Enum.flat_map(tracked, &elem(&1, 2))}

      Enum.flat_map(tracked, &elem(&1, 1)) ++
        walk(body, %{w | env: literal_env(params, guard, w)})
    else
      []
    end
  end

  defp admits?(types, type) when is_list(types), do: type in types
  defp admits?(_any_or_untyped, _type), do: true

  defp tracked?({var, _, ctx}, vars) when is_atom(var) and is_atom(ctx),
    do: MapSet.member?(vars, var)

  defp tracked?(_value, _vars), do: false

  defp keys(key, _env) when is_binary(key), do: [key]
  defp keys({var, _, ctx}, env) when is_atom(var) and is_atom(ctx), do: Map.get(env, var)
  defp keys(_key, _env), do: nil

  defp short(index, last) do
    name = to_string(last)
    Enum.find(index, fn {mod, _} -> mod |> Module.split() |> List.last() == name end)
  end

  defp collect(ast, fun) do
    {_, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case fun.(node) do
          nil -> {node, acc}
          found -> {node, acc ++ List.wrap(found)}
        end
      end)

    acc
  end
end
