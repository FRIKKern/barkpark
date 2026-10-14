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
    * `count(a.b) > 0` and `<`, `<=`, `>`, `>=`, `==` against an integer, on
      a content path -> `checks` as `{:length, path, op, n}`, which the
      source tests with `jsonb_array_length`
    * `defined(a.b)` and `defined(a.b[0])` on a content path -> `checks` as
      `{:defined, path, index}`, with `index` nil for no index
    * `a.b in [...]` with scalar members on a content path -> `checks` as
      `{:in, path, values}`, and `"x" in a.b` -> `{:member, path, "x"}`. The
      source tests both with one jsonpath that the GIN index on `content`
      serves, and that matches exactly what GROQ matches
    * `count(a.b[cond]) > 0`, `>= 1`, `length(a.b[cond]) > 0` and
      `defined(a.b[cond][0])` on a content path, where `cond` is an `&&` of
      `x.y == v` and `x.y in [...]` on element fields (or `@`) with scalar
      values -> `checks` as `{:some, path, [{field_path, values}]}`: some
      element of the array matches every pair. The source tests it with one
      jsonpath, which is exact. When only some of the conjuncts in `cond`
      have that shape, `constraints/2` keeps those as a narrowing check and
      `exact/2` refuses the filter
    * an `||` -> `any` with one probe per disjunct. A disjunct is a single
      condition or an `&&` of conditions; it gives the probe of its most
      selective condition: `_id` (`{:ids, ids}`), then `references()`, then a
      content equality. A disjunct with a condition that reads only `^` and
      is not true for this parent can never match, so it adds no probe; an
      `||` whose disjuncts all drop matches nothing.

  A probe in `any` is a JSON containment map, `{:refs, ids}` or `{:ids, ids}`.

  The value side is a literal, a parameter, arithmetic over them, an
  expression over `^` (such as `^._id`, `^.author._ref` or
  `^.variants[]._ref`), or a closed subquery (`*[...].isbn`, which reads no
  `^`). The caller passes a resolver that evaluates the `^` forms in the scope
  the filter runs in, so a subquery inside a projection gets its own
  constraints per parent document. A closed subquery is evaluated once per
  query (`{:memo, _}`), so its list narrows every read that uses it.

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
  @type check ::
          {:length, [String.t()], String.t(), integer()}
          | {:defined, [String.t()], integer() | nil}
          | {:in, [String.t()], [scalar()]}
          | {:member, [String.t()], scalar()}
          | {:some, [String.t()], [{[String.t()], [scalar()]}]}
  @type scalar :: String.t() | number() | boolean()
  @type order_key :: {:path, [String.t()]} | :_id | :_createdAt | :_updatedAt
  @type t :: %{
          types: [String.t()] | nil,
          ids: [String.t()] | nil,
          eq: list(),
          any: [[probe()]],
          checks: [check()]
        }

  @spec empty() :: t()
  def empty, do: %{types: nil, ids: nil, eq: [], any: [], checks: []}

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
  conjuncts qualify: `_type ==` and `in` with strings, `_id ==` and `in`, a
  content path `==` a string, number or boolean, and the `checks` above. A
  content path's first segment does not start with `_` and its segments are
  not array indexes. `title`, `null`, `||`, other functions and everything
  else make the filter inexact. The source still checks that
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

  defp exact_conjunct(node, acc, resolve) do
    case check(node, resolve) do
      {:ok, check} -> {:ok, %{acc | checks: [check | acc.checks]}}
      :error -> exact_match(node, acc, resolve)
    end
  end

  defp exact_match({:op, op, _l, _r} = node, acc, resolve) when op in ["==", "in"] do
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

  defp exact_match(_node, _acc, _resolve), do: :error

  # `count(path) > n`: GROQ's count() is null for anything but an array, and
  # a comparison with null is not true, so SQL needs only the array's length.
  # `!=` is left out: `null != 0` is true.
  @length_ops %{"<" => ">", "<=" => ">=", ">" => "<", ">=" => "<=", "==" => "=="}

  defp check({:op, op, l, r} = node, resolve) when is_map_key(@length_ops, op) do
    with :error <- some_check(node, :exact), do: length_check(op, l, r, resolve)
  end

  # `defined(a.b[cond][0])`: the filtered array has a first element. `cond`
  # never matches a null element, so that is some element matching.
  defp check({:func, "global", "defined", [{:elem, {:filter, _, _} = filter, 0}]}, _resolve),
    do: some_filter(filter, :exact)

  # `defined(a.b[i])` with a literal index; Postgres `->` counts a negative
  # index from the end, as GROQ does.
  defp check({:func, "global", "defined", [{:elem, base, i}]}, _resolve) when is_integer(i) do
    with {:ok, path} <- content_path(base), do: {:ok, {:defined, path, i}}
  end

  defp check({:func, "global", "defined", [arg]}, _resolve) do
    with {:ok, path} <- content_path(arg), do: {:ok, {:defined, path, nil}}
  end

  # `a.b in [...]` is true when the value at the path equals a member, so an
  # array or a missing field never matches. A member that is null or not a
  # scalar leaves the conjunct to the other shapes. `"x" in a.b` is true when
  # `a.b` is an array holding `"x"`; a string there is not searched.
  defp check({:op, "in", l, r}, resolve) do
    with :error <- in_check(l, r, resolve), do: member_check(l, r, resolve)
  end

  defp check({:group, inner}, resolve), do: check(inner, resolve)
  defp check(_node, _resolve), do: :error

  defp length_check(op, l, r, resolve) do
    case {count_path(l), count_path(r)} do
      {{:ok, path}, _} -> length_n(path, op, r, resolve)
      {_, {:ok, path}} -> length_n(path, Map.fetch!(@length_ops, op), l, resolve)
      _ -> :error
    end
  end

  defp in_check(l, r, resolve) do
    with {:ok, path} <- content_path(l),
         {:ok, values} when is_list(values) <- value(r, resolve),
         true <- Enum.all?(values, &scalar?/1) do
      {:ok, {:in, path, Enum.uniq(values)}}
    else
      _ -> :error
    end
  end

  defp member_check(l, r, resolve) do
    with {:ok, path} <- content_path(r),
         {:ok, v} <- value(l, resolve),
         true <- scalar?(v) do
      {:ok, {:member, path, v}}
    else
      _ -> :error
    end
  end

  defp length_n(path, op, n, resolve) do
    case value(n, resolve) do
      {:ok, n} when is_integer(n) -> {:ok, {:length, path, op, n}}
      _ -> :error
    end
  end

  # `count(a.b[cond]) > 0` and `>= 1`, either side, and the same with
  # `length()`. A filter over anything but an array is null in GROQ, and so
  # are its count and length, so only an array with a matching element
  # passes. `mode` is `:exact` when every conjunct of `cond` must translate,
  # `:narrow` when one is enough.
  defp some_check({:op, op, l, r}, mode) do
    case {filter_count(l), filter_count(r)} do
      {{:ok, filter}, _} ->
        if at_least_one?(op, r), do: some_filter(filter, mode), else: :error

      {_, {:ok, filter}} ->
        if at_least_one?(Map.fetch!(@length_ops, op), l),
          do: some_filter(filter, mode),
          else: :error

      _ ->
        :error
    end
  end

  defp filter_count({:func, "global", name, [{:filter, _, _} = filter]})
       when name in ["count", "length"],
       do: {:ok, filter}

  defp filter_count(_node), do: :error

  # The bound is a literal or a parameter equal to 0 for `>` or 1 for `>=`.
  defp at_least_one?(op, n) do
    case Parser.const_eval(n) do
      {:ok, 0} -> op == ">"
      {:ok, 1} -> op == ">="
      _ -> false
    end
  end

  defp some_filter({:filter, base, element_cond}, mode) do
    with {:ok, path} <- content_path(base) do
      pairs = element_cond |> conjuncts() |> Enum.map(&element_pair/1)

      cond do
        mode == :exact and :error in pairs -> :error
        Enum.all?(pairs, &(&1 == :error)) -> :error
        true -> {:ok, {:some, path, for({:ok, pair} <- pairs, do: pair)}}
      end
    end
  end

  # `x.y == v`, `v == x.y` or `x.y in [...]` on an element, where `v` is a
  # literal or a parameter and every value is a scalar. `@` is the element
  # itself, with the empty field path. Values are read without the resolver:
  # inside the element filter `^` is the filtered document, not the scope
  # the resolver evaluates in.
  defp element_pair({:op, "==", l, r}) do
    with :error <- element_pair_eq(l, r), do: element_pair_eq(r, l)
  end

  defp element_pair({:op, "in", l, r}) do
    with {:ok, field} <- element_path(l),
         {:ok, values} when is_list(values) and values != [] <- value(r, nil),
         true <- Enum.all?(values, &scalar?/1) do
      {:ok, {field, Enum.uniq(values)}}
    else
      _ -> :error
    end
  end

  defp element_pair({:group, inner}), do: element_pair(inner)
  defp element_pair(_node), do: :error

  defp element_pair_eq(field, v) do
    with {:ok, path} <- element_path(field),
         {:ok, v} <- value(v, nil),
         true <- scalar?(v) do
      {:ok, {path, [v]}}
    else
      _ -> :error
    end
  end

  defp element_path({:this}), do: {:ok, []}

  defp element_path(expr) do
    case attr_path(expr) do
      {:ok, path} -> if Enum.all?(path, &is_binary/1), do: {:ok, path}, else: :error
      :error -> :error
    end
  end

  defp count_path({:func, "global", "count", [arg]}), do: content_path(arg)
  defp count_path(_node), do: :error

  defp content_path(expr) do
    case attr_path(expr) do
      {:ok, path} -> if exact_path?(path), do: {:ok, path}, else: :error
      :error -> :error
    end
  end

  # The renderer sets or drops the top-level `_` keys and `title`; an
  # all-digit segment would index an array in SQL but not in GROQ.
  defp exact_path?(["title" | _]), do: false

  defp exact_path?([first | _] = path) do
    not String.starts_with?(first, "_") and
      Enum.all?(path, &(is_binary(&1) and not (&1 =~ ~r/^-?\d+$/)))
  end

  @doc """
  The sort keys a source can order by in SQL for the `order()` arguments
  `args`, each with its direction, or `:error` when one is anything else. A
  key is `{:path, path}` for a content path, as in `checks`, or `:_id`,
  `:_createdAt` or `:_updatedAt`. `title` and functions stay in memory.
  """
  @spec order_keys([tuple()]) :: {:ok, [{order_key(), :asc | :desc}]} | :error
  def order_keys(args) do
    Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, acc} ->
      {expr, dir} =
        case arg do
          {:desc, e} -> {e, :desc}
          {:asc, e} -> {e, :asc}
          e -> {e, :asc}
        end

      case order_key(expr) do
        {:ok, key} -> {:cont, {:ok, acc ++ [{key, dir}]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp order_key(expr) do
    case attr_path(expr) do
      {:ok, ["_id"]} -> {:ok, :_id}
      {:ok, ["_createdAt"]} -> {:ok, :_createdAt}
      {:ok, ["_updatedAt"]} -> {:ok, :_updatedAt}
      {:ok, path} -> if exact_path?(path), do: {:ok, {:path, path}}, else: :error
      :error -> :error
    end
  end

  @doc "True when `expr` reads nothing but literals and `^` scopes."
  @spec outer_only?(tuple()) :: boolean()
  def outer_only?({:value, _}), do: true
  # A closed subquery reads no `^` and no filtered document.
  def outer_only?({:memo, _}), do: true
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

  defp apply_conjunct(node, acc, resolve) do
    with :error <- check(node, resolve),
         :error <- narrowing_check(node) do
      apply_match(node, acc, resolve)
    else
      {:ok, check} -> %{acc | checks: [check | acc.checks]}
    end
  end

  # An element condition with some conjuncts SQL cannot test: the others
  # still narrow the read, and the evaluator applies the whole condition.
  defp narrowing_check({:group, inner}), do: narrowing_check(inner)

  defp narrowing_check({:func, "global", "defined", [{:elem, {:filter, _, _} = filter, 0}]}),
    do: some_filter(filter, :narrow)

  defp narrowing_check({:op, op, _l, _r} = node) when is_map_key(@length_ops, op),
    do: some_check(node, :narrow)

  defp narrowing_check(_node), do: :error

  defp apply_match({:op, op, _l, _r} = node, acc, resolve) when op in ["==", "in"] do
    case orient(node, resolve) do
      {:ok, path, value} -> add(acc, op, path, value)
      :error -> add_probes(acc, node, resolve)
    end
  end

  defp apply_match(node, acc, resolve), do: add_probes(acc, node, resolve)

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
