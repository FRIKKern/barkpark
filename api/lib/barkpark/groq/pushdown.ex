defmodule Barkpark.Groq.Pushdown do
  @moduledoc """
  Reads the constraints a document source can apply before evaluation from the
  filter of a `*[...]`.

  Only the top-level `&&` conjuncts count, and only these shapes, with a value
  on one side that does not depend on the filtered document:

    * `_type == "t"`, `_type in ["a", "b"]` -> `types`
    * `_id == "x"`, `_id in [...]` -> `ids`
    * `a.b == "x"` on a content path -> `eq` (JSON containment)
    * `"x" in a[].b` on a content path -> `eq`, with `:each` marking the
      array in the path, so the probe is `{"a": [{"b": "x"}]}`
    * `title == "x"` -> `eq` with the path `["title"]`, which the document
      source matches against the `documents.title` column
    * `a.b in ["x", "y"]` with scalar members -> `any`, a list of probes of
      which a document must match at least one
    * `references("x", ...)` -> `any` with the probe `{:refs, ids}`
    * an `||` -> `any` with one probe per disjunct. A disjunct is a single
      condition or an `&&` of conditions; it gives the probe of its most
      selective condition: `_id` (`{:ids, ids}`), then `references()`, then a
      content equality. A disjunct with a condition that reads only `^` and
      is not true for this parent can never match, so it adds no probe; an
      `||` whose disjuncts all drop matches nothing.

  A probe in `any` is a JSON containment map, `{:refs, ids}` or `{:ids, ids}`.

  The value side is a literal, a parameter, arithmetic over them, or an
  expression over `^` (such as `^._id`, `^.author._ref` or
  `^.variants[]._ref`). The caller passes a resolver that evaluates the `^`
  forms in the scope the filter runs in, so a subquery inside a projection
  gets its own constraints per parent document.

  A conjunct that reads the filtered document on both sides, dereferences, or
  calls another function stays in memory. The source may return more
  documents than match; the evaluator always applies the whole filter
  afterwards.
  """

  alias Barkpark.Groq.Parser

  @system_paths ~w(_rev _createdAt _updatedAt _originalId title)

  # Functions with no hidden input: a call over `^` values and literals has
  # one value per parent document. `references()` reads the filtered
  # document and is not one of them.
  @pure_functions ~w(defined count length lower upper coalesce string)

  @type probe :: map() | {:refs, [String.t()]} | {:ids, [String.t()]}
  @type t :: %{
          types: [String.t()] | nil,
          ids: [String.t()] | nil,
          eq: list(),
          any: [[probe()]]
        }

  @spec empty() :: t()
  def empty, do: %{types: nil, ids: nil, eq: [], any: []}

  @doc """
  Constraints for the filter `expr`. `resolve` evaluates an expression that
  reads only `^` scopes and returns its value.
  """
  @spec constraints(tuple(), (tuple() -> term()) | nil) :: t()
  def constraints(expr, resolve \\ nil) do
    expr
    |> conjuncts()
    |> Enum.reduce(empty(), &apply_conjunct(&1, &2, resolve))
  end

  @doc """
  Constraints that match exactly the documents `expr` keeps, or `:error`.

  A source may then count in SQL without loading anything. Only these
  conjuncts qualify: `_type ==` and `in` with strings, `_id ==` and `in`, and
  a content path `==` a string, number or boolean whose first segment does
  not start with `_` and whose segments are not array indexes. `title`, `null`, `||`, functions and
  everything else make the filter inexact. The source still checks that
  rendering hides no field before it trusts the count.
  """
  @spec exact(tuple(), (tuple() -> term()) | nil) :: {:ok, t()} | :error
  def exact(expr, resolve \\ nil) do
    expr
    |> conjuncts()
    |> Enum.reduce_while({:ok, empty()}, fn node, {:ok, acc} ->
      case exact_conjunct(node, acc, resolve) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp exact_conjunct({:op, op, _l, _r} = node, acc, resolve) when op in ["==", "in"] do
    case orient(node, resolve) do
      {:ok, ["_type"], v} when op == "==" and is_binary(v) ->
        {:ok, add(acc, op, ["_type"], v)}

      {:ok, ["_type"], vs} when op == "in" and is_list(vs) ->
        if Enum.all?(vs, &is_binary/1), do: {:ok, add(acc, op, ["_type"], vs)}, else: :error

      {:ok, ["_id"], v} when op == "==" ->
        {:ok, add(acc, op, ["_id"], v)}

      {:ok, ["_id"], vs} when op == "in" and is_list(vs) ->
        if Enum.all?(vs, &is_binary/1), do: {:ok, add(acc, op, ["_id"], vs)}, else: :error

      {:ok, path, v} when op == "==" ->
        if exact_path?(path) and scalar?(v),
          do: {:ok, %{acc | eq: [{path, v} | acc.eq]}},
          else: :error

      _ ->
        :error
    end
  end

  defp exact_conjunct(_node, _acc, _resolve), do: :error

  # The renderer sets or drops the top-level `_` keys and `title`; an
  # all-digit segment would index an array in SQL but not in GROQ.
  defp exact_path?(["title" | _]), do: false

  defp exact_path?([first | _] = path) do
    not String.starts_with?(first, "_") and
      Enum.all?(path, &(is_binary(&1) and not (&1 =~ ~r/^-?\d+$/)))
  end

  @doc "True when `expr` reads nothing but literals and `^` scopes."
  @spec outer_only?(tuple()) :: boolean()
  def outer_only?({:value, _}), do: true
  def outer_only?({:parent, n}) when n >= 1, do: true
  def outer_only?({:attr, base, _}) when is_tuple(base), do: outer_only?(base)
  def outer_only?({:elem, base, _}), do: outer_only?(base)
  def outer_only?({:group, base}), do: outer_only?(base)

  def outer_only?({:op, op, l, r}) when op in ["+", "-", "*", "/", "%", "**"],
    do: outer_only?(l) and outer_only?(r)

  def outer_only?({:op, op, l, r}) when op in ["==", "!=", "<", "<=", ">", ">="],
    do: outer_only?(l) and outer_only?(r)

  def outer_only?({:and, l, r}), do: outer_only?(l) and outer_only?(r)
  def outer_only?({:or, l, r}), do: outer_only?(l) and outer_only?(r)
  def outer_only?({:not, base}), do: outer_only?(base)
  def outer_only?({:array_coerce, base}), do: outer_only?(base)

  # `^.variants[]._ref`: a map over a `^` array that reads only its element.
  def outer_only?({:map, base, mapper}), do: outer_only?(base) and this_path(mapper) != :error

  def outer_only?({:func, "global", name, args}) when name in @pure_functions,
    do: Enum.all?(args, &outer_only?/1)

  def outer_only?({:array, elems}), do: Enum.all?(elems, fn {e, _splat?} -> outer_only?(e) end)
  def outer_only?(_), do: false

  defp conjuncts({:and, l, r}), do: conjuncts(l) ++ conjuncts(r)
  defp conjuncts({:group, inner}), do: conjuncts(inner)
  defp conjuncts(other), do: [other]

  defp apply_conjunct({:op, op, _l, _r} = node, acc, resolve) when op in ["==", "in"] do
    case orient(node, resolve) do
      {:ok, path, value} -> add(acc, op, path, value)
      :error -> add_probes(acc, node, resolve)
    end
  end

  defp apply_conjunct(node, acc, resolve), do: add_probes(acc, node, resolve)

  defp add_probes(acc, node, resolve) do
    case probes(node, resolve) do
      {:ok, probes} -> %{acc | any: [probes | acc.any]}
      :never -> %{acc | any: [[] | acc.any]}
      :error -> acc
    end
  end

  # The probes a document must match one of for `node` to be true:
  # `{:ok, probes}`, `:never` when `node` cannot be true for this parent, or
  # `:error` when SQL cannot narrow it.
  defp probes({:group, inner}, resolve), do: probes(inner, resolve)

  defp probes({:or, l, r}, resolve) do
    case {probes(l, resolve), probes(r, resolve)} do
      {:error, _} -> :error
      {_, :error} -> :error
      {:never, other} -> other
      {other, :never} -> other
      {{:ok, a}, {:ok, b}} -> {:ok, a ++ b}
    end
  end

  defp probes({:and, _l, _r} = node, resolve) do
    found = node |> conjuncts() |> Enum.map(&probes(&1, resolve))

    if :never in found do
      :never
    else
      found
      |> Enum.flat_map(fn
        {:ok, probes} -> [probes]
        :error -> []
      end)
      |> Enum.min_by(&selectivity/1, &<=/2, fn -> :error end)
      |> case do
        :error -> :error
        probes -> {:ok, probes}
      end
    end
  end

  defp probes({:func, "global", "references", args}, resolve) do
    with {:ok, values} <- values(args, resolve) do
      case Enum.filter(List.flatten(values), &is_binary/1) do
        [] -> :never
        ids -> {:ok, [{:refs, Enum.uniq(ids)}]}
      end
    end
  end

  defp probes({:op, "in", l, r} = node, resolve) do
    with :error <- member_probe(l, r, resolve),
         :error <- id_probe(node, resolve) do
      field_probe(node, resolve)
    end
  end

  defp probes({:op, "==", _l, _r} = node, resolve) do
    with :error <- id_probe(node, resolve), do: field_probe(node, resolve)
  end

  defp probes(node, resolve), do: outer_probe(node, resolve)

  # `"x" in a[].b`: true only when some element of `a` has `b == "x"`.
  defp member_probe(l, {:map, {:array_coerce, base}, mapper}, resolve) do
    with {:ok, [first | _] = path} <- attr_path(base),
         false <- system_path?(first),
         {:ok, rest} <- this_path(mapper),
         {:ok, v} <- value(l, resolve) do
      cond do
        is_list(v) or is_map(v) or is_nil(v) -> :error
        scalar?(v) -> {:ok, [nest(path ++ [:each | rest], v)]}
        true -> :error
      end
    else
      _ -> :error
    end
  end

  defp member_probe(_l, _r, _resolve), do: :error

  defp id_probe({:op, "in", l, r}, resolve) do
    with {:ok, ["_id"]} <- attr_path(l),
         {:ok, v} <- value(r, resolve) do
      case v do
        list when is_list(list) ->
          case Enum.filter(list, &is_binary/1) do
            [] -> :never
            ids -> {:ok, [{:ids, Enum.uniq(ids)}]}
          end

        # `_id in path(...)` is a glob match, and `in` anything else is null.
        {:path, _, _} ->
          :error

        _ ->
          :never
      end
    else
      _ -> :error
    end
  end

  defp id_probe({:op, "==", _l, _r} = node, resolve) do
    case orient(node, resolve) do
      {:ok, ["_id"], id} when is_binary(id) -> {:ok, [{:ids, [id]}]}
      {:ok, ["_id"], _not_a_string} -> :never
      _ -> :error
    end
  end

  defp field_probe({:op, op, _l, _r} = node, resolve) do
    with {:ok, [first | _] = path, value} <- orient(node, resolve),
         false <- system_path?(first),
         values = if(op == "in", do: value, else: [value]),
         true <- is_list(values) and values != [] and Enum.all?(values, &scalar?/1) do
      {:ok, Enum.map(values, &nest(path, &1))}
    else
      _ -> :error
    end
  end

  # A condition that reads only `^` and literals has one value per parent.
  defp outer_probe(_node, nil), do: :error

  defp outer_probe(node, resolve) do
    if outer_only?(node) and resolve.(node) !== true, do: :never, else: :error
  end

  defp values(args, resolve) do
    Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, acc} ->
      case value(arg, resolve) do
        {:ok, v} -> {:cont, {:ok, acc ++ [v]}}
        :error -> {:halt, :error}
      end
    end)
  end

  # Fewer, narrower probes first: an id is a primary-key lookup, a reference
  # an index lookup, a containment probe the broadest.
  defp selectivity(probes) do
    rank =
      probes
      |> Enum.map(fn
        {:ids, _} -> 0
        {:refs, _} -> 1
        _map -> 2
      end)
      |> Enum.max(fn -> 0 end)

    {rank, length(probes)}
  end

  defp scalar?(v), do: is_binary(v) or is_number(v) or is_boolean(v)

  @doc "The JSON containment probe for `path == value`; `:each` in `path` is an array."
  @spec nest([String.t()], term()) :: map()
  def nest(path, value) do
    path
    |> Enum.reverse()
    |> Enum.reduce(value, fn
      :each, acc -> [acc]
      key, acc -> %{key => acc}
    end)
  end

  defp orient({:op, "==", l, r}, resolve) do
    with {:l, {:ok, path}} <- {:l, attr_path(l)},
         {:ok, v} <- value(r, resolve) do
      {:ok, path, v}
    else
      _ ->
        with {:ok, path} <- attr_path(r), {:ok, v} <- value(l, resolve) do
          {:ok, path, v}
        else
          _ -> :error
        end
    end
  end

  defp orient({:op, "in", l, r}, resolve) do
    with {:ok, path} <- attr_path(l), {:ok, v} when is_list(v) <- value(r, resolve) do
      {:ok, path, v}
    else
      _ -> :error
    end
  end

  defp add(acc, "==", ["_type"], v) when is_binary(v), do: narrow(acc, :types, [v])
  defp add(acc, "in", ["_type"], vs), do: narrow(acc, :types, Enum.filter(vs, &is_binary/1))
  defp add(acc, "==", ["_id"], v) when is_binary(v), do: narrow(acc, :ids, [v])
  # `_type` and `_id` are always strings, so equality with anything else
  # matches nothing (a `^.ref._ref` that is null, for one).
  defp add(acc, "==", ["_type"], _v), do: narrow(acc, :types, [])
  defp add(acc, "==", ["_id"], _v), do: narrow(acc, :ids, [])
  defp add(acc, "in", ["_id"], vs), do: narrow(acc, :ids, Enum.filter(vs, &is_binary/1))

  # `title` is stored in a column, not in content; the source matches it there.
  defp add(acc, "==", ["title"], v) when is_binary(v), do: %{acc | eq: [{["title"], v} | acc.eq]}

  defp add(acc, "==", [first | _] = path, v) when is_binary(v) or is_number(v) or is_boolean(v) do
    if system_path?(first), do: acc, else: %{acc | eq: [{path, v} | acc.eq]}
  end

  defp add(acc, "in", [first | _] = path, vs) do
    scalars? = vs != [] and Enum.all?(vs, &(is_binary(&1) or is_number(&1) or is_boolean(&1)))

    if scalars? and not system_path?(first),
      do: %{acc | any: [Enum.map(vs, &nest(path, &1)) | acc.any]},
      else: acc
  end

  defp add(acc, _op, _path, _v), do: acc

  defp system_path?(first), do: first in @system_paths or first in ["_type", "_id"]

  defp narrow(acc, key, values) do
    case Map.fetch!(acc, key) do
      nil -> Map.put(acc, key, Enum.uniq(values))
      existing -> Map.put(acc, key, Enum.filter(existing, &(&1 in values)))
    end
  end

  # `a.b.c` evaluated against the filtered document itself.
  defp attr_path({:attr, nil, name}), do: {:ok, [name]}

  defp attr_path({:attr, base, name}) do
    case attr_path(base) do
      {:ok, path} -> {:ok, path ++ [name]}
      :error -> :error
    end
  end

  defp attr_path({:group, inner}), do: attr_path(inner)
  defp attr_path(_), do: :error

  # `b.c` read from each element inside `a[].b.c`.
  defp this_path({:attr, {:this}, name}), do: {:ok, [name]}

  defp this_path({:attr, base, name}) do
    case this_path(base) do
      {:ok, path} -> {:ok, path ++ [name]}
      :error -> :error
    end
  end

  defp this_path(_), do: :error

  defp value({:array, elems} = node, resolve) do
    literal =
      Enum.reduce_while(elems, {:ok, []}, fn
        {expr, false}, {:ok, acc} ->
          case Parser.const_eval(expr) do
            {:ok, v} -> {:cont, {:ok, [v | acc]}}
            :error -> {:halt, :error}
          end

        _, _ ->
          {:halt, :error}
      end)

    case literal do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> resolved(node, resolve)
    end
  end

  defp value(expr, resolve) do
    case Parser.const_eval(expr) do
      {:ok, v} -> {:ok, v}
      :error -> resolved(expr, resolve)
    end
  end

  defp resolved(_expr, nil), do: :error

  defp resolved(expr, resolve) do
    if outer_only?(expr), do: {:ok, resolve.(expr)}, else: :error
  end
end
