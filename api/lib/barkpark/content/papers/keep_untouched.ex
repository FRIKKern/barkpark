defmodule Barkpark.Content.Papers.KeepUntouched do
  @moduledoc """
  The batch write's render shapes (`BlockOps.normalize_render_shapes/1`), with
  one opt-in exception: under `keep_untouched: true`, a top-level block with
  its own id that the batch left exactly as stored keeps its stored bytes.

  The chokepoint rewrites older shapes (bare-string list items, `{"text"}`
  items, text-keyed leaves) in every block of the Paper, touched or not. A
  BPML push (`Bpml.WriteWall`) lets a block holding content its pull did not
  show through only when it comes out byte-equal to the stored block, so the
  sync write asks for this: a block it did not change is written back as it
  was read. A block the batch changed, a new block, a block with no id, and a
  block whose id the stored Paper holds twice get the shapes as before. Every
  other writer is unchanged.
  """

  alias Barkpark.Content.Papers.BlockOps

  @doc """
  `blocks` (the batch result) in the persisted shapes; with `keep_untouched:
  true` in `opts`, each block equal to the `authored` block under its id (the
  row as read) stays as it is.
  """
  @spec shapes(list(), list() | nil, keyword()) :: list()
  def shapes(blocks, authored, opts) when is_list(blocks) do
    normalized = BlockOps.normalize_render_shapes(blocks)

    if Keyword.get(opts, :keep_untouched) == true and is_list(authored) do
      stored = by_unique_id(authored)
      Enum.zip_with(blocks, normalized, &if(untouched?(&1, stored), do: &1, else: &2))
    else
      normalized
    end
  end

  defp untouched?(%{"id" => id} = block, stored) when is_binary(id),
    do: Map.get(stored, id) == block

  defp untouched?(_block, _stored), do: false

  defp by_unique_id(authored) do
    ids = for %{"id" => id} when is_binary(id) <- authored, do: id
    twice = MapSet.new(ids -- Enum.uniq(ids))

    for %{"id" => id} = b <- authored,
        is_binary(id),
        not MapSet.member?(twice, id),
        into: %{},
        do: {id, b}
  end
end
