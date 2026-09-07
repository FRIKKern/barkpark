defmodule Barkpark.Content.BoundFieldSync do
  @moduledoc """
  Write-through from a patched `content[fieldName]` back onto the BOUND block
  projection re-derives that key from — task-d8785cff163c8013.

  ## The hole this closes

  `Writer.maybe_project_document_content/2` re-derives every projected
  `content[fieldName]` from `content["blocks"]` on any whole-document write that
  carries a block list, and `Projection.project/3`'s own contract is that it is
  the SOLE writer of those keys. `Content.Mutations`' two patch clauses
  `Map.merge` a `set` map into the existing content and hand the result to
  `Content.upsert_document/4` — so on a blocks-bearing document the projector
  immediately overwrote the patched value back to the (untouched) bound block's
  value. The mutation answered 200 with a freshly bumped `_rev` and echoed the
  OLD value; only a read of the stored row showed the write was discarded.

  The repair does NOT weaken the projection contract — projection stays the sole
  writer of `content[fieldName]`. It updates the block the projector reads FROM,
  so re-projection reproduces exactly the value the caller set. The bound block,
  the projected index entry and (through `Preview.project/3`, which prefers
  `content["title"]`) `content["preview"]` all land on one value.

  ## Deliberately narrow

    * Only when `content["blocks"]` is a LIST — the same discriminator the
      projector keys on. A document the projector never touches never had a
      value discarded, so a blocks-less type (`author`) passes through
      byte-identical. That is the row's own negative control.
    * Only blocks that are BOUND (`Projection.bound?/1`) and whose `fieldName`
      names a field the patch actually CHANGED. Free blocks — every paper's
      body, and a `role: "title"` heading — are never touched.
    * Only the block's `"value"` key. No block is added, removed, reordered or
      otherwise reshaped, so a document with no bound block for a patched field
      is byte-identical to before.
    * `blocks` / `body` / `preview` / `body_html` are projection OUTPUT, never a
      bound field's index entry, so a difference in them is never a field change.

  The `title` case is separate because `Mutations` DROPS `"title"` from the
  merged content (it addresses the row COLUMN) — so a title change is invisible
  to a content diff and is passed in explicitly. Nothing here writes
  `content["title"]` directly: when a bound title block exists, projection
  derives it from the block this module just updated; when none exists, the
  document has no bound title index entry to keep in sync and is left alone.
  """

  alias Barkpark.PortableDoc.Projection

  # Projection OWNS these keys. They are output, not an authored field value, so
  # a difference in them is never evidence that a caller changed a field.
  @projection_owned ~w(blocks body preview body_html)

  @doc """
  Sync the bound blocks of `merged` so re-projection reproduces the patched
  values.

  `merged` is the post-merge content the patch is about to persist, `prior` the
  document's content BEFORE the patch, and `title` the patch's `set["title"]`
  (or nil when the patch set no title — the column is written elsewhere).

  Returns `merged` unchanged whenever `merged["blocks"]` is not a list, no
  field changed, or no bound block names a changed field. Pure: map operations
  only, no Repo access, no mutation of the inputs.
  """
  @spec sync(term(), term(), term()) :: term()
  def sync(merged, prior, title) when is_map(merged) and is_map(prior) do
    case Map.get(merged, "blocks") do
      blocks when is_list(blocks) -> do_sync(merged, blocks, prior, title)
      _ -> merged
    end
  end

  def sync(merged, _prior, _title), do: merged

  defp do_sync(merged, blocks, prior, title) do
    changed = changed_fields(merged, prior, title)

    if map_size(changed) == 0 do
      merged
    else
      Map.put(merged, "blocks", Enum.map(blocks, &sync_block(&1, changed)))
    end
  end

  # Every key whose value the patch moved, in either direction: a `set` that
  # differs, a `setIfMissing` that filled an absent key, an inc/dec/append/
  # prepend result, and an `unset` (which lands here as nil — exactly the
  # cleared index entry `Projection.projected_value/1` documents).
  defp changed_fields(merged, prior, title) do
    names = Enum.uniq(Map.keys(merged) ++ Map.keys(prior))

    base =
      for name <- names,
          is_binary(name),
          name not in @projection_owned,
          Map.get(merged, name) != Map.get(prior, name),
          into: %{},
          do: {name, Map.get(merged, name)}

    if is_binary(title), do: Map.put(base, "title", title), else: base
  end

  defp sync_block(block, changed) when is_map(block) do
    if Projection.bound?(block) do
      case Map.fetch(changed, Map.get(block, "fieldName")) do
        {:ok, value} -> Map.put(block, "value", value)
        :error -> block
      end
    else
      block
    end
  end

  defp sync_block(block, _changed), do: block
end
