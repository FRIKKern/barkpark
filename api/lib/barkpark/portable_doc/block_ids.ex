defmodule Barkpark.PortableDoc.BlockIds do
  @moduledoc """
  Stable, collision-free block ids for a PortableDoc block list — the kernel
  half of the write chokepoint.

  ## Why it lives here

  `ensure_block_ids/1` used to live in `Barkpark.Content.Papers.BlockOps`, and
  `PortableDoc.Bpml.Diff.derive/2` aliased it to mint ids for the blocks a
  `bp paper push` introduces — a KERNEL module reaching UP into the *papers*
  feature (boundary edge `portable_doc>papers`, task-9d06bca37668f76a). The
  dependency was real: the BPML diff must mint ids "via the same
  `ensure_block_ids/1` every write path uses", or the ops it derives address
  blocks that do not exist yet. The PLACEMENT was wrong — this function knows
  nothing about papers, documents, `Repo` or ops. It is a pure function over a
  block list, i.e. over the PortableDoc block shape itself, so it moved DOWN to
  the layer that defines that shape.

  `BlockOps.ensure_block_ids/1` delegates here and stays the name every write
  path speaks (`upsert_paper`, `Content.Writer`, the op-folds, the backfill Mix
  task, `Content.ensure_block_ids/1`), so the "SINGLE chokepoint" property is
  unchanged — there is still exactly one implementation, and it is this one.

  Pure: no `Repo`, no schema, no deps.
  """

  @doc """
  R2 fix (Option A). Walk a block list and fill a stable positional id
  (`block-<index>`, sections recurse with a `<parent>.<index>` prefix) for
  any block that lacks one. A block already carrying a non-blank "id" is left
  untouched, so author/op-supplied ids — which DocPatchOps address blocks by —
  survive byte-identical and stay resolvable. Sections recurse so a nested
  id-less child also gets a unique id (the stream only keys on top-level ids,
  but `apply_paper_block_op` addresses children too).

  Coverage (the three id-less shapes a block can take):

    * ABSENT — no `"id"` key at all → gets `<prefix>-<index>`.
    * BLANK  — `"id" => ""` or `"id" => nil` → gets `<prefix>-<index>`.
    * NESTED — recursion covers any block carrying a `"blocks"` list — sections
      are the only id-addressable nested container, so they are the only thing
      recursed. (composite / arrayOf inline children nest under `"items"` /
      `"content"`, are inline — not id-addressable blocks — and are NOT
      recursed.) The recursion prefix is the parent's (now-ensured) id, keeping
      child ids unique and deterministic.

  Collision-safe WITHIN each list (and each nested list). Before minting, the
  set of all present non-blank ids at this level is collected. The positional
  candidate `<prefix>-<index>` is checked against that set PLUS every id already
  minted this pass; if taken, a deterministic suffix (`-<k>`, k incrementing
  from 1) is appended until free. So a MIXED list — an id-bearing block whose
  literal id collides with the positional slot of an id-less block, or two
  id-less blocks resolving to the same slot — can never produce DUPLICATE ids.

  Idempotent: re-running over an already-id-bearing list is a no-op (a present
  non-blank id is preserved exactly). This is the SINGLE chokepoint every write
  path that persists `content["blocks"]` routes through — the paper upsert path
  (`upsert_paper`), the document write path (`Content.Writer.create_document` /
  `upsert_document`, covering the Sanity-shaped mutation + legacy-create
  ingress), the op-fold paths (`apply_paper_block_op` / `apply_paper_block_ops`),
  and the backfill Mix task all call it, so an id-less block can never reach
  storage.

  Post-condition: within any block list (and each nested list), all ids are
  UNIQUE.
  """
  @spec ensure_block_ids(list()) :: list()
  def ensure_block_ids(blocks) when is_list(blocks), do: ensure_block_ids(blocks, "block")

  defp ensure_block_ids(blocks, prefix) when is_list(blocks) do
    # Seed the working set with EVERY present non-blank id at this level, so a
    # minted positional id can never collide with a literal id already present
    # (the mixed-paper duplicate-id corruption). The set then grows as each
    # id-less block is filled, so two id-less blocks at the same level can't
    # collide either.
    taken = present_ids(blocks)

    {ensured, _taken} =
      blocks
      |> Enum.with_index()
      |> Enum.map_reduce(taken, fn {block, index}, taken ->
        ensure_block_id(block, prefix, index, taken)
      end)

    ensured
  end

  # The set of all present, non-blank string ids in a block list (this level
  # only — nested lists carry their own scope).
  defp present_ids(blocks) do
    Enum.reduce(blocks, MapSet.new(), fn block, acc ->
      case is_map(block) && Map.get(block, "id") do
        id when is_binary(id) and id != "" -> MapSet.put(acc, id)
        _ -> acc
      end
    end)
  end

  # Returns `{ensured_block, taken'}` — the block with a guaranteed-unique id
  # (recursing into a section's children), and the working id-set extended with
  # any id this block now occupies. A present non-blank id is preserved exactly
  # (already in `taken`); an id-less block mints a collision-free positional id.
  defp ensure_block_id(block, prefix, index, taken) when is_map(block) do
    {id, taken} =
      case Map.get(block, "id") do
        existing when is_binary(existing) and existing != "" ->
          # Already present and already counted in `taken` via present_ids/1.
          {existing, taken}

        _ ->
          id = unique_id(prefix, index, taken)
          {id, MapSet.put(taken, id)}
      end

    block = Map.put(block, "id", id)

    block =
      case Map.get(block, "blocks") do
        children when is_list(children) ->
          Map.put(block, "blocks", ensure_block_ids(children, id))

        _ ->
          block
      end

    {block, taken}
  end

  defp ensure_block_id(block, _prefix, _index, taken), do: {block, taken}

  # The positional candidate `<prefix>-<index>`, disambiguated deterministically
  # if already taken: append `-1`, `-2`, … until free. Deterministic (no
  # randomness) so the same input always yields the same ids, and the appended
  # suffix is itself re-checked against `taken` so it can never collide.
  defp unique_id(prefix, index, taken) do
    candidate = "#{prefix}-#{index}"

    if MapSet.member?(taken, candidate) do
      disambiguate(candidate, taken, 1)
    else
      candidate
    end
  end

  defp disambiguate(base, taken, k) do
    candidate = "#{base}-#{k}"

    if MapSet.member?(taken, candidate) do
      disambiguate(base, taken, k + 1)
    else
      candidate
    end
  end
end
