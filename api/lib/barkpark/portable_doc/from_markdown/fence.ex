defmodule Barkpark.PortableDoc.FromMarkdown.Fence do
  @moduledoc """
  The ` ```portabledoc ` fence of `Barkpark.PortableDoc.FromMarkdown`: a JSON
  array of PortableDoc blocks, spliced into the import when it is

    * 1 to 50 blocks,
    * every block, nested ones included (a list item's `children`, a callout's
      `slots`), of an allowed display type: never fields, forms, embeds or
      other bound blocks, whose renderers assume editor- or resolver-provided
      invariants,
    * valid by `Barkpark.PortableDoc.Validate` as the blocks of a doc, which
      also caps how deep any value nests (`Validate.max_value_depth/0`, counted
      inside the doc's `%{"blocks" => ...}` envelope),
    * linking only to URLs the renderer allows (`Render.Util.safe_url/1`), and
    * reusing no block id from an earlier fence in the same import.

  Anything else stays a plain code block. `@portable-doc/text` `fromMarkdown`
  follows the same rules; the shared cases live in the golden pack's
  `from-markdown/`.
  """

  alias Barkpark.PortableDoc.FromMarkdown.Url
  alias Barkpark.PortableDoc.Validate

  @max_blocks 50

  @allowed_types ~w(
    heading paragraph list code table callout divider diagram
    chart stat stats heatmap pullquote eyebrow
  )

  @doc "The block types a fence may hold, at any depth."
  def allowed_types, do: @allowed_types

  @doc """
  The fence's blocks and the block ids seen so far with this fence's added, or
  `:error` when the fence must stay a code block.
  """
  @spec splice(String.t(), MapSet.t()) :: {:ok, [map()], MapSet.t()} | :error
  def splice(source, seen_ids) do
    with {:ok, blocks} when is_list(blocks) and blocks != [] <- Jason.decode(source),
         true <- length(blocks) <= @max_blocks,
         :ok <- Validate.validate(%{"blocks" => blocks}),
         {:ok, ids} <- scan([blocks], []),
         true <- Enum.all?(blocks, &allowed_block?/1),
         false <- Enum.any?(ids, &MapSet.member?(seen_ids, &1)) do
      {:ok, blocks, MapSet.union(seen_ids, MapSet.new(ids))}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # A block of an allowed type whose nested blocks are all allowed too.
  defp allowed_block?(%{"type" => type} = block) when type in @allowed_types,
    do: Enum.all?(nested_blocks(block), &allowed_block?/1)

  defp allowed_block?(_), do: false

  # The blocks a block holds: a list item's `children` and every slot's blocks.
  defp nested_blocks(block) do
    item_children =
      for %{"children" => children} when is_list(children) <- list_of(block["items"]),
          child <- children,
          do: child

    slot_blocks =
      for {_name, slot} <- map_of(block["slots"]), is_list(slot), child <- slot, do: child

    item_children ++ slot_blocks
  end

  defp list_of(value) when is_list(value), do: value
  defp list_of(_), do: []

  defp map_of(value) when is_map(value), do: value
  defp map_of(_), do: %{}

  # Every non-blank block id in the fence, or :error when an `href` in it is
  # unsafe. Iterative; Validate has already capped the depth.
  defp scan([], ids), do: {:ok, ids}

  defp scan([value | rest], ids) when is_map(value) or is_list(value) do
    if is_map(value) and Map.has_key?(value, "href") and
         Url.safe(value["href"]) != value["href"] do
      :error
    else
      children = if is_map(value), do: Map.values(value), else: value
      scan(Enum.reduce(children, rest, &[&1 | &2]), add_id(value, ids))
    end
  end

  defp scan([_leaf | rest], ids), do: scan(rest, ids)

  defp add_id(%{"id" => id, "type" => type}, ids) when is_binary(id) and is_binary(type) do
    if String.trim(id) == "", do: ids, else: [id | ids]
  end

  defp add_id(_value, ids), do: ids
end
