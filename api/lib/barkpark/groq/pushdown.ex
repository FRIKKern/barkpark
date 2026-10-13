defmodule Barkpark.Groq.Pushdown do
  @moduledoc """
  Reads the constraints a document source can apply before evaluation from the
  filter of a `*[...]`.

  Only the top-level `&&` conjuncts count, and only these shapes, with a value
  on one side that does not depend on the filtered document:

    * `_type == "t"`, `_type in ["a", "b"]` -> `types`
    * `_id == "x"`, `_id in [...]` -> `ids`
    * `a.b == "x"` on a content path -> `eq` (JSON containment)
    * `a.b in ["x", "y"]` with scalar members -> `any`

  The value side is a literal, a parameter, arithmetic over them, or an
  expression over `^` (such as `^._id` or `^.author._ref`). The caller passes a
  resolver that evaluates the `^` forms in the scope the filter runs in, so a
  subquery inside a projection gets its own constraints per parent document.

  A conjunct that reads the filtered document on both sides, dereferences, or
  calls a function stays in memory. The source may return more documents than
  match; the evaluator always applies the whole filter afterwards.
  """

  alias Barkpark.Groq.Parser

  @system_paths ~w(_rev _createdAt _updatedAt _originalId title)

  @type t :: %{types: [String.t()] | nil, ids: [String.t()] | nil, eq: list(), any: list()}

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

  @doc "True when `expr` reads nothing but literals and `^` scopes."
  @spec outer_only?(tuple()) :: boolean()
  def outer_only?({:value, _}), do: true
  def outer_only?({:parent, n}) when n >= 1, do: true
  def outer_only?({:attr, base, _}) when is_tuple(base), do: outer_only?(base)
  def outer_only?({:elem, base, _}), do: outer_only?(base)
  def outer_only?({:group, base}), do: outer_only?(base)

  def outer_only?({:op, op, l, r}) when op in ["+", "-", "*", "/", "%", "**"],
    do: outer_only?(l) and outer_only?(r)

  def outer_only?({:array, elems}), do: Enum.all?(elems, fn {e, _splat?} -> outer_only?(e) end)
  def outer_only?(_), do: false

  defp conjuncts({:and, l, r}), do: conjuncts(l) ++ conjuncts(r)
  defp conjuncts({:group, inner}), do: conjuncts(inner)
  defp conjuncts(other), do: [other]

  defp apply_conjunct({:op, op, _l, _r} = node, acc, resolve) when op in ["==", "in"] do
    case orient(node, resolve) do
      {:ok, path, value} -> add(acc, op, path, value)
      :error -> acc
    end
  end

  defp apply_conjunct(_other, acc, _resolve), do: acc

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

  defp add(acc, "==", [first | _] = path, v) when is_binary(v) or is_number(v) or is_boolean(v) do
    if system_path?(first), do: acc, else: %{acc | eq: [{path, v} | acc.eq]}
  end

  defp add(acc, "in", [first | _] = path, vs) do
    scalars? = vs != [] and Enum.all?(vs, &(is_binary(&1) or is_number(&1) or is_boolean(&1)))

    if scalars? and not system_path?(first),
      do: %{acc | any: [{path, vs} | acc.any]},
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
