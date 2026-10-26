defmodule Barkpark.Groq.SourceMap do
  @moduledoc """
  Sanity's `resultSourceMap` for a GROQ result (task-640e8371b8e468ce, tier T1
  of /papers/groq-result-source-map-note): for each part of the result that
  came from a stored document, the document and the path inside it. With
  stega on, `@sanity/client` hides an edit link in each string it can trace
  this way.

  Built only when a request asks (`resultSourceMap=true` or
  `withKeyArraySelector`), after the normal evaluation has finished: one more
  pass over the query tree, on the warm document cache, that asks
  `Barkpark.Groq.Evaluator` for every value it needs and tracks where each one
  came from. A query that does not ask runs exactly as before.

  ## Provenance

  The pass returns, for a node, one of

    * `{:src, {id, type}, path}`: the value is the stored value at `path` in
      that document (`[]` for the whole document);
    * `{:obj, %{key => provenance}}`: an object the query built, per key;
    * `{:arr, [provenance]}`: an array the query built, per element;
    * `nil`: computed, a literal, or a node T1 does not cover.

  Covered (T1): `*[...]` and its slices, `[n]` and `order()`, field access,
  `@`, `^`, filters and slices of arrays, projections, `...` spreads, objects,
  arrays, `->` and maps over arrays. T2: `a[]` over a list, `order()` of any
  list, and the functions that pass a stored value through, as Sanity maps
  them: `upper()`, `lower()`, `coalesce()` and `select()` (the chosen value),
  `pt::text()` (the body it reads), `array::unique()` (each first
  occurrence). Other functions and operators answer no mapping, as Sanity does
  for a computed value.

  ## Output

  `%{"documents" => [%{"_id", "_type"}], "paths" => [...], "mappings" =>
  %{result_path => %{"source" => %{"document", "path", "type" =>
  "documentValue"}, "type" => "value"}}}`, in Sanity's single-quoted path
  syntax (`$['title']`, `$[0]['author']['name']`). A part of the result that
  is wholly one stored value maps once, at its top: `*[_id == $id][0]` maps
  `$` to the document's `$`. Array items in a source path are `[i]`, or
  `[?(@._key=='k')]` for a keyed item with `withKeyArraySelector`, `i` being
  the item's position in the stored array. A document is named by its
  `_originalId` when the perspective overlaid a draft, else its `_id`.
  """

  alias Barkpark.Groq.Evaluator

  @root %{value: nil, prov: nil, parent: nil, hidden: false}

  @doc """
  The source map of `result` (the evaluated, JSON-ready value of `tree`), or
  nil when nothing in it maps. `mode` is `:plain` or `:keyed`
  (`withKeyArraySelector`). `ctx` is the `Barkpark.Groq.Evaluator` context
  the result was evaluated with.
  """
  @spec build(tuple(), term(), Evaluator.t(), :plain | :keyed) :: map() | nil
  def build(tree, result, ctx, mode) do
    prov = prov(tree, @root, ctx)

    {mappings, docs, paths} = emit(result, prov, "$", mode, {[], %{}, %{}})

    if mappings == [] do
      %{"documents" => [], "paths" => [], "mappings" => %{}}
    else
      doc_list = docs |> Map.keys() |> Enum.sort()
      doc_index = doc_list |> Enum.with_index() |> Map.new()
      path_list = paths |> Map.keys() |> Enum.sort()
      path_index = path_list |> Enum.with_index() |> Map.new()

      %{
        "documents" => Enum.map(doc_list, fn {id, type} -> %{"_id" => id, "_type" => type} end),
        "paths" => path_list,
        "mappings" =>
          Map.new(mappings, fn {rpath, doc, spath} ->
            {rpath,
             %{
               "source" => %{
                 "document" => Map.fetch!(doc_index, doc),
                 "path" => Map.fetch!(path_index, spath),
                 "type" => "documentValue"
               },
               "type" => "value"
             }}
          end)
      }
    end
  end

  # ── Provenance ───────────────────────────────────────────────────────────

  defp prov({:this}, s, _c), do: s.prov
  defp prov({:group, base}, s, c), do: prov(base, s, c)
  defp prov({:memo, node}, _s, c), do: prov(node, @root, c)
  defp prov({:parent, n}, s, _c), do: parent_prov(s, n)
  defp prov({:value, _}, _s, _c), do: nil

  defp prov({:everything}, s, c), do: docs_prov(ev({:everything}, s, c))
  defp prov({:filter, {:everything}, _} = node, s, c), do: docs_prov(ev(node, s, c))

  defp prov({:filter, base, expr}, s, c) do
    case ev(base, s, c) do
      list when is_list(list) ->
        lp = prov(base, s, c)

        kept =
          for {item, i} <- Enum.with_index(list),
              Evaluator.eval(expr, nested(s, item, nil), c) === true,
              do: item_prov(lp, list, i)

        {:arr, kept}

      _ ->
        nil
    end
  end

  # `_ref`, `_type`, `_weak` and `current` read off a bare string (a declared
  # reference or slug stored as the id or the slug) are computed by the read
  # compat, not stored: no mapping, as Sanity maps none for `_weak` it computes.
  defp prov({:attr, base, name}, s, c) when name in ["_ref", "_type", "_weak", "current"] do
    case if(base, do: ev(base, s, c), else: s.value) do
      v when is_binary(v) -> nil
      _ -> child(if(base, do: prov(base, s, c), else: s.prov), name)
    end
  end

  defp prov({:attr, nil, name}, s, _c), do: child(s.prov, name)
  defp prov({:attr, base, name}, s, c), do: child(prov(base, s, c), name)

  defp prov({:elem, base, index} = node, s, c) do
    cond do
      source_list?(base) ->
        root(ev(node, s, c))

      match?({:map, _, _}, unmemo(base)) and source_list?(elem(unmemo(base), 1)) ->
        {:map, list_base, mapped} = unmemo(base)

        case ev({:elem, list_base, index}, s, c) do
          %{} = doc -> prov(mapped, hidden(s, doc, root(doc)), c)
          _ -> nil
        end

      true ->
        with list when is_list(list) <- ev(base, s, c),
             i when is_integer(i) <- int(index) do
          i = if i < 0, do: i + length(list), else: i
          if i >= 0 and i < length(list), do: item_prov(prov(base, s, c), list, i)
        else
          _ -> nil
        end
    end
  end

  defp prov({:slice, base, left, right, inclusive?} = node, s, c) do
    cond do
      source_list?(base) ->
        docs_prov(ev(node, s, c))

      match?({:map, _, _}, unmemo(base)) and source_list?(elem(unmemo(base), 1)) ->
        {:map, list_base, mapped} = unmemo(base)

        case ev({:slice, list_base, left, right, inclusive?}, s, c) do
          docs when is_list(docs) ->
            {:arr, Enum.map(docs, &prov(mapped, hidden(s, &1, root(&1)), c))}

          _ ->
            nil
        end

      true ->
        case ev(base, s, c) do
          list when is_list(list) ->
            lp = prov(base, s, c)

            {:arr,
             Enum.map(
               slice_range(length(list), left, right, inclusive?),
               &item_prov(lp, list, &1)
             )}

          _ ->
            nil
        end
    end
  end

  defp prov({:pipe, base, "order", _args} = node, s, c) do
    if source_list?(node), do: docs_prov(ev(node, s, c)), else: reordered(node, base, s, c)
  end

  defp prov({:projection, base, obj}, s, c) do
    case ev(base, s, c) do
      %{} = value -> prov(obj, nested(s, value, prov(base, s, c)), c)
      _ -> nil
    end
  end

  defp prov({:deref, _} = node, s, c), do: root(ev(node, s, c))

  defp prov({:map, base, expr}, s, c) do
    case ev(base, s, c) do
      list when is_list(list) ->
        lp = prov(base, s, c)

        {:arr,
         list
         |> Enum.with_index()
         |> Enum.map(fn {item, i} -> prov(expr, hidden(s, item, item_prov(lp, list, i)), c) end)}

      _ ->
        nil
    end
  end

  defp prov({:array_coerce, base}, s, c), do: prov(base, s, c)

  defp prov({:object, attrs}, s, c) do
    {:obj,
     Enum.reduce(attrs, %{}, fn
       {:attr_value, name, expr}, acc ->
         Map.put(acc, name, prov(expr, s, c))

       {:splat, expr}, acc ->
         splat(acc, expr, s, c)

       {:cond_splat, cond_expr, expr}, acc ->
         if Evaluator.eval(cond_expr, s, c) === true, do: splat(acc, expr, s, c), else: acc
     end)}
  end

  defp prov({:array, elems}, s, c) do
    {:arr,
     Enum.flat_map(elems, fn
       {expr, true} ->
         case ev(expr, s, c) do
           list when is_list(list) ->
             lp = prov(expr, s, c)
             Enum.map(0..(length(list) - 1)//1, &item_prov(lp, list, &1))

           _ ->
             []
         end

       {expr, false} ->
         [prov(expr, s, c)]
     end)}
  end

  # `a[]` over a list (`*[...].tags[]`): each item's own items, in order.
  defp prov({:flat_map, base, expr}, s, c) do
    case ev(base, s, c) do
      list when is_list(list) ->
        lp = prov(base, s, c)

        {:arr,
         list
         |> Enum.with_index()
         |> Enum.flat_map(fn {item, i} ->
           inner_scope = hidden(s, item, item_prov(lp, list, i))

           case Evaluator.eval(expr, inner_scope, c) do
             inner when is_list(inner) ->
               ip = prov(expr, inner_scope, c)
               Enum.map(0..(length(inner) - 1)//1, &item_prov(ip, inner, &1))

             _ ->
               [prov(expr, inner_scope, c)]
           end
         end)}

      _ ->
        nil
    end
  end

  # ── T2: functions that pass a stored value through, as Sanity maps them ──

  defp prov({:func, "global", f, [arg]}, s, c) when f in ["upper", "lower"] do
    if is_binary(ev(arg, s, c)), do: prov(arg, s, c)
  end

  # The first argument that is not null is the value.
  defp prov({:func, "global", "coalesce", args}, s, c) do
    Enum.find_value(args, fn arg -> if ev(arg, s, c) != nil, do: {:hit, prov(arg, s, c)} end)
    |> case do
      {:hit, p} -> p
      nil -> nil
    end
  end

  defp prov({:select, branches, default}, s, c) do
    case Enum.find(branches, fn {cond_expr, _} -> Evaluator.eval(cond_expr, s, c) === true end) do
      {_, value} -> prov(value, s, c)
      nil -> if default, do: prov(default, s, c)
    end
  end

  # pt::text(body) maps to the body it reads.
  defp prov({:func, "pt", "text", [arg]}, s, c), do: prov(arg, s, c)

  # array::unique keeps each value's first occurrence.
  defp prov({:func, "array", "unique", [arg]}, s, c) do
    case ev(arg, s, c) do
      list when is_list(list) ->
        lp = prov(arg, s, c)

        {_, provs} =
          list
          |> Enum.with_index()
          |> Enum.reduce({MapSet.new(), []}, fn {v, i}, {seen, acc} ->
            if MapSet.member?(seen, v),
              do: {seen, acc},
              else: {MapSet.put(seen, v), [item_prov(lp, list, i) | acc]}
          end)

        {:arr, Enum.reverse(provs)}

      _ ->
        nil
    end
  end

  # Other functions, operators, score() and the rest: computed, no mapping.
  defp prov(_node, _s, _c), do: nil

  # `| order()` of a list that is not `*[...]`: each item of the ordered result
  # takes the provenance of the first unused equal item of the input.
  defp reordered(node, base, s, c) do
    with out when is_list(out) <- ev(node, s, c),
         input when is_list(input) <- ev(base, s, c) do
      lp = prov(base, s, c)
      indexed = Enum.with_index(input)

      {provs, _used} =
        Enum.map_reduce(out, MapSet.new(), fn v, used ->
          case Enum.find(indexed, fn {x, i} -> x == v and not MapSet.member?(used, i) end) do
            {_, i} -> {item_prov(lp, input, i), MapSet.put(used, i)}
            nil -> {nil, used}
          end
        end)

      {:arr, provs}
    else
      _ -> nil
    end
  end

  defp splat(acc, expr, s, c) do
    case ev(expr, s, c) do
      %{} = obj ->
        p = prov(expr, s, c)
        Enum.reduce(Map.keys(obj), acc, &Map.put(&2, &1, child(p, &1)))

      _ ->
        acc
    end
  end

  # The values come from the evaluator itself, so the map can only describe the
  # result the query returned.
  defp ev(node, s, c), do: Evaluator.eval(node, s, c)

  # A `*[...]`, optionally ordered: its items are whole stored documents.
  defp source_list?(node) do
    case unmemo(node) do
      {:filter, {:everything}, _} -> true
      {:everything} -> true
      {:group, inner} -> source_list?(inner)
      {:pipe, base, "order", _} -> source_list?(base)
      _ -> false
    end
  end

  defp unmemo({:memo, inner}), do: unmemo(inner)
  defp unmemo(node), do: node

  defp docs_prov(docs) when is_list(docs), do: {:arr, Enum.map(docs, &root/1)}
  defp docs_prov(_), do: nil

  defp root(%{"_id" => id, "_type" => type} = doc) when is_binary(id) and is_binary(type),
    do: {:src, {Map.get(doc, "_originalId") || id, type}, []}

  defp root(_), do: nil

  defp child({:src, doc, path}, key), do: {:src, doc, path ++ [key]}
  defp child({:obj, map}, key), do: Map.get(map, key)
  defp child(_, _key), do: nil

  # The provenance of item `i` of `list`, whose own provenance is `lp`. A
  # stored array's item is addressed by its stored position (and `_key`).
  defp item_prov({:src, doc, path}, list, i) do
    key =
      case Enum.at(list, i) do
        %{"_key" => k} when is_binary(k) and k != "" -> k
        _ -> nil
      end

    {:src, doc, path ++ [{:item, i, key}]}
  end

  defp item_prov({:arr, provs}, _list, i), do: Enum.at(provs, i)
  defp item_prov(_, _list, _i), do: nil

  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n) and trunc(n) == n, do: trunc(n)
  defp int(_), do: nil

  # The same arithmetic as the evaluator's slice/4, as positions.
  defp slice_range(len, left, right, inclusive?) do
    l = if left < 0, do: len + left, else: left
    r = if right < 0, do: len + right, else: right
    r = if inclusive?, do: r + 1, else: r
    l = max(trunc(l), 0)
    r = min(max(trunc(r), 0), len)
    if r > l, do: Enum.to_list(l..(r - 1)), else: []
  end

  # Scopes as the evaluator builds them, plus the provenance of the value.
  defp nested(%{hidden: true, parent: parent}, value, prov),
    do: %{value: value, prov: prov, parent: parent, hidden: false}

  defp nested(scope, value, prov), do: %{value: value, prov: prov, parent: scope, hidden: false}

  defp hidden(scope, value, prov), do: %{nested(scope, value, prov) | hidden: true}

  defp parent_prov(scope, 0), do: Map.get(scope, :prov)
  defp parent_prov(%{parent: nil}, _n), do: nil
  defp parent_prov(%{parent: parent}, n), do: parent_prov(parent, n - 1)

  # ── Emitter ──────────────────────────────────────────────────────────────

  defp emit(nil, _prov, _rpath, _mode, acc), do: acc

  defp emit(_value, {:src, doc, path}, rpath, mode, {mappings, docs, paths}) do
    spath = source_path(path, mode)
    {[{rpath, doc, spath} | mappings], Map.put(docs, doc, true), Map.put(paths, spath, true)}
  end

  defp emit(%{} = value, {:obj, provs}, rpath, mode, acc) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(acc, fn {k, v}, acc ->
      emit(v, Map.get(provs, k), rpath <> key(k), mode, acc)
    end)
  end

  defp emit(list, {:arr, provs}, rpath, mode, acc) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {v, i}, acc ->
      emit(v, Enum.at(provs, i), "#{rpath}[#{i}]", mode, acc)
    end)
  end

  defp emit(_value, _prov, _rpath, _mode, acc), do: acc

  defp source_path(path, mode) do
    Enum.reduce(path, "$", fn
      {:item, _i, k}, acc when mode == :keyed and is_binary(k) ->
        acc <> "[?(@._key==#{quote_key(k)})]"

      {:item, i, _k}, acc ->
        acc <> "[#{i}]"

      k, acc ->
        acc <> key(k)
    end)
  end

  defp key(k), do: "[#{quote_key(k)}]"

  defp quote_key(k) do
    "'" <> (k |> to_string() |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")) <> "'"
  end
end
