defmodule Barkpark.PortableDoc.Bpml.Diff do
  @moduledoc """
  Old blocks → new blocks as a DocPatchOp batch (BPML masterplan W3). The
  working copy's keystone: `bp paper push` sends an edited BPML document and
  the server derives the ops here — nobody hand-writes an op, and the op
  vocabulary stays the only write path.

  Pure and self-verifying: `derive/2` id-keys both lists (minting ids for new
  blocks via the same `BlockIds.ensure_block_ids/1` every write path uses —
  `Content.Papers.BlockOps.ensure_block_ids/1` is a delegate to it),
  emits removes → then a single left-to-right walk that inserts, moves and
  replaces — and then PROVES the batch by replaying it through
  `Patch.apply_patches/2`: a batch that does not reproduce the target
  exactly is refused (`{:error, :diff_verification_failed}`), never applied.
  Top-level granularity on purpose: a change inside a section replaces the
  section block wholesale (`replace-block` is total), which keeps the derivation
  obviously correct at the cost of coarser ops.
  """

  alias Barkpark.PortableDoc.BlockIds
  alias Barkpark.PortableDoc.Patch

  @doc """
  `{:ok, minted_new_blocks, ops}` — ops transform `old` into `minted_new_blocks`
  (the caller persists ops and treats `minted_new_blocks` as the result truth) —
  or `{:error, :diff_verification_failed}` if the replay proof fails.
  `{:ok, new, []}` means the documents are already equal.
  """
  @spec derive([map()], [map()]) ::
          {:ok, [map()], [op :: map()]} | {:error, :diff_verification_failed}
  def derive(old, new) when is_list(old) and is_list(new) do
    new =
      new
      |> BlockIds.ensure_block_ids()
      |> keep_unedited(old)

    if old == new do
      {:ok, new, []}
    else
      ops = removes(old, new) ++ walk(old, new)
      verify(old, new, ops)
    end
  end

  # AN UNEDITED BLOCK KEEPS ITS STORED BYTES (Run-4 round-trip matrix).
  #
  # The parser emits the CANONICAL spelling of a block, and the store holds
  # whatever dialect wrote it: object marks (`%{"type" => "bold"}`) where BPML
  # reads back `"strong"`, an empty step with no `blocks` key where the parser
  # adds `[]`, a `role`/`locked` the grammar cannot spell. Compared by full map
  # equality, every such block derived a `replace-block` on a push nobody
  # edited — rewriting stored data (and, for a locked block, a refused batch).
  #
  # A pushed block whose BPML spelling equals the stored block's spelling was
  # not edited: the author can only change what BPML spells. So it is replaced
  # by the stored block before the diff, and derives no op. A block the printer
  # cannot spell is compared by map equality as before.
  defp keep_unedited(new, old) do
    old_by_id = Map.new(old, &{&1["id"], &1})

    Enum.map(new, fn block ->
      case Map.fetch(old_by_id, block["id"]) do
        {:ok, stored} when stored != block ->
          if same_spelling?(stored, block), do: stored, else: block

        _ ->
          block
      end
    end)
  end

  defp same_spelling?(a, b) do
    Barkpark.PortableDoc.Bpml.print_blocks([a]) == Barkpark.PortableDoc.Bpml.print_blocks([b])
  rescue
    _ -> false
  end

  defp removes(old, new) do
    keep = MapSet.new(new, & &1["id"])

    old
    |> Enum.reject(&MapSet.member?(keep, &1["id"]))
    |> Enum.map(&%{"op" => "remove-block", "id" => &1["id"]})
  end

  # One pass over the DESIRED list, simulating the working order as ops land:
  # every desired block must sit directly after `prev` (nil = head) with the
  # desired content.
  defp walk(old, new) do
    keep = MapSet.new(new, & &1["id"])
    old_by_id = Map.new(old, &{&1["id"], &1})
    sim = old |> Enum.filter(&MapSet.member?(keep, &1["id"])) |> Enum.map(& &1["id"])

    {ops, _sim, _prev} =
      Enum.reduce(new, {[], sim, nil}, fn block, {ops, sim, prev} ->
        id = block["id"]
        expected = if prev == nil, do: 0, else: Enum.find_index(sim, &(&1 == prev)) + 1

        cond do
          id not in sim and prev == nil ->
            # New block at the very head: append lands it last, the move lifts
            # it to the front (insert-after has no head form).
            ops = [
              %{"op" => "move-block", "id" => id, "after" => nil},
              %{"op" => "append-block", "block" => block} | ops
            ]

            {ops, List.insert_at(sim, 0, id), id}

          id not in sim ->
            ops = [%{"op" => "insert-after", "afterId" => prev, "block" => block} | ops]
            {ops, List.insert_at(sim, expected, id), id}

          true ->
            at = Enum.find_index(sim, &(&1 == id))

            {ops, sim} =
              if at == expected do
                {ops, sim}
              else
                sim =
                  sim
                  |> List.delete(id)
                  |> List.insert_at(
                    if(prev == nil,
                      do: 0,
                      else: Enum.find_index(List.delete(sim, id), &(&1 == prev)) + 1
                    ),
                    id
                  )

                {[%{"op" => "move-block", "id" => id, "after" => prev} | ops], sim}
              end

            ops =
              if Map.fetch!(old_by_id, id) == block do
                ops
              else
                [%{"op" => "replace-block", "id" => id, "block" => block} | ops]
              end

            {ops, sim, id}
        end
      end)

    Enum.reverse(ops)
  end

  # The replay proof: the batch must reproduce the target byte-equal.
  defp verify(old, new, ops) do
    case Patch.apply_patches(old, ops) do
      {:ok, ^new} -> {:ok, new, ops}
      _ -> {:error, :diff_verification_failed}
    end
  end
end
