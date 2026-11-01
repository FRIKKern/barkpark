defmodule BarkparkWeb.PaperCanvasTKeys do
  @moduledoc """
  Every key the paper editor's source can hand its `t()` helper (src/i18n.js), read
  from the source at test time.

  A key reaches `t` (or `te`, or an alias such as `t as tr`) as a string or a
  template literal, a branch of `?:`, `||`, `??` or `&&`, a `const`, a value of a
  `const` object, a function's `return`, a `for … of` over a literal list, a
  parameter of a wrapper (followed to every call of that wrapper), or a property
  (`item.label`, `this._eyebrow`, a destructured `{ label }`), followed to every
  `label: …` entry and `.label = …` assignment in the same file. A `const` may
  come from another editor file through an `import`.

  `scan/1` answers `%{keys:, sites:}`; each site is a `t` call with the keys it
  reaches and the branches it could not follow. A site that reaches no key is
  one this reading cannot see.
  """

  alias BarkparkWeb.JsTokens

  @src Path.expand("../../assets/paper-editor/src", __DIR__)
  @i18n_import ~r/import\s*\{([^}]*)\}\s*from\s*["'](?:\.\.?\/)+i18n\.js["']/
  @keywords ~w(if for while switch catch function return typeof new delete void throw case do else in of instanceof yield await with)

  def scan(dir \\ @src) do
    files =
      for path <- Path.wildcard(Path.join(dir, "**/*.js")),
          not String.starts_with?(Path.basename(path), "__"),
          not String.contains?(path, "/__"),
          Path.basename(path) != "i18n.js",
          into: %{} do
        source = File.read!(path)

        {Path.relative_to(path, dir),
         %{source: source, tree: source |> JsTokens.lex() |> JsTokens.tree()}}
      end

    index = index(files)
    Process.put(__MODULE__, %{})

    sites =
      for {file, %{source: source}} <- Enum.sort(files),
          aliases = i18n_aliases(source),
          aliases != [],
          {args, line, scopes} <- calls(index.files[file], aliases) do
        {keys, misses} = resolve(first_arg(args), {file, scopes}, index, MapSet.new())
        %{file: file, line: line, keys: keys, misses: misses}
      end

    Process.delete(__MODULE__)
    all = Enum.flat_map(sites, & &1.keys)

    %{
      keys: all |> Enum.filter(&is_binary/1) |> MapSet.new(),
      patterns: all |> Enum.reject(&is_binary/1) |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
      sites: sites
    }
  end

  def i18n_aliases(source) do
    for [names] <- Regex.scan(@i18n_import, source, capture: :all_but_first),
        part <- String.split(names, ","),
        part = String.trim(part),
        part != "",
        [name | rest] = String.split(part, ~r/\s+as\s+/),
        name in ["t", "te"],
        do: List.first(rest, name)
  end

  # ── index: what each file declares, calls and assigns ─────────────────────────

  defp index(files) do
    per_file =
      Map.new(files, fn {file, %{source: source, tree: tree}} ->
        {file,
         walk(tree, file, [], %{
           fns: %{},
           consts: %{},
           calls: [],
           entries: [],
           assigns: [],
           t_calls: [],
           imports: imports(source),
           modules: modules(source, file)
         })}
      end)

    %{
      files: per_file,
      entries:
        Enum.flat_map(per_file, fn {_f, i} -> i.entries end)
        |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0)),
      assigns:
        Enum.flat_map(per_file, fn {_f, i} -> i.assigns end)
        |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))
    }
  end

  defp modules(source, file) do
    for [path] <- Regex.scan(~r/from\s*["'](\.\.?\/[^"']+)["']/, source, capture: :all_but_first),
        into: MapSet.new(),
        do: file |> Path.dirname() |> Path.join(path) |> Path.expand("/") |> Path.relative_to("/")
  end

  defp imports(source) do
    for [names] <- Regex.scan(~r/import\s*\{([^}]*)\}\s*from/, source, capture: :all_but_first),
        part <- String.split(names, ","),
        name = part |> String.split(~r/\s+as\s+/) |> hd() |> String.trim(),
        name != "",
        into: MapSet.new(),
        do: name
  end

  # Walk a token list; `scopes` is the stack of enclosing functions, innermost first.
  defp walk([], _file, _scopes, acc), do: acc

  defp walk(tokens, file, scopes, acc) do
    acc = note(tokens, file, scopes, acc)

    case named_function_at(tokens) || function_at(tokens) do
      {fun, rest} ->
        acc = put_fun(acc, fun, scopes)
        inner = [fun | scopes]
        acc = walk(fun.params, file, inner, acc)
        acc = walk(fun.body, file, inner, acc)
        walk(rest, file, scopes, acc)

      nil ->
        [tok | rest] = tokens

        case tok do
          {:group, open, children, _} ->
            acc = if open == "{", do: note_entries(children, file, scopes, acc), else: acc
            walk(rest, file, scopes, walk(children, file, scopes, acc))

          {:tpl, parts, _} ->
            acc = Enum.reduce(for({:expr, e} <- parts, do: e), acc, &walk(&1, file, scopes, &2))
            walk(rest, file, scopes, acc)

          _ ->
            walk(rest, file, scopes, acc)
        end
    end
  end

  # `const f = (…) => …`, `f: (…) => …`, `f = function (…) {…}`: the function takes the name.
  defp named_function_at([{:id, kind, _}, {:id, name, _}, {:p, "=", _} | rest])
       when kind in ["const", "let", "var"],
       do: rename(function_at(rest), name)

  defp named_function_at([{:id, name, _}, {:p, op, _} | rest])
       when op in [":", "="] and name not in @keywords,
       do: rename(function_at(rest), name)

  defp named_function_at(_), do: nil

  defp rename(nil, _name), do: nil
  defp rename({fun, rest}, name), do: {%{fun | name: name}, rest}

  # `function name(…) {…}`, `name(…) {…}` (a method), `(…) => …`, `x => …`.
  defp function_at([{:id, "function", _} | rest]) do
    {name, rest} =
      case rest do
        [{:p, "*", _}, {:id, name, _} | rest] -> {name, rest}
        [{:id, name, _} | rest] -> {name, rest}
        rest -> {nil, rest}
      end

    case rest do
      [{:group, "(", params, _}, {:group, "{", body, _} | rest] -> {fun(name, params, body), rest}
      _ -> nil
    end
  end

  defp function_at([{:id, name, _}, {:group, "(", params, _}, {:group, "{", body, _} | rest])
       when name not in @keywords,
       do: {fun(name, params, body), rest}

  defp function_at([{:group, "(", params, _}, {:p, "=>", _} | rest]), do: arrow(params, rest)
  defp function_at([{:id, param, l}, {:p, "=>", _} | rest]), do: arrow([{:id, param, l}], rest)
  defp function_at(_), do: nil

  defp arrow(params, [{:group, "{", body, _} | rest]), do: {fun(nil, params, body, :block), rest}

  defp arrow(params, rest) do
    {body, rest} = Enum.split_while(rest, &(not match?({:p, op, _} when op in [",", ";"], &1)))
    {fun(nil, params, body, :expr), rest}
  end

  defp fun(name, params, body, kind \\ :block),
    do: %{name: name, params: param_names(params), body: body, kind: kind, ref: make_ref()}

  defp param_names(params) do
    params
    |> split(",")
    |> Enum.map(fn
      [{:p, "...", _}, {:id, name, _} | _] ->
        {:name, name}

      [{:id, name, _} | _] ->
        {:name, name}

      [{:group, "{", inner, _} | _] ->
        {:props, for([{:id, n, _} | _] <- split(inner, ","), do: n)}

      _ ->
        :other
    end)
  end

  defp put_fun(acc, %{name: nil}, _scopes), do: acc
  defp put_fun(acc, fun, scopes), do: put_in(acc, [:fns, fun.name], {fun, scopes})

  # Name an anonymous function after what it is assigned to: `const f = (…) =>`, `f: (…) =>`.
  defp note([{:id, kind, _}, {:id, name, _}, {:p, "=", _} | rest], _file, scopes, acc)
       when kind in ["const", "let", "var"] do
    {expr, _} = statement(rest)
    put_in(acc, [:consts, name], [{expr, scopes} | Map.get(acc.consts, name, [])])
  end

  defp note(
         [{:id, kind, _}, {:group, "[", pattern, _}, {:id, "of", _} | rest],
         _file,
         scopes,
         acc
       )
       when kind in ["const", "let", "var"] do
    {expr, _} = statement(rest)

    pattern
    |> split(",")
    |> Enum.with_index()
    |> Enum.reduce(acc, fn
      {[{:id, name, _} | _], i}, acc ->
        put_in(acc, [:consts, name], [
          {{:of_index, expr, i}, scopes} | Map.get(acc.consts, name, [])
        ])

      _, acc ->
        acc
    end)
  end

  defp note(
         [{:id, kind, _}, {:group, "{", pattern, _}, {:id, "of", _} | rest],
         _file,
         scopes,
         acc
       )
       when kind in ["const", "let", "var"] do
    {expr, _} = statement(rest)

    Enum.reduce(split(pattern, ","), acc, fn
      [{:id, name, _} | _], acc ->
        put_in(acc, [:consts, name], [
          {{:of_prop, expr, name}, scopes} | Map.get(acc.consts, name, [])
        ])

      _, acc ->
        acc
    end)
  end

  defp note([{:id, kind, _}, {:id, name, _}, {:id, "of", _} | rest], _file, scopes, acc)
       when kind in ["const", "let", "var"] do
    {expr, _} = statement(rest)
    put_in(acc, [:consts, name], [{{:of_each, expr}, scopes} | Map.get(acc.consts, name, [])])
  end

  defp note([{:p, ".", _}, {:id, prop, _}, {:p, "=", _} | rest], file, scopes, acc) do
    {expr, _} = statement(rest)
    %{acc | assigns: [{prop, expr, file, scopes} | acc.assigns]}
  end

  defp note([{:id, name, line}, {:group, "(", args, _} | _], _file, scopes, acc) do
    %{
      acc
      | calls: [{name, args, scopes} | acc.calls],
        t_calls: [{name, args, line, scopes} | acc.t_calls]
    }
  end

  defp note(_tokens, _file, _scopes, acc), do: acc

  defp note_entries(children, file, scopes, acc) do
    children
    |> split(",")
    |> Enum.reduce(acc, fn
      [{kind, key, _}, {:p, ":", _} | value], acc
      when kind in [:id, :str] and key not in ["case", "default"] ->
        %{acc | entries: [{key, value, file, scopes} | acc.entries]}

      _, acc ->
        acc
    end)
  end

  defp calls(file_index, aliases) do
    file_index.t_calls
    |> Enum.filter(fn {name, _args, _line, _scopes} -> name in aliases end)
    |> Enum.reverse()
    |> Enum.map(fn {_name, args, line, scopes} -> {args, line, scopes} end)
  end

  defp first_arg(args), do: args |> split(",") |> List.first([])

  # ── resolve: the keys an expression can be ────────────────────────────────────

  defp resolve(expr, ctx, index, seen) do
    key = {expr, elem(ctx, 0)}

    if MapSet.member?(seen, key) do
      {[], []}
    else
      do_resolve(strip(expr), ctx, index, MapSet.put(seen, key))
    end
  end

  defp do_resolve(expr, ctx, index, seen) do
    cond do
      expr == [] ->
        {[], []}

      (parts = ternary(expr)) != nil ->
        union(parts, ctx, index, seen)

      (parts = split_any(expr, ["||", "??"])) |> length() > 1 ->
        union(parts, ctx, index, seen)

      (parts = split(expr, "&&")) |> length() > 1 ->
        resolve(List.last(parts), ctx, index, seen)

      true ->
        term(expr, ctx, index, seen)
    end
  end

  defp term([{:str, "", _}], _ctx, _index, _seen), do: {[], []}
  defp term([{:str, value, _}], _ctx, _index, _seen), do: {[value], []}

  defp term([{:tpl, parts, line}], {file, _}, _index, _seen) do
    if Enum.all?(parts, &is_binary/1),
      do: {[Enum.join(parts)], []},
      else: {[{:pattern, pattern(parts)}], [{file, line, "a template literal with ${…}"}]}
  end

  defp term([{:group, "(", inner, _}], ctx, index, seen), do: resolve(inner, ctx, index, seen)

  defp term([{:id, name, line}], ctx, index, seen), do: identifier(name, line, ctx, index, seen)

  defp term([{:id, name, line}, {:group, "(", _args, _}], ctx, index, seen),
    do: returns(name, line, ctx, index, seen)

  defp term(expr, ctx, index, seen) do
    case Enum.reverse(expr) do
      [{:id, prop, _}, {:p, dot, _} | object] when dot in [".", "?."] ->
        member(Enum.reverse(object), {:prop, prop}, ctx, index, seen)

      [{:group, "[", _key, _} | object] ->
        member(Enum.reverse(object), :any, ctx, index, seen)

      _ ->
        {[], [{elem(ctx, 0), line_of(expr), "an expression it cannot follow"}]}
    end
  end

  defp member([{:id, name, _}], selector, {file, scopes} = ctx, index, seen) do
    case object_const(name, file, scopes, index) do
      nil -> by_selector(selector, ctx, index, seen)
      {entries, octx} -> object_values(entries, selector, octx, index, seen)
    end
  end

  defp member(_object, selector, ctx, index, seen), do: by_selector(selector, ctx, index, seen)

  defp by_selector({:prop, prop}, ctx, index, seen), do: property(prop, ctx, index, seen)

  defp by_selector(:any, {file, _}, _index, _seen),
    do: {[], [{file, 0, "a computed property of an unknown object"}]}

  defp object_values(entries, {:prop, prop}, ctx, index, seen),
    do: union(for({^prop, value} <- entries, do: value), ctx, index, seen)

  defp object_values(entries, :any, ctx, index, seen),
    do: union(Enum.map(entries, &elem(&1, 1)), ctx, index, seen)

  # `Edit empty ${type}` reads as the pattern ^Edit empty .+$: some key must fit it.
  defp pattern(parts),
    do:
      "^" <>
        Enum.map_join(parts, fn
          text when is_binary(text) -> Regex.escape(text)
          {:expr, _} -> ".+"
        end) <> "$"

  defp object_const(name, file, scopes, index) do
    case binding(name, file, scopes, index) do
      {[{:group, "{", children, _}], bfile, bscopes} ->
        {entries(children), {bfile, bscopes}}

      _ ->
        nil
    end
  end

  defp entries(children),
    do:
      for(
        [{kind, key, _}, {:p, ":", _} | value] <- split(children, ","),
        kind in [:id, :str],
        do: {key, value}
      )

  # A property's keys: every `prop: …` entry and `.prop = …` assignment in the file.
  defp property(prop, {file, _} = ctx, index, seen),
    do: memo({:property, prop, file}, fn -> harvest(prop, ctx, index, seen) end)

  defp harvest(prop, {file, _}, index, seen) do
    sources =
      for {value, ^file, sscopes} <-
            Map.get(index.entries, prop, []) ++ Map.get(index.assigns, prop, []),
          do: {value, file, sscopes}

    case sources do
      [] ->
        {[], [{file, 0, "property #{prop}: no entry or assignment in this file"}]}

      sources ->
        sources
        |> Enum.map(fn {value, sfile, sscopes} ->
          resolve(value, {sfile, sscopes}, index, seen)
        end)
        |> merge()
    end
  end

  defp identifier(name, line, {file, scopes} = ctx, index, seen) do
    case param(name, scopes) do
      {:props, _fun} ->
        property(name, ctx, index, seen)

      {:index, fun, i, outer} ->
        wrapper_args(fun, i, file, outer, index, seen, line)

      nil ->
        case bindings(name, file, scopes, index) do
          [] ->
            {[], [{file, line, "#{name}: not a literal, const, parameter or property"}]}

          found ->
            found
            |> Enum.map(fn {expr, bfile, bscopes} ->
              bound(expr, {bfile, bscopes}, index, seen)
            end)
            |> merge()
        end
    end
  end

  defp bound({_, list, _} = of, ctx, index, seen) when elem(of, 0) in [:of_index, :of_prop] do
    case elements(list, ctx, index) do
      {[], _} -> runtime_list(ctx, line_of(list))
      found -> of_items(of, found, index, seen)
    end
  end

  defp bound({:of_each, list}, ctx, index, seen) do
    case elements(list, ctx, index) do
      {[], _} -> runtime_list(ctx, line_of(list))
      {items, lctx} -> union(items, lctx, index, seen)
    end
  end

  defp bound(expr, ctx, index, seen), do: resolve(expr, ctx, index, seen)

  defp of_items({:of_index, _list, i}, {items, lctx}, index, seen),
    do:
      union(
        for([{:group, "[", row, _}] <- items, el = Enum.at(split(row, ","), i), do: el),
        lctx,
        index,
        seen
      )

  defp of_items({:of_prop, _list, name}, {items, lctx}, index, seen),
    do:
      union(
        for([{:group, "{", obj, _}] <- items, {^name, value} <- entries(obj), do: value),
        lctx,
        index,
        seen
      )

  defp elements([{:group, "[", items, _}], ctx, _index), do: {split(items, ","), ctx}

  defp elements([{:id, name, _}], {file, scopes} = ctx, index) do
    case binding(name, file, scopes, index) do
      {list, bfile, bscopes} when is_list(list) -> elements(list, {bfile, bscopes}, index)
      _ -> {[], ctx}
    end
  end

  defp elements(_list, ctx, _index), do: {[], ctx}

  defp runtime_list({file, _}, line), do: {[], [{file, line, "a list built at run time"}]}

  defp param(name, scopes) do
    scopes
    |> Enum.with_index()
    |> Enum.find_value(fn {fun, depth} ->
      outer = Enum.drop(scopes, depth + 1)

      Enum.find_value(Enum.with_index(fun.params), fn
        {{:name, ^name}, i} -> {:index, fun, i, outer}
        {{:props, props}, _} -> if name in props, do: {:props, fun}
        _ -> nil
      end)
    end)
  end

  # A wrapper's parameter: the same argument at every call of the wrapper.
  defp wrapper_args(%{name: nil}, _i, file, _outer, _index, _seen, line),
    do: {[], [{file, line, "a parameter of an anonymous function"}]}

  defp wrapper_args(fun, i, file, outer, index, seen, line),
    do: memo({:wrapper, fun.ref, i}, fn -> callers(fun, i, file, outer, index, seen, line) end)

  defp callers(fun, i, file, _outer, index, seen, line) do
    callers =
      for {cfile, findex} <- index.files,
          cfile == file or MapSet.member?(findex.imports, fun.name),
          {name, args, cscopes} <- findex.calls,
          name == fun.name,
          arg = Enum.at(split(args, ","), i),
          do: {arg, {cfile, cscopes}}

    case callers do
      [] ->
        {[], [{file, line, "#{fun.name}: a wrapper nobody calls"}]}

      callers ->
        callers |> Enum.map(fn {arg, cctx} -> resolve(arg, cctx, index, seen) end) |> merge()
    end
  end

  defp returns(name, line, {file, _scopes}, index, seen) do
    case Map.get(index.files[file].fns, name) do
      nil ->
        {[], [{file, line, "#{name}(): not a function of this file"}]}

      {fun, fscopes} ->
        exprs = if fun.kind == :expr, do: [fun.body], else: return_exprs(fun.body)
        exprs |> Enum.map(&resolve(&1, {file, [fun | fscopes]}, index, seen)) |> merge()
    end
  end

  defp return_exprs(tokens) do
    tokens
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:id, "return", _}, i} -> [tokens |> Enum.drop(i + 1) |> statement() |> elem(0)]
      {{:group, _, children, _}, _} -> return_exprs(children)
      _ -> []
    end)
  end

  defp bindings(name, file, scopes, index) do
    refs = scopes |> Enum.map(& &1.ref) |> Enum.reverse()

    local =
      for {expr, bscopes} <- Map.get(index.files[file].consts, name, []),
          List.starts_with?(refs, bscopes |> Enum.map(& &1.ref) |> Enum.reverse()),
          do: {expr, file, bscopes}

    case Enum.sort_by(local, fn {_e, _f, bscopes} -> -length(bscopes) end) do
      [] -> imported(name, file, index)
      found -> found
    end
  end

  defp imported(name, file, index) do
    if MapSet.member?(index.files[file].imports, name) do
      for mod <- index.files[file].modules,
          %{consts: consts} <- [index.files[mod]],
          {expr, []} <- Map.get(consts, name, []),
          do: {expr, mod, []}
    else
      []
    end
  end

  defp binding(name, file, scopes, index),
    do: name |> bindings(file, scopes, index) |> List.first()

  # Each property and wrapper argument is followed once per scan; a cycle reads as no key.
  defp memo(key, compute) do
    case Process.get(__MODULE__) do
      %{^key => result} ->
        result

      memos ->
        Process.put(__MODULE__, Map.put(memos, key, {[], []}))
        result = compute.()
        Process.put(__MODULE__, Map.put(Process.get(__MODULE__), key, result))
        result
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp union(parts, ctx, index, seen),
    do: parts |> Enum.map(&resolve(&1, ctx, index, seen)) |> merge()

  defp merge(results),
    do:
      {results |> Enum.flat_map(&elem(&1, 0)) |> Enum.uniq(),
       results |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()}

  defp strip([{:group, "(", inner, _}]), do: strip(inner)
  defp strip(expr), do: expr

  defp ternary(expr) do
    case Enum.find_index(expr, &match?({:p, "?", _}, &1)) do
      nil ->
        nil

      q ->
        rest = Enum.drop(expr, q + 1)
        colon = matching_colon(rest, 0, 0)
        [Enum.slice(rest, 0, colon), Enum.drop(rest, colon + 1)]
    end
  end

  defp matching_colon([{:p, ":", _} | _], 0, i), do: i
  defp matching_colon([{:p, ":", _} | rest], d, i), do: matching_colon(rest, d - 1, i + 1)
  defp matching_colon([{:p, "?", _} | rest], d, i), do: matching_colon(rest, d + 1, i + 1)
  defp matching_colon([_ | rest], d, i), do: matching_colon(rest, d, i + 1)

  defp split(tokens, op), do: split_any(tokens, [op])

  defp split_any(tokens, ops) do
    tokens
    |> Enum.chunk_while(
      [],
      fn
        {:p, op, _} = tok, acc ->
          if op in ops, do: {:cont, Enum.reverse(acc), []}, else: {:cont, [tok | acc]}

        tok, acc ->
          {:cont, [tok | acc]}
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
  end

  # One statement's tokens: up to `;`, or a line break where the next line starts anew.
  defp statement(tokens), do: statement(tokens, [])

  defp statement([], acc), do: {Enum.reverse(acc), []}
  defp statement([{:p, ";", _} | rest], acc), do: {Enum.reverse(acc), rest}

  defp statement([next | rest] = tokens, [prev | _] = acc) do
    if line_of([next]) > line_of([prev]) and not continues?(prev, next),
      do: {Enum.reverse(acc), tokens},
      else: statement(rest, [next | acc])
  end

  defp statement([next | rest], []), do: statement(rest, [next])

  defp continues?({:p, op, _}, _next) when op not in [")", "]", "}"], do: true

  defp continues?(_prev, {:p, op, _})
       when op in [".", "?.", "?", ":", "||", "??", "&&", "+", "-", "*", "/", "=>", ","], do: true

  defp continues?(_prev, {:group, open, _, _}) when open in ["(", "["], do: false
  defp continues?(_prev, _next), do: false

  defp line_of([{_, _, line} | _]) when is_integer(line), do: line
  defp line_of([{:group, _, _, line} | _]), do: line
  defp line_of(_), do: 0
end
