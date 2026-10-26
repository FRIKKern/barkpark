defmodule Barkpark.Groq.Diff do
  @moduledoc """
  `diff::changedAny(lhs, rhs, selector)` and `diff::changedOnly(lhs, rhs,
  selector)` (task-13790b478beeee4d), as Sanity's API answers them
  (ecu57yeh, 26 Oct) and its GROQ test suite pins them.

  A selector is a list of steps the parser builds: `{:key, name}`, `{:group,
  [selector]}` (a tuple `(a, b)`), `:each` (`[]`), `{:filter, cond}` (`[cond]`)
  and `{:anywhere, cond}`. `test` answers whether a condition is true for a
  value.

    * Both values must be objects; otherwise both functions answer false.
    * A key step on two objects compares that key (absent reads as null); on
      anything else it selects nothing.
    * An array step compares by position. Arrays of different lengths, or an
      array on one side only, are a change; two non-arrays select nothing.
    * `anywhere(cond)` selects every node where `cond` is true; a node found at
      different places on the two sides is a change.
    * `changedOnly` masks what the selector selects on both sides and answers
      whether the rest is equal.
  """

  @type step ::
          {:key, String.t()}
          | {:group, [[step]]}
          | :each
          | {:filter, term()}
          | {:anywhere, term()}

  @doc "True when any value the selector selects differs between `l` and `r`."
  @spec changed_any?([step], term(), term(), (term(), term() -> boolean())) :: boolean()
  def changed_any?(sel, l, r, test) when is_map(l) and is_map(r), do: changed?(sel, l, r, test)
  def changed_any?(_sel, _l, _r, _test), do: false

  @doc "True when nothing outside what the selector selects differs."
  @spec changed_only?([step], term(), term(), (term(), term() -> boolean())) :: boolean()
  def changed_only?(sel, l, r, test) when is_map(l) and is_map(r) do
    {ml, mr} = mask(sel, l, r, test)
    equal?(ml, mr)
  end

  def changed_only?(_sel, _l, _r, _test), do: false

  defp changed?([], l, r, _test), do: not equal?(l, r)

  defp changed?([{:key, k} | rest], l, r, test) when is_map(l) and is_map(r),
    do: changed?(rest, Map.get(l, k), Map.get(r, k), test)

  defp changed?([{:key, _} | _], _l, _r, _test), do: false

  defp changed?([{:group, sels} | rest], l, r, test),
    do: Enum.any?(sels, &changed?(&1 ++ rest, l, r, test))

  defp changed?([{:anywhere, cond} | rest], l, r, test) do
    lm = matches(l, cond, test, [], [])
    rm = matches(r, cond, test, [], [])

    if Enum.map(lm, &elem(&1, 0)) != Enum.map(rm, &elem(&1, 0)) do
      true
    else
      Enum.zip(lm, rm) |> Enum.any?(fn {{_, lv}, {_, rv}} -> changed?(rest, lv, rv, test) end)
    end
  end

  defp changed?([step | rest], l, r, test) when step == :each or elem(step, 0) == :filter do
    cond do
      is_list(l) and is_list(r) and length(l) != length(r) ->
        true

      is_list(l) and is_list(r) ->
        Enum.zip(l, r)
        |> Enum.any?(fn {lv, rv} ->
          selected?(step, lv, rv, test) and changed?(rest, lv, rv, test)
        end)

      is_list(l) or is_list(r) ->
        true

      true ->
        false
    end
  end

  defp selected?(:each, _lv, _rv, _test), do: true
  defp selected?({:filter, cond}, lv, rv, test), do: test.(cond, lv) or test.(cond, rv)

  # Every node (pre-order) whose condition is true, with its path.
  defp matches(value, cond, test, path, acc) do
    acc = if test.(cond, value), do: [{Enum.reverse(path), value} | acc], else: acc

    case value do
      %{} = map ->
        map
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce(acc, fn {k, v}, acc -> matches(v, cond, test, [k | path], acc) end)

      list when is_list(list) ->
        list
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {v, i}, acc -> matches(v, cond, test, [i | path], acc) end)

      _ ->
        acc
    end
    |> then(fn acc -> if path == [], do: Enum.reverse(acc), else: acc end)
  end

  defp mask([], _l, _r, _test), do: {:masked, :masked}

  defp mask([{:key, k} | rest], l, r, test) when is_map(l) and is_map(r) do
    {a, b} = mask(rest, Map.get(l, k), Map.get(r, k), test)
    {Map.put(l, k, a), Map.put(r, k, b)}
  end

  defp mask([{:key, _} | _], l, r, _test), do: {l, r}

  defp mask([{:group, sels} | rest], l, r, test),
    do: Enum.reduce(sels, {l, r}, fn sel, {l, r} -> mask(sel ++ rest, l, r, test) end)

  defp mask([{:anywhere, cond} | rest], l, r, test),
    do: {mask_anywhere(l, cond, rest, test), mask_anywhere(r, cond, rest, test)}

  defp mask([step | rest], l, r, test) when is_list(l) and is_list(r) do
    if length(l) == length(r) do
      Enum.zip(l, r)
      |> Enum.map(fn {lv, rv} ->
        if selected?(step, lv, rv, test), do: mask(rest, lv, rv, test), else: {lv, rv}
      end)
      |> Enum.unzip()
    else
      {l, r}
    end
  end

  defp mask([_step | _], l, r, _test), do: {l, r}

  defp mask_anywhere(value, cond, rest, test) do
    if test.(cond, value) do
      value |> then(&mask(rest, &1, &1, test)) |> elem(0)
    else
      case value do
        %{} = map -> Map.new(map, fn {k, v} -> {k, mask_anywhere(v, cond, rest, test)} end)
        list when is_list(list) -> Enum.map(list, &mask_anywhere(&1, cond, rest, test))
        other -> other
      end
    end
  end

  @doc "Deep equality: object key order and an absent key versus null do not count; 1 == 1.0."
  @spec equal?(term(), term()) :: boolean()
  def equal?(%{} = a, %{} = b) do
    keys = MapSet.new(Map.keys(a) ++ Map.keys(b))
    Enum.all?(keys, fn k -> equal?(Map.get(a, k), Map.get(b, k)) end)
  end

  def equal?(a, b) when is_list(a) and is_list(b),
    do: length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> equal?(x, y) end)

  def equal?(a, b) when is_number(a) and is_number(b), do: a == b
  def equal?(a, b), do: a === b
end
