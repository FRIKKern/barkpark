defmodule BarkparkWeb.Studio.StudioLive.UnsetPath do
  @moduledoc """
  Unset a value in the desk's form buffer as TanStack's `write()` (`edits.ts`)
  does: the key goes, and an object left holding only blanks (`""` or none)
  goes in turn, outward. An array row is never removed; the walk stops there.

  A top-level field is written `""`, which the save takes off the document. A
  key inside an object is written `nil`, which the save's composite restore
  (`Forms`) reads as unset; a key merely left out would be kept as stored.
  """

  alias BarkparkWeb.Studio.StudioLive.Path

  @spec unset(map(), [String.t() | non_neg_integer()]) :: map()
  def unset(form, [root]) when is_map(form) and is_binary(root), do: Map.put(form, root, "")

  def unset(form, path) when is_map(form) and length(path) > 1 do
    {parent, [key]} = Enum.split(path, -1)

    case value_at(form, parent) do
      %{} = map when is_binary(key) ->
        left = Map.put(map, key, nil)

        if blank?(left) and not row?(parent),
          do: unset(form, parent),
          else: Path.put_value_at(form, parent, left)

      _ ->
        form
    end
  end

  def unset(form, _path), do: form

  defp blank?(map), do: Enum.all?(map, fn {_key, value} -> value in [nil, ""] end)

  defp row?(path), do: is_integer(List.last(path))

  defp value_at(value, []), do: value

  defp value_at(%{} = map, [key | rest]) when is_binary(key),
    do: value_at(Map.get(map, key), rest)

  defp value_at(list, [idx | rest]) when is_list(list) and is_integer(idx),
    do: value_at(Enum.at(list, idx), rest)

  defp value_at(%{} = map, [idx | rest]) when is_integer(idx),
    do: value_at(Map.get(map, Integer.to_string(idx)), rest)

  defp value_at(_value, _path), do: nil
end
