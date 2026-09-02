defmodule Barkpark.Content.Papers.BackfillBlockIds do
  @moduledoc """
  Backfill canonical block SHAPE onto LEGACY papers — two passes at ONE
  chokepoint:

    1. **id-less blocks** (R2 corpus fix) — fill a stable `id` on every block
       that lacks one (`ensure_block_ids`).
    2. **flat-string list items** (obsidian list-item-crash fix) — coerce a
       legacy `items:["text", …]` (flat strings) to the canonical inline-array
       `items:[[%{"type"=>"text","value"=>"text"}], …]` (`normalize_list_items`).

  ## Why

  *id-less blocks.* The continuous canvas keys its block diff on each block's
  `id`. A stored block with NO `id` projects to `bpId: null`; on the next edit
  the canvas `runToOps` cannot match it, so it emits a spurious `insert-after`
  (minting a fresh id) → the server inserts DUPLICATE blocks. Editing such a
  paper in the canvas CORRUPTS it.

  *flat-string list items.* The canonical `list` block stores each item as an
  inline ARRAY. 7 legacy papers (webhook-* / qstash-* / ga4-* specs) store flat
  STRINGS. The editors' `convert.js` projection now coerces a string item
  defensively (so neither editor throws), but the editor's reconstructed
  (inline-array) shape no longer matches the STORED (string) shape — so the first
  canvas load would emit a spurious shape-flip patch (churn), exactly like the
  id-less bug. Normalizing the stored data to the canonical inline-array shape
  closes that gap. The normalize is **render-IDENTICAL**: `compose.ex` renders a
  string item and a single-text-inline-array item the same, so `body_html` is
  byte-identical before and after (the data write is provably render-preserving).

  New ingests are already safe — every write path that persists
  `content["blocks"]` now routes through BOTH
  `Barkpark.Content.Papers.BlockOps.ensure_block_ids/1` AND
  `Barkpark.Content.Papers.BlockOps.normalize_list_items/1` (the paper upsert
  path, the document write path covering Sanity-shaped mutations + the legacy
  create controller, the op-fold paths, the scaffold). This module repairs the
  EXISTING corpus that predates those chokepoints.

  ## Contract

  * **Additive only** — it fills an `id` on id-less blocks (absent key, blank
    `""`/`nil`, or nested under a section) and coerces a flat-string list item to
    its inline-array form, and changes NOTHING else: not other blocks' ids, not
    list item CONTENT (the text is identical — only the SHAPE string→inline
    changes), not `content["body_html"]`, not `content["rev"]`, not any projected
    field. Neither pass changes rendered output (ids are not rendered; a string
    item and its inline-array form render identically), so `body_html` stays
    valid and is left untouched.
  * **Idempotent** — re-running over an already-fixed corpus writes nothing (a
    paper is saved only when a pass actually changed its block list).
  * **Tenancy-complete** — it scans ALL `type:"paper"` documents across EVERY
    workspace / project / dataset in one Repo pass (no scope filter), and each
    save preserves the row's own `workspace_id` / `project_id` / `dataset_id`
    columns (only `content` is cast), so a multi-tenant corpus is fully covered.
  * **Minimal save** — only `content["blocks"]` is replaced: no broadcast, no
    re-render, no re-projection, no rev bump, because the change is
    metadata-only and must not re-stream a paper. It is NOT, however, a bare
    `Repo.update/1` any more: the save goes through
    `Barkpark.Content.Revisions.update_document_with_history/3`, so the content
    write and a `revisions` row stamped `action: "migrate:backfill_block_ids"`
    commit in ONE transaction. A sweep over published papers that leaves no
    history entry is exactly what made an accidental clobber indistinguishable
    from a migration.

  ## Usage

  Prefer the Mix task — `mix barkpark.paper.backfill_block_ids` (dry-run by
  default) / `--apply` (writes). The functions here back that task and are the
  unit-test surface.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Barkpark.Repo
  alias Barkpark.Content.Document
  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.Content.Revisions

  @paper_type "paper"

  @type stats :: %{
          scanned: non_neg_integer(),
          changed_papers: non_neg_integer(),
          blocks_filled: non_neg_integer(),
          list_items_normalized: non_neg_integer(),
          dry_run: boolean(),
          changes: [
            %{
              slug: String.t(),
              dataset: String.t(),
              blocks_filled: non_neg_integer(),
              list_items_normalized: non_neg_integer()
            }
          ],
          skipped_duplicates: [
            %{slug: String.t(), dataset: String.t(), duplicate_ids: [String.t()]}
          ]
        }

  @doc """
  Backfill id-less blocks across the WHOLE paper corpus.

  `opts`:

    * `:dry_run` (boolean, default `true`) — when `true`, compute what WOULD
      change and write nothing. The default is SAFE: a bare call never mutates.

  Returns `{:ok, stats}` where `stats` carries `:scanned`, `:changed_papers`,
  `:blocks_filled`, `:list_items_normalized`, `:dry_run`, a `:changes` list (one
  entry per paper that changed, with its slug, dataset, count of ids filled, and
  count of list items normalized), and a `:skipped_duplicates` list (papers whose
  ensured block ids still contained a DUPLICATE — refused, never written; an empty
  list is the healthy case). Idempotent: a second run over a now-fixed corpus
  returns `changed_papers: 0`.
  """
  @spec run(keyword()) :: {:ok, stats()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, true)

    papers = all_papers()

    {changes, blocks_filled, items_normalized, skipped} =
      papers
      |> Enum.reduce({[], 0, 0, []}, fn doc, {changes_acc, filled_acc, items_acc, skipped_acc} ->
        case plan_change(doc) do
          {:change, new_blocks, filled, normalized} ->
            unless dry_run?, do: persist(doc, new_blocks)

            entry = %{
              slug: doc.doc_id,
              dataset: doc.dataset,
              blocks_filled: filled,
              list_items_normalized: normalized
            }

            {[entry | changes_acc], filled_acc + filled, items_acc + normalized, skipped_acc}

          {:duplicate, slug, dataset, dupe_ids} ->
            # NEVER written (a duplicate-id paper is the corruption this fixes).
            # Surfaced in stats so the run reports it loudly, dry-run or not.
            entry = %{slug: slug, dataset: dataset, duplicate_ids: dupe_ids}
            {changes_acc, filled_acc, items_acc, [entry | skipped_acc]}

          :unchanged ->
            {changes_acc, filled_acc, items_acc, skipped_acc}
        end
      end)

    changes = Enum.reverse(changes)
    skipped = Enum.reverse(skipped)

    stats = %{
      scanned: length(papers),
      changed_papers: length(changes),
      blocks_filled: blocks_filled,
      list_items_normalized: items_normalized,
      dry_run: dry_run?,
      changes: changes,
      skipped_duplicates: skipped
    }

    {:ok, stats}
  end

  # Every paper document, UNSCOPED — one pass across all workspaces / projects /
  # datasets. We only need the columns the backfill reads + the scope columns the
  # changeset preserves; selecting the whole struct keeps `Repo.update` simple.
  defp all_papers do
    Repo.all(from(d in Document, where: d.type == @paper_type))
  end

  # Decide whether a paper needs a write. `ensure_block_ids` + `normalize_list_items`
  # are the SAME chokepoints the live write paths use, so the backfill produces a
  # byte-identical result to what an ingest would have. A paper whose block list is
  # unchanged by BOTH passes (no id-less block, no flat-string list item, or no
  # block list at all — an HTML-only paper) is skipped.
  #
  # Order: ids first, then list-item shape. The two passes are independent
  # (ensure_block_ids touches `id`; normalize_list_items touches list `items`),
  # both additive + idempotent + render-preserving.
  #
  # SAFETY NET (prod write). After `ensure_block_ids`, ASSERT that the flattened
  # block ids (top-level + nested) are UNIQUE. ensure_block_ids is collision-safe,
  # so a surviving duplicate indicates a BUG — refuse to save it (a duplicate-id
  # paper is the exact canvas-diff corruption this fix prevents) and surface it
  # loudly so the run reports it instead of silently writing it.
  defp plan_change(%Document{content: content} = doc) when is_map(content) do
    case Map.get(content, "blocks") do
      blocks when is_list(blocks) ->
        id_blocks = BlockOps.ensure_block_ids(blocks)
        new_blocks = BlockOps.normalize_render_shapes(id_blocks)

        cond do
          new_blocks == blocks ->
            :unchanged

          not unique_ids?(id_blocks) ->
            ids = flat_ids(id_blocks)
            dupes = ids -- Enum.uniq(ids)

            Logger.error(
              "backfill_block_ids: REFUSING to save #{inspect(doc.doc_id)} " <>
                "(#{doc.dataset}) — ensure_block_ids left DUPLICATE block ids " <>
                "#{inspect(Enum.uniq(dupes))}; this indicates a bug, paper left untouched"
            )

            {:duplicate, doc.doc_id, doc.dataset, Enum.uniq(dupes)}

          true ->
            {:change, new_blocks, count_filled(blocks, id_blocks), count_string_items(blocks)}
        end

      _ ->
        :unchanged
    end
  end

  defp plan_change(_), do: :unchanged

  # Post-condition: every block id (flattened, incl. nested) is unique.
  defp unique_ids?(blocks) do
    ids = flat_ids(blocks)
    length(ids) == length(Enum.uniq(ids))
  end

  # All block ids, top-level + nested "blocks" containers, flattened in order.
  defp flat_ids(blocks) when is_list(blocks) do
    Enum.flat_map(blocks, fn block ->
      id =
        case is_map(block) && Map.get(block, "id") do
          v when is_binary(v) -> [v]
          _ -> []
        end

      nested =
        case is_map(block) && Map.get(block, "blocks") do
          children when is_list(children) -> flat_ids(children)
          _ -> []
        end

      id ++ nested
    end)
  end

  defp flat_ids(_), do: []

  # Minimal, additive save: replace ONLY content["blocks"], preserving every
  # other content key (body_html, rev, projected fields) and every row column
  # (scope, status, title, rev). No broadcast, no re-render — a direct update.
  defp persist(%Document{content: content} = doc, new_blocks) do
    new_content = Map.put(content, "blocks", new_blocks)

    # HISTORY IS NOT OPTIONAL (task-8d4b1f2c7a0e3591). This was a bare
    # `Repo.update/1`, so a `--apply` sweep rewrote the blocks of every
    # ALREADY-PUBLISHED paper in the corpus and left `bp doc history` showing
    # nothing at all between the last human edit and the rewrite. The write and
    # its revision row now share ONE transaction, so the content cannot commit
    # without the entry that says this task wrote it.
    Revisions.update_document_with_history(doc, %{"content" => new_content},
      action: "migrate:backfill_block_ids"
    )
  end

  # Count how many blocks (top-level + nested) gained an id — the delta between
  # the original list and the ensured list. Used for per-paper + summary logging.
  defp count_filled(old_blocks, new_blocks) do
    idless_count(old_blocks) - idless_count(new_blocks)
  end

  # Number of id-less blocks in a list, recursing into nested "blocks" containers
  # (sections / composites) exactly as ensure_block_ids does, so the delta lines
  # up. A non-blank string id counts as present; absent/blank/nil counts as
  # id-less.
  defp idless_count(blocks) when is_list(blocks) do
    Enum.reduce(blocks, 0, fn block, acc ->
      acc + block_idless(block) + nested_idless(block)
    end)
  end

  defp idless_count(_), do: 0

  defp block_idless(block) when is_map(block) do
    case Map.get(block, "id") do
      id when is_binary(id) and id != "" -> 0
      _ -> 1
    end
  end

  defp block_idless(_), do: 0

  defp nested_idless(block) when is_map(block) do
    case Map.get(block, "blocks") do
      children when is_list(children) -> idless_count(children)
      _ -> 0
    end
  end

  defp nested_idless(_), do: 0

  # Count how many list items are FLAT (non-inline-array — string / scalar) across
  # a block list, recursing into nested "blocks" containers (sections) exactly as
  # normalize_list_items does, so the per-paper count reflects every item the
  # normalize would coerce. A canonical inline-ARRAY item counts as 0.
  defp count_string_items(blocks) when is_list(blocks) do
    Enum.reduce(blocks, 0, fn block, acc ->
      acc + list_string_items(block) + nested_string_items(block)
    end)
  end

  defp count_string_items(_), do: 0

  defp list_string_items(%{"type" => "list", "items" => items}) when is_list(items) do
    Enum.count(items, fn item -> not is_list(item) end)
  end

  defp list_string_items(_), do: 0

  defp nested_string_items(block) when is_map(block) do
    case Map.get(block, "blocks") do
      children when is_list(children) -> count_string_items(children)
      _ -> 0
    end
  end

  defp nested_string_items(_), do: 0

  @doc """
  Log a one-line summary plus a per-paper line for each changed paper. Used by
  the Mix task; pure (no DB) so the run/1 result drives reporting.
  """
  @spec log_report(stats(), (String.t() -> any())) :: :ok
  def log_report(%{} = stats, emit) when is_function(emit, 1) do
    mode = if stats.dry_run, do: "DRY-RUN (no writes)", else: "APPLY (writes)"

    emit.("paper block backfill — #{mode}")
    emit.("  papers scanned:        #{stats.scanned}")
    emit.("  papers changed:        #{stats.changed_papers}")
    emit.("  block ids added:       #{stats.blocks_filled}")
    emit.("  list items normalized: #{Map.get(stats, :list_items_normalized, 0)}")

    Enum.each(stats.changes, fn c ->
      ids = "#{c.blocks_filled} id(s) added"
      items = "#{Map.get(c, :list_items_normalized, 0)} list item(s) normalized"
      emit.("    • #{c.slug} (#{c.dataset}) — #{ids}, #{items}")
    end)

    skipped = Map.get(stats, :skipped_duplicates, [])

    if skipped != [] do
      emit.("  !! REFUSED (duplicate ids survived ensure_block_ids — BUG): #{length(skipped)}")

      Enum.each(skipped, fn s ->
        emit.("    ✗ #{s.slug} (#{s.dataset}) — duplicate id(s) #{inspect(s.duplicate_ids)}")
      end)
    end

    :ok
  end
end
