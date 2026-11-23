defmodule Barkpark.PortableDoc.Bpml.WriteWall.Items do
  @moduledoc """
  The write wall's rule, read per list item (task-0b448ea0847a6b4f).

  An item that is still there, with its id, in the same block, its unshown
  keys carried byte for byte from the stored copy (`Bpml.ListItems.carry/2`),
  loses nothing, so it is not refused. An unshown path is that item's when it
  lies inside a stored list item with an id (the innermost such item wins), and
  it is kept when all of these hold:

    * the stored top-level block holds that item id once;
    * the push's top-level block with the same id holds exactly one item with
      that id, at any depth;
    * the value at the same place inside that item is byte-equal to the stored
      one, both in `Canonical.normalize` spelling.

  Every other unshown path stays, and `Bpml.WriteWall` refuses on it.
  """

  alias Barkpark.PortableDoc.Bpml.{Canonical, ListItems}

  @doc """
  `paths` (unshown paths of stored block `s`, as `Bpml.WriteWall` spells them)
  less those a list item in `result` keeps, by the rule above.
  """
  @spec uncovered([String.t()], map(), [map()]) :: [String.t()]
  def uncovered([], _s, _result), do: []

  def uncovered(paths, %{"id" => id} = s, result) when is_binary(id) do
    case Enum.filter(result, &(is_map(&1) and &1["id"] == id)) do
      [r] ->
        [ns] = Canonical.normalize([s])
        [nr] = Canonical.normalize([r])
        here = %{prefixes: prefixes(ns), stored: ListItems.index(ns)}
        here = Map.put(here, :result, ListItems.index(nr))
        Enum.reject(paths, &kept?(&1, here))

      _ ->
        paths
    end
  end

  def uncovered(paths, _s, _result), do: paths

  defp kept?(path, here) do
    with {prefix, id} <- innermost(path, here.prefixes),
         {:ok, s} <- Map.fetch(here.stored, id),
         {:ok, r} <- Map.fetch(here.result, id) do
      rel = binary_part(path, byte_size(prefix), byte_size(path) - byte_size(prefix))

      case Map.fetch(paths(s), rel) do
        {:ok, v} -> Map.fetch(paths(r), rel) == {:ok, v}
        :error -> false
      end
    else
      _ -> false
    end
  end

  defp innermost(path, prefixes) do
    prefixes
    |> Enum.filter(fn {p, _id} ->
      path == p or String.starts_with?(path, p <> ".") or String.starts_with?(path, p <> "[")
    end)
    |> Enum.max_by(fn {p, _id} -> byte_size(p) end, fn -> nil end)
  end

  # `{path, id}` of every list item with an id, at any depth.
  defp prefixes(block) do
    for {path, node} <- paths(block),
        ListItems.list?(node),
        {%{"id" => id}, i} <- Enum.with_index(node["items"]),
        is_binary(id) and id != "",
        do: {"#{path}.items[#{i}]", id}
  end

  # Every value inside `node` by its path below it ("" is `node` itself),
  # spelled as `Bpml.WriteWall` spells paths (`.key`, `[i]`).
  defp paths(node, path \\ "", acc \\ %{}) do
    acc = Map.put(acc, path, node)

    cond do
      is_map(node) ->
        Enum.reduce(node, acc, fn {k, v}, acc -> paths(v, "#{path}.#{k}", acc) end)

      is_list(node) ->
        node
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {v, i}, acc -> paths(v, "#{path}[#{i}]", acc) end)

      true ->
        acc
    end
  end
end
