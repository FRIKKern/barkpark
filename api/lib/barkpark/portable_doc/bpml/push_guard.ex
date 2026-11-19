defmodule Barkpark.PortableDoc.Bpml.PushGuard do
  @moduledoc """
  A BPML push may remove only what its working copy showed.

  A copy pulled since the print checked itself (`Bpml.RoundTrip`) carries the
  print mark `print_mark/0`: the pull answers it in `x-bpml-print`, `bp paper
  pull` keeps it with the anchor, and `bp paper push` sends it back as
  `bpmlPrint`. Such a copy showed every part of the Paper, so what it leaves out
  the person removed.

  A copy without the mark (pulled before, or written from scratch for a slug
  that exists) may not have shown everything. Its push is compared with what is
  stored, and refused, naming the block paths, when it would remove a block, a
  list item's children or a callout's body.
  """

  @print_mark "1"

  @doc "The mark a pull carries and a push sends back."
  @spec print_mark() :: String.t()
  def print_mark, do: @print_mark

  @doc "A sync answer whose `bpml` printed carries the mark (`bpmlPrint`)."
  @spec mark(map()) :: map()
  def mark(%{bpml: bpml} = payload) when is_binary(bpml),
    do: Map.put(payload, :bpmlPrint, @print_mark)

  def mark(payload), do: payload

  @doc """
  `Bpml.Diff.derive/2` of the stored and pushed blocks, after `check/3`: a copy
  without the current mark that would remove parts answers
  `{:error, envelope}` and derives nothing.
  """
  @spec derive([map()], [map()] | nil, term()) ::
          {:ok, [map()], [map()]} | {:error, map() | atom()}
  def derive(stored, pushed, mark) do
    pushed = pushed || []

    with :ok <- check(stored, pushed, mark),
         do: Barkpark.PortableDoc.Bpml.Diff.derive(stored, pushed)
  end

  @doc """
  `:ok`, or `{:error, envelope}` when a copy without the current mark would
  remove parts of the stored blocks.
  """
  @spec check([map()], [map()], term()) :: :ok | {:error, map()}
  def check(_stored, _pushed, @print_mark), do: :ok

  def check(stored, pushed, _mark) do
    case removals(stored, pushed) do
      [] ->
        :ok

      paths ->
        {:error,
         %{
           code: "bpml_unshown_removal",
           message:
             "this push would remove #{Enum.join(paths, ", ")}, which your copy may never have shown: " <>
               "it has no print mark (it was pulled before the print checked itself, or written from scratch for a Paper that exists). " <>
               "Pull again (bp paper pull) and make your change in the fresh copy.",
           paths: paths
         }}
    end
  end

  @doc false
  # Block paths in `stored` that `pushed` no longer holds: top-level blocks by
  # id, every nested block id, list item children and callout bodies.
  @spec removals([map()], [map()]) :: [String.t()]
  def removals(stored, pushed) when is_list(stored) and is_list(pushed) do
    pushed_ids = pushed |> ids() |> MapSet.new()
    pushed_by_id = for %{"id" => id} = b <- pushed, into: %{}, do: {id, b}

    stored
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, i} ->
      path = "blocks[#{i}]"

      case block do
        %{"id" => id} when is_map_key(pushed_by_id, id) ->
          nested_ids_gone(block, pushed_ids, path) ++ parts_gone(block, pushed_by_id[id], path)

        %{"id" => id} when is_binary(id) ->
          [path]

        _ ->
          parts_gone(block, Enum.at(pushed, i), path)
      end
    end)
    |> Enum.uniq()
  end

  def removals(_stored, _pushed), do: []

  defp ids(term) when is_list(term), do: Enum.flat_map(term, &ids/1)

  defp ids(%{} = m) do
    own = if is_binary(m["id"]) and is_binary(m["type"]), do: [m["id"]], else: []
    own ++ (m |> Map.values() |> ids())
  end

  defp ids(_), do: []

  defp nested_ids_gone(block, pushed_ids, path) do
    block
    |> Map.drop(["id"])
    |> ids()
    |> Enum.reject(&MapSet.member?(pushed_ids, &1))
    |> Enum.map(&"#{path} (block #{&1})")
  end

  # Item children and callout bodies, compared at the same path.
  defp parts_gone(%{"type" => "callout"} = old, new, path) do
    gone =
      if filled?(get_in(old, ["slots", "body"])) and not filled?(slot_body(new)),
        do: ["#{path}.slots.body"],
        else: []

    gone ++ walk(old, new, path)
  end

  defp parts_gone(%{"items" => items} = old, new, path) when is_list(items) do
    new_items = if is_map(new), do: List.wrap(new["items"]), else: []

    gone =
      items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, j} ->
        new_item = Enum.at(new_items, j)

        if is_map(item) and filled?(item["children"]) and
             not (is_map(new_item) and filled?(new_item["children"])),
           do: ["#{path}.items[#{j}].children"],
           else: []
      end)

    gone ++ walk(old, new, path)
  end

  defp parts_gone(old, new, path), do: walk(old, new, path)

  defp walk(%{} = old, %{} = new, path) do
    Enum.flat_map(old, fn {k, v} ->
      case Map.fetch(new, k) do
        {:ok, nv} -> walk_value(v, nv, "#{path}.#{k}")
        :error -> []
      end
    end)
  end

  defp walk(_old, _new, _path), do: []

  defp walk_value(%{} = v, nv, path), do: parts_gone(v, nv, path)

  defp walk_value(v, nv, path) when is_list(v) and is_list(nv) do
    v
    |> Enum.with_index()
    |> Enum.flat_map(fn {x, i} -> walk_value(x, Enum.at(nv, i), "#{path}[#{i}]") end)
  end

  defp walk_value(_v, _nv, _path), do: []

  defp slot_body(%{"slots" => %{"body" => body}}), do: body
  defp slot_body(_), do: nil

  defp filled?(v), do: v not in [nil, [], %{}, ""]
end
