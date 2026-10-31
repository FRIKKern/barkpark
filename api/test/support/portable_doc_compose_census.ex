defmodule Barkpark.PortableDoc.ComposeCensus do
  @moduledoc """
  The block types the reader renders, read off `render/compose.ex` itself.

  A canonical type is named by a `def compose_block/2,3` clause head: a literal
  `"type" => "x"` in the first-argument map pattern, or a literal `t in ["x", "y"]`
  guard over the variable that pattern binds. Nothing outside a clause head can
  move the set (#17811: a column-type guard in a private helper once did).

  An alias is a variable-guard clause (`t == "x"` or `t in @attr`) whose body
  rewrites `"type"` with `Map.put/3` before composing again. It has no tier of
  its own; it borrows its target's. A variable-guard clause that does not rewrite
  `"type"` (the task `unavailable` overlay) is neither.

  Shared by `tiers_test.exs` and `spec_test.exs`. Each passes the source in, so
  its own `"../"` path keeps it in `elixir-impacted-tests.sh`'s ALWAYS set: a
  change to compose.ex is not a compile edge to either test.
  """

  def types(source) do
    source
    |> Code.string_to_quoted!()
    |> clauses()
    |> Enum.flat_map(fn {head, _body} -> head_types(head) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def aliases(source) do
    ast = Code.string_to_quoted!(source)
    attrs = list_attributes(ast)

    for {head, body} <- clauses(ast),
        {:ok, {var, _, ctx}} when is_atom(var) and is_atom(ctx) <- [
          head |> call_of() |> first_arg_type()
        ],
        target <- List.wrap(type_rewrite(body)),
        spelling <- alias_spellings(guard_of(head), var, attrs),
        into: %{},
        do: {spelling, target}
  end

  defp clauses(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:def, _, [head | rest]} = node, acc -> {node, [{head, rest} | acc]}
        node, acc -> {node, acc}
      end)

    acc
    |> Enum.reverse()
    |> Enum.filter(fn {head, _} ->
      match?(
        {:compose_block, _, args} when is_list(args) and length(args) in [2, 3],
        call_of(head)
      )
    end)
  end

  defp call_of({:when, _, [call, _guard]}), do: call
  defp call_of(call), do: call

  defp guard_of({:when, _, [_call, guard]}), do: guard
  defp guard_of(_head), do: nil

  defp first_arg_type({:compose_block, _, [arg | _]}), do: type_pattern(arg)

  defp head_types(head) do
    case head |> call_of() |> first_arg_type() do
      {:ok, literal} when is_binary(literal) ->
        [literal]

      {:ok, {var, _, ctx}} when is_atom(var) and is_atom(ctx) ->
        guard_literals(guard_of(head), var)

      _ ->
        []
    end
  end

  defp type_pattern({:=, _, parts}) do
    Enum.find_value(parts, :error, fn part ->
      case type_pattern(part) do
        {:ok, value} -> {:ok, value}
        :error -> nil
      end
    end)
  end

  defp type_pattern({:%{}, _, pairs}) when is_list(pairs) do
    case List.keyfind(pairs, "type", 0) do
      {"type", value} -> {:ok, value}
      nil -> :error
    end
  end

  defp type_pattern(_other), do: :error

  defp guard_literals(guard, var) do
    collect(guard, fn
      {:in, _, [{^var, _, _}, list]} when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> nil
    end)
  end

  defp alias_spellings(guard, var, attrs) do
    collect(guard, fn
      {:==, _, [{^var, _, _}, literal]} when is_binary(literal) -> [literal]
      {:in, _, [{^var, _, _}, {:@, _, [{attr, _, _}]}]} -> Map.fetch!(attrs, attr)
      _ -> nil
    end)
  end

  defp type_rewrite(body) do
    case collect(body, &map_put_type/1) do
      [] -> nil
      [target] -> target
    end
  end

  defp map_put_type({{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, args}) do
    case Enum.take(args, -2) do
      ["type", target] when is_binary(target) -> [target]
      _ -> nil
    end
  end

  defp map_put_type(_node), do: nil

  defp list_attributes(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          case string_list(value) do
            nil -> {node, acc}
            list -> {node, Map.put(acc, name, list)}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp string_list({:sigil_w, _, [{:<<>>, _, [words]}, []]}), do: String.split(words)

  defp string_list(list) when is_list(list),
    do: if(Enum.all?(list, &is_binary/1), do: list, else: nil)

  defp string_list(_value), do: nil

  defp collect(ast, fun) do
    {_, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case fun.(node) do
          nil -> {node, acc}
          found -> {node, acc ++ found}
        end
      end)

    acc
  end
end
