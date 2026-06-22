defmodule Barkpark.Content.Sheets do
  @moduledoc false
  # Sheet write-through + embed hydration (concern J), extracted from
  # `Barkpark.Content` which keeps thin wrappers so every caller — the
  # create/upsert write path (concern E) and the paper-ingest block path —
  # is unchanged.
  #
  # ── Sheet embed write-through ───────────────────────────────────────────────
  #
  # A `{"type":"sheet","ref":<sheet doc id>}` block in any document's
  # `content["blocks"]` carries a cached `"snapshot"` — the dense value grid
  # `Barkpark.Plugins.Sheets.Core.snapshot_for/2` synthesizes from the sheet's sparse cells.
  # The snapshot is what keeps the block rendering with the Sheets plugin off
  # (fresh-install invariant), so it must never go stale: every successful save
  # of a `"sheet"` document rewrites the snapshot in all same-scope documents
  # embedding it, in the same logical operation.
  #
  # Targeting is JSONB containment (`content @> {"blocks":[{"type":"sheet",
  # "ref":…}]}`) so the DB returns ONLY embedding rows — the same predicate
  # push-down discipline as `find_referencing_docs/3`, never a full scan.
  # Refreshed docs persist through the direct changeset + `tap_broadcast` tail
  # `disconnect_references/3` uses, so revisions land and PubSub fires for every
  # refreshed doc. The direct path cannot re-enter this trigger (only
  # `create_document/4` / `upsert_document/4` call it), so a sheet embedding
  # another sheet terminates after one refresh level, and the query excludes the
  # sheet's own rows — a sheet never embeds itself.

  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Content.{Broadcast, Document, Labels}
  alias Barkpark.PortableDoc.{Projection, Render}

  import Barkpark.Content.DraftId, only: [draft_id: 1, published_id: 1, draft?: 1]

  # The Sheets formula engine runs in the attrs pipeline of `create_document/4`
  # and `upsert_document/4` so stored content carries computed values; the
  # write-through below projects them into embed snapshots with zero renderer
  # changes. The engine is pure and total: non-sheet types and writes without a
  # "tabs" list pass through untouched.
  def maybe_recompute_sheet_formulas(attrs, "sheet") do
    case Map.get(attrs, "content") do
      %{"tabs" => _} = content ->
        Map.put(attrs, "content", Barkpark.Plugins.Sheets.Engine.recompute(content))

      _ ->
        attrs
    end
  end

  def maybe_recompute_sheet_formulas(attrs, _type), do: attrs

  def tap_sheet_writethrough({:ok, %Document{type: "sheet"} = sheet} = result) do
    refresh_sheet_embeds(sheet)
    result
  end

  def tap_sheet_writethrough(result), do: result

  def refresh_sheet_embeds(%Document{} = sheet) do
    # Match both id forms: papers canonically embed the published id, but the
    # mutated row is (almost always) the draft — and a block authored against
    # the draft id must refresh too.
    pub_id = published_id(sheet.doc_id)
    refs = [pub_id, draft_id(pub_id)]

    sheet
    |> sheet_embed_targets(refs)
    |> Enum.each(&refresh_doc_sheet_snapshots(&1, refs, sheet.content || %{}))
  end

  # Same-scope embedding rows. `dataset_id` is the authoritative scope key when
  # the sheet row carries one (W2); legacy/unscoped rows fall back to the
  # dataset STRING + nil-safe workspace match, so a fresh sandbox without the
  # tenancy backfill still resolves its own scope and never crosses another's.
  def sheet_embed_targets(%Document{} = sheet, refs) do
    [embed_a, embed_b] = Enum.map(refs, &%{"blocks" => [%{"type" => "sheet", "ref" => &1}]})

    base =
      from d in Document,
        where: d.doc_id not in ^refs,
        where:
          fragment("? @> ?", d.content, ^embed_a) or
            fragment("? @> ?", d.content, ^embed_b)

    scoped =
      cond do
        sheet.dataset_id ->
          where(base, [d], d.dataset_id == ^sheet.dataset_id)

        sheet.workspace_id ->
          where(base, [d], d.dataset == ^sheet.dataset and d.workspace_id == ^sheet.workspace_id)

        true ->
          where(base, [d], d.dataset == ^sheet.dataset and is_nil(d.workspace_id))
      end

    Repo.all(scoped)
  end

  def refresh_doc_sheet_snapshots(%Document{} = doc, refs, sheet_content) do
    content = doc.content || %{}
    blocks = Map.get(content, "blocks") || []

    {blocks, changed?} =
      Enum.map_reduce(blocks, false, fn block, changed ->
        if is_map(block) and Map.get(block, "type") == "sheet" and
             Map.get(block, "ref") in refs do
          snapshot =
            Barkpark.Plugins.Sheets.Core.snapshot_for(sheet_content, embed_tab_index(block))

          {Map.put(block, "snapshot", snapshot), true}
        else
          {block, changed}
        end
      end)

    if changed? do
      # Re-derive everything downstream of the refreshed blocks: the paper
      # body_html cache (when the doc carries one — upsert_paper's render of
      # the full block list) and the projected content[fieldName] /
      # content["body"] keys, whose html also embeds the rendered grid.
      # Projection remains the SOLE writer of the projected keys.
      render_opts = Labels.paper_render_opts(doc.dataset, Map.get(content, "style"))

      content =
        case content do
          %{"body_html" => _} ->
            Map.put(content, "body_html", Render.render_blocks(blocks, render_opts))

          _ ->
            content
        end

      content =
        content
        |> Map.put("blocks", blocks)
        |> Projection.project(blocks, render_opts)

      doc
      |> Document.changeset(%{"content" => content, "rev" => generate_rev()})
      |> Repo.update()
      |> Broadcast.tap_broadcast(doc.dataset, doc.type, "update", doc.rev)
    end

    :ok
  end

  def embed_tab_index(block) do
    case Map.get(block, "tab") do
      i when is_integer(i) and i >= 0 -> i
      _ -> 0
    end
  end

  # ── Sheet embed hydration (M0a) ─────────────────────────────────────────────
  #
  # The write-through above keeps embed snapshots fresh when the SHEET saves;
  # this is its mirror for the EMBEDDING side. A document save whose blocks
  # introduce or change `{"type":"sheet","ref":…}` blocks hydrates each
  # block's `"snapshot"` from the referenced sheet IMMEDIATELY — same
  # `Barkpark.Plugins.Sheets.Core.snapshot_for/2` projection, same per-block `"tab"`,
  # same scope ladder — so a paper embedding an EXISTING sheet renders its
  # values on the first read instead of an empty grid until the sheet's next
  # save. ONE batched query fetches every referenced sheet (both id forms,
  # draft preferred — the freshest content, matching what the write-through
  # last projected); a ref that resolves to nothing leaves its block
  # untouched (the renderer keeps the valid empty-grid placeholder), and a
  # self-reference is skipped — the mirror of the write-through's
  # `doc_id not in refs` exclusion, so a sheet embedding itself terminates.
  # Runs pre-write in the attrs pipeline (zero extra writes); a save without
  # sheet blocks costs zero extra queries.

  def hydrate_sheet_embed_snapshots(attrs) do
    content = Map.get(attrs, "content")

    case content && Map.get(content, "blocks") do
      blocks when is_list(blocks) ->
        blocks = hydrate_sheet_blocks(blocks, attrs, Map.get(attrs, "doc_id"))
        Map.put(attrs, "content", Map.put(content, "blocks", blocks))

      _ ->
        attrs
    end
  end

  def hydrate_sheet_blocks(blocks, scope, self_id) do
    self_root = self_id && published_id(self_id)

    refs =
      for %{"type" => "sheet", "ref" => ref} <- blocks,
          is_binary(ref) and ref != "" and published_id(ref) != self_root,
          uniq: true,
          do: published_id(ref)

    case refs do
      [] ->
        blocks

      refs ->
        sheets = fetch_embedded_sheets(refs, scope)

        Enum.map(blocks, fn block ->
          with %{"type" => "sheet", "ref" => ref} when is_binary(ref) <- block,
               %{} = sheet_content <- Map.get(sheets, published_id(ref)) do
            snapshot =
              Barkpark.Plugins.Sheets.Core.snapshot_for(sheet_content, embed_tab_index(block))

            Map.put(block, "snapshot", snapshot)
          else
            _ -> block
          end
        end)
    end
  end

  # Same-scope sheet rows for the refs an embedding doc carries — the reverse
  # of `sheet_embed_targets/2`, same scope ladder (`dataset_id` authoritative,
  # workspace + dataset STRING, then unscoped dataset STRING). Returns a map
  # of published root → sheet content; when a ref has both a draft and a
  # published row the DRAFT wins.
  def fetch_embedded_sheets(refs, scope) do
    ids = refs ++ Enum.map(refs, &draft_id/1)
    dataset = Map.get(scope, "dataset")
    dataset_id = Map.get(scope, "dataset_id")
    workspace_id = Map.get(scope, "workspace_id")

    base = from d in Document, where: d.type == "sheet", where: d.doc_id in ^ids

    scoped =
      cond do
        dataset_id ->
          where(base, [d], d.dataset_id == ^dataset_id)

        workspace_id ->
          where(base, [d], d.dataset == ^dataset and d.workspace_id == ^workspace_id)

        true ->
          where(base, [d], d.dataset == ^dataset and is_nil(d.workspace_id))
      end

    scoped
    |> Repo.all()
    |> Enum.reduce(%{}, fn doc, acc ->
      root = published_id(doc.doc_id)

      if draft?(doc.doc_id) or not Map.has_key?(acc, root) do
        Map.put(acc, root, doc.content || %{})
      else
        acc
      end
    end)
  end

  # Opaque string rev for the mutation spine. Identical to the generator in
  # `Barkpark.Content` (concern E) — a pure, stateless helper; kept local so
  # this module does not depend on E's still-unextracted internals.
  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
