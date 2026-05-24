defmodule Barkpark.PortableDoc.Patch do
  @moduledoc """
  Pure, immutable patch operations over a PortableDoc block tree. A direct
  in-process port of the TS `applyDocPatch()` in
  `portable-doc/packages/core/src/patch.ts`, conforming to the shared
  inter-repo contract (`docs/doc-patch-op-contract.md`) and the golden
  fixtures in `fixtures/doc-patch-op/`.

  `apply_patch/2` is **pure**: it never mutates its input, performs no Repo
  access, no GenServer, no I/O. It returns either a new document/block list or
  a [structured error](#module-errors) — never a silent no-op, never a
  partially-applied result.

  ## Wire shape

  Documents and ops cross process boundaries as JSON, so this module operates
  on plain maps keyed by **string keys** — the same convention as the sibling
  `Barkpark.PortableDoc.Render`. A document is

      %{"version" => 1, "title" => "…", "blocks" => [block, …]}

  and a block is `%{"id" => "…", "type" => "…", …}`. A `section` block nests
  the tree under its own `"blocks"` key.

  ## The six ops

  Each op is a map whose `"op"` key is the discriminator:

  | `"op"`          | Required keys        | Effect                                              |
  | --------------- | -------------------- | --------------------------------------------------- |
  | `append-block`  | `"block"`            | Append to the document's **top-level** `blocks`.    |
  | `insert-after`  | `"afterId"`, `"block"` | Insert directly after the block `afterId`.        |
  | `patch-block`   | `"id"`, `"patch"`    | Shallow-merge `patch`; `id` + `type` are immutable. |
  | `replace-block` | `"id"`, `"block"`    | Replace the block `id` wholesale.                   |
  | `remove-block`  | `"id"`               | Remove the block `id` from its parent's `blocks`.   |
  | `move-block`    | `"id"`, `"after"`    | Move the block `id` to just after `after` (or to the front when `after` is `null`). |

  Ids are resolved against the **entire** tree: `insert-after`, `patch-block`,
  `replace-block`, and `remove-block` recurse into `section` children at any
  depth, exactly as patch.ts does. `append-block` is top-level only.

  `move-block` is **top-level only** (the paper editor reorders the top-level
  block list; nested-within-section reorder is not in scope). It is a pure
  permutation — the moved block keeps its identity (same id, same content), so
  it never duplicates content. `"after"` names the block the moved block should
  land directly after; `null` (or absent) moves it to the head. Moving a block
  after itself, or after the block it already follows, is an idempotent no-op.
  Note: `move-block` is a Barkpark-local extension and is **not** part of the
  shared TS portable-doc contract — the TS `applyDocPatch()` does not know it.

  An op MAY also carry an optional `"ifRev"` / `"expectedVersion"` concurrency
  guard. The canonical patch.ts single-op core does not evaluate these (rev
  comparison is a batch/runtime concern that builds on top), so this module
  mirrors that and ignores them — they pass through harmlessly.

  ## Errors

  Mutating ops validate before they mutate and surface failures as tagged
  tuples mirroring patch.ts's `DocPatchError`, consistent with the
  error-return style elsewhere in this namespace:

      {:error, {:block_not_found, target, op}}
      {:error, {:type_mismatch, target, op}}
      {:error, {:duplicate_id, target, op}}
      {:error, {:invalid_op, op_value}}

  where `target` is the offending id (or `afterId`), and `op` is the failing
  op's discriminator string. `:invalid_op` is raised for an unknown or
  malformed op map.
  """

  @type block :: %{required(String.t()) => term()}
  @type blocks :: [block()]
  @type doc :: %{required(String.t()) => term()}
  @type op :: %{required(String.t()) => term()}

  @type error_code :: :block_not_found | :type_mismatch | :duplicate_id
  @type error ::
          {:error, {error_code(), String.t(), String.t()}}
          | {:error, {:invalid_op, term()}}

  @doc """
  Apply a single `op` to a PortableDoc or a bare block list.

  Accepts either a full document map (`%{"blocks" => […]}`) or a plain list of
  blocks. Returns the same shape it was given on success — `{:ok, new_doc}` for
  a document, `{:ok, new_blocks}` for a bare list — or `{:error, reason}`.

  Pure and immutable: the input is never mutated; only the path from the root
  down to the target block is rebuilt (structural sharing), every untouched
  subtree keeps its identity.
  """
  @spec apply_patch(doc(), op()) :: {:ok, doc()} | error()
  @spec apply_patch(blocks(), op()) :: {:ok, blocks()} | error()
  def apply_patch(%{"blocks" => blocks} = doc, op) when is_list(blocks) do
    case apply_to_blocks(blocks, op) do
      {:ok, new_blocks} -> {:ok, Map.put(doc, "blocks", new_blocks)}
      {:error, _} = err -> err
    end
  end

  def apply_patch(blocks, op) when is_list(blocks) do
    apply_to_blocks(blocks, op)
  end

  # ── op dispatch — one clause per discriminator ─────────────────────────────

  defp apply_to_blocks(blocks, %{"op" => "append-block", "block" => block}) do
    if id_exists?(blocks, block_id(block)) do
      {:error, {:duplicate_id, block_id(block), "append-block"}}
    else
      {:ok, blocks ++ [block]}
    end
  end

  defp apply_to_blocks(blocks, %{"op" => "insert-after", "afterId" => after_id, "block" => block}) do
    cond do
      id_exists?(blocks, block_id(block)) ->
        {:error, {:duplicate_id, block_id(block), "insert-after"}}

      true ->
        case transform_at_id(blocks, after_id, fn target -> [target, block] end) do
          nil -> {:error, {:block_not_found, after_id, "insert-after"}}
          new_blocks -> {:ok, new_blocks}
        end
    end
  end

  defp apply_to_blocks(blocks, %{"op" => "patch-block", "id" => id, "patch" => patch})
       when is_map(patch) do
    # Track a type mismatch out-of-band: transform_at_id can only signal
    # found / not-found, so the merge fn records the conflict and leaves the
    # target untouched, and we inspect the flag after the walk — mirroring the
    # `typeMismatch` closure variable in patch.ts.
    {result, mismatch?} =
      transform_with_flag(blocks, id, fn target ->
        # `patch.type` present and differing from the target's type is a
        # mismatch (contract §5); omitting `type` is the common case. A literal
        # `null` is treated as "absent" — it can never re-key the type.
        case Map.get(patch, "type") do
          nil ->
            {[merge_block(target, coerce_field_patch(target, patch))], false}

          patch_type ->
            if patch_type != Map.get(target, "type") do
              {[target], true}
            else
              {[merge_block(target, coerce_field_patch(target, patch))], false}
            end
        end
      end)

    cond do
      result == nil -> {:error, {:block_not_found, id, "patch-block"}}
      mismatch? -> {:error, {:type_mismatch, id, "patch-block"}}
      true -> {:ok, result}
    end
  end

  defp apply_to_blocks(blocks, %{"op" => "replace-block", "id" => id, "block" => block}) do
    case transform_at_id(blocks, id, fn _target -> [block] end) do
      nil -> {:error, {:block_not_found, id, "replace-block"}}
      new_blocks -> {:ok, new_blocks}
    end
  end

  defp apply_to_blocks(blocks, %{"op" => "remove-block", "id" => id}) do
    case transform_at_id(blocks, id, fn _target -> [] end) do
      nil -> {:error, {:block_not_found, id, "remove-block"}}
      new_blocks -> {:ok, new_blocks}
    end
  end

  # move-block — top-level reorder, pure permutation. Lift the block out by id,
  # then splice it back in directly after `after_id` (or at the head when
  # `after_id` is nil). The lifted block keeps its identity + content, so this
  # never duplicates a block. Both the moved id and the (non-nil) anchor must
  # exist at top level; "after itself" is an idempotent no-op.
  defp apply_to_blocks(blocks, %{"op" => "move-block", "id" => id} = op) do
    after_id = Map.get(op, "after")

    cond do
      not Enum.any?(blocks, &(block_id(&1) == id)) ->
        {:error, {:block_not_found, id, "move-block"}}

      after_id == id ->
        # Moving a block after itself is meaningless but harmless.
        {:ok, blocks}

      not is_nil(after_id) and not Enum.any?(blocks, &(block_id(&1) == after_id)) ->
        {:error, {:block_not_found, after_id, "move-block"}}

      true ->
        moved = Enum.find(blocks, &(block_id(&1) == id))
        without = Enum.reject(blocks, &(block_id(&1) == id))

        new_blocks =
          case after_id do
            nil ->
              [moved | without]

            anchor ->
              idx = Enum.find_index(without, &(block_id(&1) == anchor))
              {head, tail} = Enum.split(without, idx + 1)
              head ++ [moved] ++ tail
          end

        {:ok, new_blocks}
    end
  end

  defp apply_to_blocks(_blocks, op) do
    {:error, {:invalid_op, op}}
  end

  # ── id resolution & structural transform (recurses sections) ───────────────

  # True when `id` names any block anywhere in `blocks` (recurses sections),
  # mirroring patch.ts `idExists`.
  defp id_exists?(blocks, id) do
    Enum.any?(blocks, fn block ->
      cond do
        block_id(block) == id -> true
        section?(block) -> id_exists?(Map.get(block, "blocks", []), id)
        true -> false
      end
    end)
  end

  # Transform a block list, applying `fn` to the matching block at any depth.
  #
  # `fn` returns the replacement list for the array slot it was handed (one
  # block in → zero or more out), so a single helper drives patch (1→1),
  # replace (1→1), insert-after (1→2) and remove (1→0).
  #
  # Returns `nil` (distinct from `[]`) when `id` was not found at this level or
  # below, so callers can tell "not found" from "found and removed". Untouched
  # subtrees keep their identity; only the branch containing the target is
  # rebuilt. Mirrors patch.ts `transformAtId`.
  defp transform_at_id(blocks, id, fun) do
    transform_at_id(blocks, id, fun, [])
  end

  defp transform_at_id([], _id, _fun, _acc), do: nil

  defp transform_at_id([block | rest], id, fun, acc) do
    cond do
      block_id(block) == id ->
        Enum.reverse(acc) ++ fun.(block) ++ rest

      section?(block) ->
        case transform_at_id(Map.get(block, "blocks", []), id, fun) do
          nil ->
            transform_at_id(rest, id, fun, [block | acc])

          nested_blocks ->
            next_section = Map.put(block, "blocks", nested_blocks)
            Enum.reverse([next_section | acc]) ++ rest
        end

      true ->
        transform_at_id(rest, id, fun, [block | acc])
    end
  end

  # Variant of `transform_at_id` whose `fun` returns `{replacement_list, flag}`.
  # Returns `{transformed_blocks_or_nil, flag}` — the flag carries out-of-band
  # state (here: a type mismatch) past the walk. The flag defaults to false
  # when the target is never reached.
  defp transform_with_flag(blocks, id, fun) do
    transform_with_flag(blocks, id, fun, [])
  end

  defp transform_with_flag([], _id, _fun, _acc), do: {nil, false}

  defp transform_with_flag([block | rest], id, fun, acc) do
    cond do
      block_id(block) == id ->
        {replacement, flag} = fun.(block)
        {Enum.reverse(acc) ++ replacement ++ rest, flag}

      section?(block) ->
        case transform_with_flag(Map.get(block, "blocks", []), id, fun) do
          {nil, _} ->
            transform_with_flag(rest, id, fun, [block | acc])

          {nested_blocks, flag} ->
            next_section = Map.put(block, "blocks", nested_blocks)
            {Enum.reverse([next_section | acc]) ++ rest, flag}
        end

      true ->
        transform_with_flag(rest, id, fun, [block | acc])
    end
  end

  # ── small helpers ──────────────────────────────────────────────────────────

  # Shallow / replace-by-key merge of `patch` over `target`, then re-pin `id`
  # and `type` so a patch can never mutate the block's identity or kind.
  # Map.merge replaces wholesale per key (arrays/objects are not deep-merged),
  # matching the contract's shallow-merge rule and the JS spread in patch.ts.
  defp merge_block(target, patch) do
    target
    |> Map.merge(patch)
    |> Map.put("id", Map.get(target, "id"))
    |> Map.put("type", Map.get(target, "type"))
  end

  defp section?(block), do: Map.get(block, "type") == "section"

  defp block_id(block), do: Map.get(block, "id")

  # Minimal per-type coercion for field-* LEAF blocks (P2.1). Only the
  # `"value"` key is touched, and only for field-boolean (string "true"/"false"
  # → real bool) so a stringy checkbox value can never land in the store as a
  # binary. All other field types (string/slug/text/select/datetime/color) keep
  # their value as-is — string values are already the right shape. Non-field
  # blocks (rich text, callout, …) are returned untouched, so the P1 path is
  # byte-identical. Full per-type schema validation is a later slice.
  defp coerce_field_patch(%{"type" => "field-boolean"}, patch) do
    case Map.fetch(patch, "value") do
      {:ok, "true"} -> Map.put(patch, "value", true)
      {:ok, "false"} -> Map.put(patch, "value", false)
      _ -> patch
    end
  end

  defp coerce_field_patch(_target, patch), do: patch
end
