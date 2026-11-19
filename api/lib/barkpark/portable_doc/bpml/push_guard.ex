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
  list item's children or a callout's body. A `bp` from before the mark never
  sends one, so its pushes may not remove those parts either.

  When the print learns to carry a part it could not carry before, the mark
  goes up: a copy pulled before then counts as unmarked.
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
               "Pull again with a current bp (bp paper pull) and make your change in the fresh copy.",
           paths: paths
         }}
    end
  end

  @doc false
  # Block paths in `stored` that `pushed` no longer holds: top-level blocks by
  # id, every nested block id, and every list item's children and callout body.
  # Those two are compared by content, not position: each stored one must still
  # be somewhere in the pushed document (as many times as it was stored), so a
  # reorder passes and a swap that drops one is refused.
  @spec removals([map()], [map()]) :: [String.t()]
  def removals(stored, pushed) when is_list(stored) and is_list(pushed) do
    pushed_ids = pushed |> ids() |> MapSet.new()

    blocks_gone =
      stored
      |> Enum.with_index()
      |> Enum.flat_map(fn {block, i} ->
        path = "blocks[#{i}]"

        case block do
          %{"id" => id} when is_binary(id) ->
            if MapSet.member?(pushed_ids, id),
              do: nested_ids_gone(block, pushed_ids, path),
              else: [path]

          _ ->
            []
        end
      end)

    blocks_gone ++ parts_gone(stored, pushed, blocks_gone)
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

  # Each stored item-children list and callout body, by path, that the pushed
  # document no longer holds. A part inside a block already named as removed is
  # not named twice.
  defp parts_gone(stored, pushed, blocks_gone) do
    held = pushed |> parts("blocks") |> Enum.map(&elem(&1, 1)) |> Enum.frequencies()

    {gone, _held} =
      stored
      |> parts("blocks")
      |> Enum.reduce({[], held}, fn {path, part}, {gone, held} ->
        case Map.get(held, part, 0) do
          0 -> {[path | gone], held}
          n -> {gone, Map.put(held, part, n - 1)}
        end
      end)

    gone
    |> Enum.reverse()
    |> Enum.reject(fn path -> Enum.any?(blocks_gone, &String.starts_with?(path, &1 <> ".")) end)
  end

  defp parts(%{} = m, path) do
    own =
      case m do
        %{"type" => "callout", "slots" => %{"body" => body}} ->
          if filled?(body), do: [{"#{path}.slots.body", body}], else: []

        _ ->
          []
      end

    items =
      for {item, j} <- Enum.with_index(List.wrap(m["items"])),
          is_map(item) and filled?(item["children"]),
          do: {"#{path}.items[#{j}].children", item["children"]}

    own ++ items ++ Enum.flat_map(Enum.sort(m), fn {k, v} -> parts(v, "#{path}.#{k}") end)
  end

  defp parts(l, path) when is_list(l),
    do: l |> Enum.with_index() |> Enum.flat_map(fn {x, i} -> parts(x, "#{path}[#{i}]") end)

  defp parts(_other, _path), do: []

  defp filled?(v), do: v not in [nil, [], %{}, ""]
end
