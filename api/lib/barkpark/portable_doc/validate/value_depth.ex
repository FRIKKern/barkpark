defmodule Barkpark.PortableDoc.Validate.ValueDepth do
  @moduledoc """
  The value-depth limit of `Barkpark.PortableDoc.Validate`: any JSON value,
  block or not, nests at most `max/0` (1000) JSON levels from the doc root, so
  every valid doc can be written back out as JSON. `@portable-doc/validate`
  has the same limit as `MAX_VALUE_DEPTH` (`tooDeepValues` in its `index.js`).

  Every array and object is one level, and the doc root is level 1: a bare
  blocks array is level 1, `%{"blocks" => [...]}` puts the array at level 2
  and its blocks at level 3. A value at exactly `max/0` passes; the first array
  or object past it, in document order, is `too_deep` at its path, and nothing
  under it is walked. The walk covers what the schema walk does not reach too
  (open fields, inline `children`, extra keys). A block the schema walk already
  stopped as `too_deep` (block depth) is not counted again. Object keys are
  walked in sorted order, since a decoded map keeps no insertion order.

  Iterative: depth costs no stack.
  """

  @max 1000

  @doc "How many JSON levels any value may nest from the doc root."
  @spec max() :: pos_integer()
  def max, do: @max

  @doc """
  The `too_deep` errors of `value` found at `path`, `level` JSON levels from
  the doc root, skipping the paths in `skip`, in document order.
  """
  @spec errors(term(), String.t(), pos_integer(), MapSet.t()) :: [
          %{code: :too_deep, path: String.t()}
        ]
  def errors(value, path, level, skip) do
    if container?(value), do: walk([{value, path, level}], skip, []), else: []
  end

  defp walk([], _skip, acc), do: Enum.reverse(acc)

  defp walk([{value, path, level} | rest], skip, acc) do
    cond do
      MapSet.member?(skip, path) -> walk(rest, skip, acc)
      level > @max -> walk(rest, skip, [%{code: :too_deep, path: path} | acc])
      true -> walk(children(value, path, level + 1) ++ rest, skip, acc)
    end
  end

  # The arrays and objects directly inside a container, in document order.
  defp children(list, path, level) when is_list(list) do
    for {child, i} <- Enum.with_index(list),
        container?(child),
        do: {child, pointer(path, Integer.to_string(i)), level}
  end

  defp children(map, path, level) when is_map(map) do
    for {key, child} <- Enum.sort(map),
        container?(child),
        do: {child, pointer(path, to_string(key)), level}
  end

  # A struct (a DateTime off a decoded row, say) is not JSON structure: a leaf.
  defp container?(value), do: is_list(value) or (is_map(value) and not is_struct(value))

  defp pointer(path, key),
    do: path <> "/" <> (key |> String.replace("~", "~0") |> String.replace("/", "~1"))
end
