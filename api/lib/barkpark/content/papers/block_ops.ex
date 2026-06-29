defmodule Barkpark.Content.Papers.BlockOps do
  @moduledoc """
  Papers — the block-ops / write path, extracted from `Barkpark.Content.Papers`
  (Modularity decomposition: `papers.ex` was a god-module).

  This module owns the four public write functions and their private helpers:

    * `upsert_paper/1` — whole-paper upsert + whole-HTML broadcast.
    * `apply_paper_block_op/4` — single portable-doc op + delta broadcast.
    * `apply_paper_block_ops/4` — atomic batch of ops + one delta broadcast.
    * `apply_document_block_op/5` — generalized block-op for any
      Expectation-bearing document (the Beta block editor's write path).

  `Barkpark.Content.Papers` keeps its public API byte-identical by delegating
  these four functions here. The read-side helpers (`get_paper/3`,
  `resolve_blocks_for_edit/3`) stay in `Papers`; this module calls back to them.
  Behavior is preserved 1:1 from the former in-module implementation.
  """

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Broadcast, Document, DraftId, Encryption, Labels, Sheets}
  alias Barkpark.Content.Papers
  alias Barkpark.PortableDoc.{Patch, Projection, Render}

  @paper_type "paper"
  @paper_default_dataset "production"

  @doc """
  Upsert a paper keyed by `{dataset, slug}` (as a type-"paper" document) and
  broadcast a **whole-HTML** frame on the per-doc topic.

  `attrs` accepts string or atom keys: `slug` (required), and either
  `body_html` OR `blocks`. When `blocks` is given, `body_html` is (re)rendered
  from it as the derived cache. Optionally `dataset`, `source_doc`, `goal_id`,
  `event_type`. The monotonic integer streaming rev (`content["rev"]`) is
  bumped on every write.

  On success, broadcasts `{:paper_updated, %{slug, dataset, html, rev, …}}` to
  `paper_topic(slug, dataset)` and returns `{:ok, %Document{}}`. Returns
  `{:error, changeset}` on validation/constraint failure.
  """
  def upsert_paper(attrs) when is_map(attrs) do
    attrs = normalize_paper_attrs(attrs)
    slug = attrs["slug"]
    dataset = attrs["dataset"] || @paper_default_dataset

    # The pre-write lookup MUST be scoped to THIS write's tenant, not unscoped.
    # An unscoped `get_paper(slug, dataset)` resolves the slug across EVERY
    # workspace (slugs are per-workspace), so a same-slug write in workspace B
    # would find workspace A's row and UPDATE it — re-stamping A's row with B's
    # scope and hijacking A's paper. Scoping the lookup to the write's resolved
    # workspace keeps the two papers DISTINCT, matching the per-workspace
    # uniqueness the Wave-2 index flip established (barkpark-w9dg). The scope is
    # the explicit one in attrs, else the seeded Default — identical to the
    # write-stamp fallback below, so the lookup sees exactly the row the write
    # would update.
    existing = slug && get_existing_paper_for_write(slug, dataset, attrs)

    # Tenancy scope for the row stamp, resolved BEFORE the content build so
    # the sheet-embed hydration below can fetch same-scope sheets (M0a). Same
    # contract as the stamp it feeds (W1.5-C, below): an explicit caller
    # scope ALWAYS wins; a brand-new row falls back to the seeded Default; an
    # UPDATE without an explicit scope resolves to `%{}` (nothing stamped, the
    # existing row's scope preserved) and hydration scopes by the existing row.
    scope_opts = paper_scope_opts(attrs)

    scope_attrs =
      cond do
        scope_opts != [] ->
          Map.delete(Content.put_scope_attrs(%{"dataset" => dataset}, scope_opts), "dataset")

        existing ->
          %{}

        true ->
          Map.delete(Content.put_scope_attrs(%{"dataset" => dataset}, []), "dataset")
      end

    embed_scope =
      if scope_attrs == %{} and existing do
        %{
          "dataset" => dataset,
          "dataset_id" => existing.dataset_id,
          "workspace_id" => existing.workspace_id
        }
      else
        Map.put(scope_attrs, "dataset", dataset)
      end

    # R2 fix (Option A): assign a stable per-block id at INGEST so every block
    # has a UNIQUE "id" before storage/render. Id-less blocks otherwise all
    # collapse to the same LiveView stream/DOM id (`blocks-`), so Phoenix's
    # stream dedupes them and only the LAST block renders in the live <article>.
    # `ensure_block_ids/1` ONLY fills a missing/blank id (positional `block-N`,
    # recursing into sections) — it NEVER overwrites an author/op-supplied id, so
    # DocPatchOp block-addressing (ops target blocks by id) stays stable across
    # ops and re-ingests of the same structure.
    #
    # M0a: hydrate `"sheet"` block snapshots from their referenced sheets at
    # ingest, BEFORE the body_html render below — a paper embedding an
    # EXISTING sheet shows its values on the first read.
    blocks =
      case attrs["blocks"] do
        list when is_list(list) ->
          # Same chokepoint, two normalizers: `ensure_block_ids` fills id-less
          # blocks; `normalize_list_items` coerces legacy flat-STRING list items
          # to the canonical inline-array shape (the obsidian list-item-crash fix)
          # so the canvas's reconstructed shape matches what is stored (no spurious
          # shape-flip patch on load). Both are additive + idempotent + recurse
          # into sections; both are render-preserving.
          list
          |> ensure_block_ids()
          |> normalize_list_items()
          |> Sheets.hydrate_sheet_blocks(embed_scope, slug)

        other ->
          other
      end

    # Field-encryption CHOKEPOINT (Phase 2). Encrypt bound block values for any
    # schema field marked `encrypted: true` BEFORE they are rendered into the
    # body_html cache / projected into content[fieldName] / persisted — so the
    # paper write path stores ciphertext-at-rest exactly like Writer does. Run
    # here (pre-render) rather than only pre-changeset so the rendered body_html
    # (a stored + broadcast surface) redacts the encrypted field instead of
    # leaking plaintext. Projection then copies the envelope into
    # content[fieldName]. Byte-identical no-op when the "paper" schema marks
    # nothing encrypted (or this is an HTML-only, block-less write).
    blocks = encrypt_paper_blocks(blocks, dataset)

    # Per-doc article marker. An ingest/POST may set `style: "article"` in
    # attrs; otherwise it sticks at whatever the existing doc already carries
    # (so a partial update never silently demotes an article paper). Threaded
    # into render_opts so the body_html cache is rendered in the article palette.
    style = Labels.paper_style(attrs, existing)
    render_opts = Labels.paper_render_opts(dataset, style)

    body_html =
      cond do
        is_list(blocks) -> Render.render_blocks(blocks, render_opts)
        is_binary(attrs["body_html"]) -> attrs["body_html"]
        true -> (existing && get_in(existing.content || %{}, ["body_html"])) || ""
      end

    next_rev = paper_next_rev(existing)

    content =
      ((existing && existing.content) || %{})
      |> Map.put("body_html", body_html)
      |> maybe_put_paper("blocks", if(is_list(blocks), do: blocks))
      |> maybe_put_paper("style", style)
      |> maybe_put_paper("source_doc", attrs["source_doc"])
      |> maybe_put_paper("goal_id", attrs["goal_id"])
      |> maybe_put_paper("event_type", attrs["event_type"])
      |> Map.put("rev", next_rev)
      # Project-on-write (Exp-P2): when this write carries a block list, project
      # the bound-field index + content["body"] from it. The SOLE writer of
      # content[fieldName]/content["body"], alongside apply_paper_block_op/3.
      # An HTML-only (legacy) write with no blocks skips projection untouched.
      |> maybe_project(blocks, dataset)

    title = paper_title(content, slug)

    doc_attrs = %{
      "doc_id" => slug,
      "type" => @paper_type,
      "dataset" => dataset,
      "title" => title,
      "status" => "published",
      "content" => content,
      "rev" => generate_rev()
    }

    # Stamp tenancy scope on the paper row. W1.5-C: an ingest/Studio caller MAY
    # thread an explicit workspace/project (via `attrs["workspace_id"]` /
    # `["project_id"]`) — when present it ALWAYS wins, so the surface is ready
    # the moment paper ingest starts sending the goal's scope. Absent it, this
    # falls back to the seeded Default workspace/project (same contract as
    # create_document/4) — without that a NULL-workspace paper is invisible to
    # the now-scoped Studio desk (B8/qucz). An UPDATE only re-stamps when the
    # caller asserted an explicit scope; otherwise `scope_attrs` resolved to
    # `%{}` above and the existing row's scope is preserved.
    doc_attrs = Map.merge(doc_attrs, scope_attrs)

    changeset =
      Document.changeset(existing || %Document{}, doc_attrs)

    result =
      if existing do
        Repo.update(changeset)
      else
        Repo.insert(changeset)
      end

    case result do
      {:ok, doc} ->
        broadcast_paper_update(doc)
        # P6.U1: append a goal-path lifecycle event ALONGSIDE the paper save,
        # gated strictly on a present `event_type` so ordinary streaming saves
        # never create events. The paper save is the source of truth — an
        # event-insert failure is logged and swallowed, never propagated.
        #
        # W1.5-C: the event FOLLOWS the paper's (goal's) scope — stamp it with
        # the saved doc's resolved workspace/project (Default fallback already
        # applied to the doc above) so a goal's events share the goal's scope.
        maybe_append_paper_event(attrs, slug, doc)
        {:ok, doc}

      error ->
        error
    end
  end

  # Append a `paper_events` row when this upsert carries a non-empty
  # `event_type`. Decoupled from Beads/W7 — pure Postgres via
  # `Barkpark.Plugins.Bulldocs.Events`. Failures are logged, never raised.
  #
  # W1.5-C: the event inherits the saved paper document's workspace/project —
  # the paper already resolved Default-fallback (new rows) or kept its existing
  # scope (updates), so the event always lands in the paper/goal's workspace.
  defp maybe_append_paper_event(attrs, slug, %Document{} = doc) do
    event_type = attrs["event_type"]

    if is_binary(event_type) and event_type != "" do
      event_attrs = %{
        "goal_id" => attrs["goal_id"],
        "paper_slug" => slug,
        "event_type" => event_type,
        "source_doc" => attrs["source_doc"],
        "payload_html" => attrs["payload_html"],
        "branch" => attrs["branch"] || "main",
        "workspace_id" => doc.workspace_id,
        "project_id" => doc.project_id
      }

      case Barkpark.Plugins.Bulldocs.Events.create_event(event_attrs) do
        {:ok, _event} ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("paper_events append failed for #{inspect(slug)}: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Apply a single portable-doc `op` (a DocPatchOp map) to a paper's block list,
  persist the new block list + a refreshed `body_html` cache + a bumped
  streaming rev, then broadcast a **delta** frame.

  Flow mirrors the former `Barkpark.Papers.apply_block_op/3`:

    1. Load the paper. Unknown slug ⇒ `{:error, :not_found}`. An HTML-only
       paper seeds an empty block list so the first op can append into it.
    2. Apply via `Barkpark.PortableDoc.Patch.apply_patch/2`.
    3. Render the affected block + refresh the whole `content["body_html"]`.
    4. Persist `content["blocks"]` + `content["body_html"]` + bumped
       `content["rev"]`.
    5. Broadcast `{:paper_block, %{op_kind, block_id, fragment_html, position,
       rev}}` on the per-doc topic.

  Returns `{:ok, %{block:, fragment_html:, op_kind:, block_id:, position:,
  rev:}}` on success.
  """
  def apply_paper_block_op(slug, op, dataset \\ @paper_default_dataset, opts \\ [])
      when is_binary(slug) and is_map(op) do
    with %Document{} = doc <- get_block_op_paper(slug, dataset, opts),
         blocks = get_in(doc.content || %{}, ["blocks"]) || [],
         {:ok, patched} <- Patch.apply_patch(blocks, op),
         # Route the op-applied list through the SAME chokepoint before
         # persisting: a NEW op-inserted block carrying no id (clients normally
         # mint ids, but the op payload is not guaranteed to) would otherwise be
         # stored id-less. `normalize_list_items` likewise canonicalizes any
         # flat-string list item the op carried (the obsidian crash fix). Both are
         # additive + idempotent — they only fill a missing id / coerce a string
         # item, never disturb an op-supplied id or a canonical inline item. Run
         # BEFORE locate so the affected block + fragment_html see the final list.
         new_blocks = patched |> ensure_block_ids() |> normalize_list_items(),
         # Field-encryption CHOKEPOINT (Phase 2): encrypt marked bound block
         # values BEFORE locate/render/project, so the streaming editor stores
         # ciphertext-at-rest and the delta fragment + body_html cache redact the
         # encrypted field. No-op when nothing in the "paper" schema is marked.
         new_blocks = encrypt_paper_blocks(new_blocks, dataset),
         {:ok, affected} <- locate_paper_affected(op, new_blocks) do
      op_kind = Map.get(op, "op")
      rev = paper_next_rev(doc)
      # Carry the doc's stored article marker into the render so both the
      # body_html cache and the delta fragment match the article palette.
      style = get_in(doc.content || %{}, ["style"])
      render_opts = Labels.paper_render_opts(dataset, style)
      body_html = Render.render_blocks(new_blocks, render_opts)

      fragment_html =
        case affected.block do
          nil -> nil
          block -> Render.render_block(block, render_opts)
        end

      content =
        (doc.content || %{})
        |> Map.put("blocks", new_blocks)
        |> Map.put("body_html", body_html)
        |> Map.put("rev", rev)
        # Project-on-write (Exp-P2): the SOLE writer of content[fieldName] and
        # content["body"]. Re-derives the bound-field index + body from the
        # block list we just computed, so Classic queries stay in sync with the
        # blocks and never drift. Threads the PRE-patch `blocks` as old_blocks so
        # an unbind (fieldName→nil) clears the now-orphaned content[fieldName].
        |> Projection.project(blocks, new_blocks, render_opts)

      title = paper_title(content, slug)

      changeset =
        Document.changeset(doc, %{
          "content" => content,
          "title" => title,
          "rev" => generate_rev()
        })

      case Repo.update(changeset) do
        {:ok, _saved} ->
          frame = %{
            op_kind: op_kind,
            block_id: affected.block_id,
            fragment_html: fragment_html,
            position: affected.position,
            rev: rev
          }

          broadcast_paper_block(slug, doc.workspace_id, dataset, frame)

          {:ok,
           %{
             block: affected.block,
             fragment_html: fragment_html,
             op_kind: op_kind,
             block_id: affected.block_id,
             position: affected.position,
             rev: rev
           }}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Apply a LIST of portable-doc ops to a paper's block list **atomically** —
  the batch twin of `apply_paper_block_op/4`.

  All-or-nothing: the ops fold over the paper's block list in order; the FIRST
  op that fails halts the fold and the function returns the error with the
  paper **UNCHANGED** (no Repo write, no rev bump, no broadcast). Only when
  every op applies cleanly is the result persisted **once** (one row update,
  one rev bump) and a single delta frame broadcast.

  Flow:

    1. Load the paper (scoped). Unknown slug ⇒ `{:error, :not_found}`. An
       HTML-only paper seeds an empty block list so the first op can append.
    2. Fold the ops through `Barkpark.PortableDoc.Patch.apply_patch/2`,
       collecting each op's affected block id against the intermediate state.
       Halt + return `{:error, reason}` on the first failure (the same tagged
       tuples `apply_paper_block_op/4` surfaces), leaving the paper untouched.
    3. On full success: render the new block list, refresh the `body_html`
       cache, project-on-write, bump `content["rev"]` once, persist once.
    4. Broadcast one `{:paper_block, …}` delta frame carrying the new rev and
       the list of affected block ids.

  Returns `{:ok, %{slug:, op_count:, rev:, block_ids:}}` on success — the
  MINIMAL batch receipt (no per-op fragment_html). An empty `ops` list is a
  no-op that still loads the paper and returns the receipt at the current rev
  with `op_count: 0` and no block_ids, without writing.
  """
  def apply_paper_block_ops(slug, ops, dataset \\ @paper_default_dataset, opts \\ [])
      when is_binary(slug) and is_list(ops) do
    with %Document{} = doc <- get_block_op_paper(slug, dataset, opts),
         :ok <- check_paper_if_rev(doc, Keyword.get(opts, :if_rev)),
         blocks = get_in(doc.content || %{}, ["blocks"]) || [],
         {:ok, folded, block_ids} <- fold_paper_ops(blocks, ops),
         # Same chokepoint as the single-op path: an op-inserted block lacking an
         # id is filled, and any flat-string list item is canonicalized, before
         # persistence. Both additive + idempotent, so a batch of well-formed
         # (id-bearing, canonical-item) ops is byte-identical through it.
         normalized = folded |> ensure_block_ids() |> normalize_list_items(),
         # Field-encryption CHOKEPOINT (Phase 2): same as the single-op path —
         # encrypt marked bound block values before render/project/persist so the
         # batch write stores ciphertext-at-rest. No-op for an unmarked schema.
         new_blocks = encrypt_paper_blocks(normalized, dataset) do
      cond do
        ops == [] ->
          # Nothing to apply — report the current rev, no write, no broadcast.
          {:ok,
           %{
             slug: slug,
             op_count: 0,
             rev: paper_current_rev(doc),
             block_ids: []
           }}

        true ->
          rev = paper_next_rev(doc)
          style = get_in(doc.content || %{}, ["style"])
          render_opts = Labels.paper_render_opts(dataset, style)
          body_html = Render.render_blocks(new_blocks, render_opts)

          content =
            (doc.content || %{})
            |> Map.put("blocks", new_blocks)
            |> Map.put("body_html", body_html)
            |> Map.put("rev", rev)
            # Pre-patch `blocks` as old_blocks: a batch that unbinds a field
            # clears the orphan content[fieldName]; non-unbind ops ⇒ dropped == [].
            |> Projection.project(blocks, new_blocks, render_opts)

          title = paper_title(content, slug)

          changeset =
            Document.changeset(doc, %{
              "content" => content,
              "title" => title,
              "rev" => generate_rev()
            })

          case Repo.update(changeset) do
            {:ok, _saved} ->
              frame = %{
                op_kind: :batch,
                block_id: List.last(block_ids),
                block_ids: block_ids,
                fragment_html: nil,
                position: nil,
                rev: rev
              }

              broadcast_paper_block(slug, doc.workspace_id, dataset, frame)

              {:ok,
               %{
                 slug: slug,
                 op_count: length(ops),
                 rev: rev,
                 block_ids: block_ids
               }}

            {:error, changeset} ->
              {:error, changeset}
          end
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = err -> err
    end
  end

  # Atomic fold: thread the block list through each op via Patch.apply_patch/2,
  # collecting the affected block id per op against the post-op state. Halts on
  # the first failure (returning that op's tagged error) so a partial batch is
  # never persisted. Affected ids are de-duped while preserving first-seen order.
  defp fold_paper_ops(blocks, ops) do
    Enum.reduce_while(ops, {:ok, blocks, []}, fn op, {:ok, acc, ids} ->
      with {:ok, next} <- Patch.apply_patch(acc, op),
           {:ok, affected} <- locate_paper_affected(op, next) do
        new_ids =
          case affected.block_id do
            nil -> ids
            id -> if id in ids, do: ids, else: ids ++ [id]
          end

        {:cont, {:ok, next, new_ids}}
      else
        {:error, _reason} = err -> {:halt, err}
      end
    end)
  end

  # The CURRENT streaming rev (no bump) — used by the empty-batch no-op receipt.
  defp paper_current_rev(%Document{content: content}) when is_map(content) do
    case Map.get(content, "rev") do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp paper_current_rev(_), do: 0

  # M3 optimistic-concurrency guard. When the caller supplies an `ifRev`, reject
  # the batch BEFORE applying any op unless it matches the paper's current rev.
  # Absent `ifRev` (nil) keeps the prior behaviour (always proceed). The expected
  # value may arrive as an integer or a stringified integer (the wire shape);
  # both are compared against the integer `content["rev"]`.
  defp check_paper_if_rev(_doc, nil), do: :ok

  defp check_paper_if_rev(%Document{} = doc, expected) do
    current = paper_current_rev(doc)

    case normalize_if_rev(expected) do
      :invalid -> {:error, :precondition_failed}
      ^current -> :ok
      _other -> {:error, :precondition_failed}
    end
  end

  defp normalize_if_rev(n) when is_integer(n), do: n

  defp normalize_if_rev(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> :invalid
    end
  end

  defp normalize_if_rev(_), do: :invalid

  @doc """
  Apply a single portable-doc `op` to ANY Expectation-bearing document's block
  list (Exp-P3.2 — the generalization of `apply_paper_block_op/3` off the
  hardcoded `"paper"` type onto an arbitrary `{doc_id, type}`).

  This is the Beta block editor's write path for a non-paper document (a post):
  the same DocPatchOps the paper pane emits (`patch-block`, `insert-after`,
  `append-block`, `remove-block`, `move-block`, `replace-block`) apply to the
  document's `content["blocks"]`, then the content is re-projected
  (`Projection.project/3` — bound blocks → `content[fieldName]`, free blocks →
  `content["body"]`) and persisted through the canonical `upsert_document/4`
  path, which broadcasts `{:doc_updated,…}` + fires lifecycle hooks exactly
  like a Classic save.

  Synthesis-on-first-edit (Exp-P2/P3.1): a document with no stored
  `content["blocks"]` synthesizes its block list in memory via
  `resolve_blocks_for_edit/3`, applies the op to that, and the write persists
  the result — the first Beta edit is what materializes the blocks on disk.

  The block list is the SAME one Classic reads through projection — never a
  separate copy. Returns `{:ok, %{block, block_id, op_kind, position}}` on
  success, mirroring `apply_paper_block_op/3`'s result shape (minus the
  paper-only streaming `rev`/`fragment_html`, which the document editor does
  not stream). `opts` is forwarded to `upsert_document/4` for hook context.
  """
  @spec apply_document_block_op(String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def apply_document_block_op(doc_id, type, op, dataset, opts \\ [])
      when is_binary(doc_id) and is_binary(type) and is_map(op) do
    with {:ok, %Document{} = doc} <- Content.get_document(doc_id, type, dataset, opts),
         {blocks, _synth?} = Papers.resolve_blocks_for_edit(doc, type, dataset),
         {:ok, new_blocks} <- Patch.apply_patch(blocks, op),
         {:ok, affected} <- locate_paper_affected(op, new_blocks) do
      content =
        (doc.content || %{})
        |> Map.put("blocks", new_blocks)
        # Project-on-write — the SOLE writer of content[fieldName]/content["body"]
        # for this document, identical to the paper path. Bound title → "title",
        # free body blocks → content["body"]. Pre-patch `blocks` as old_blocks so
        # a Beta-editor unbind clears the orphaned content[fieldName].
        |> Projection.project(blocks, new_blocks, Labels.render_opts(dataset))

      # Derive the row title from the bound title field if present (matches the
      # Classic-save title precedence), else keep the document's current title.
      new_title = blank_to_nil(Map.get(content, "title")) || doc.title

      attrs = %{
        "doc_id" => DraftId.draft_id(DraftId.published_id(doc_id)),
        "title" => new_title,
        "status" => doc.status,
        "content" => content
      }

      case Content.upsert_document(type, attrs, dataset, opts) do
        {:ok, _saved} ->
          {:ok,
           %{
             block: affected.block,
             block_id: affected.block_id,
             op_kind: Map.get(op, "op"),
             position: affected.position
           }}

        {:error, _} = err ->
          err
      end
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} = err -> err
    end
  end

  # ── Papers — internal ──────────────────────────────────────────────────────

  # Resolve which block an op affected (post-apply) plus its top-level position.
  # Identical to the former Barkpark.Papers.locate_affected/2, except the
  # append/insert clauses now read the STORED block out of `new_blocks` rather
  # than trusting the op payload — so an op whose `block` carried no id reports
  # the id `ensure_block_ids` just minted (the op-fold runs ensure_block_ids over
  # `new_blocks` before this locate), keeping the broadcast frame's block_id and
  # the persisted block in sync.
  defp locate_paper_affected(%{"op" => "append-block", "block" => block}, new_blocks) do
    position = length(new_blocks) - 1
    stored = Enum.at(new_blocks, position) || block
    {:ok, %{block: stored, block_id: Map.get(stored, "id"), position: position}}
  end

  defp locate_paper_affected(%{"op" => "insert-after", "afterId" => after_id} = op, new_blocks) do
    block = Map.get(op, "block") || %{}

    case Map.get(block, "id") do
      id when is_binary(id) and id != "" ->
        {:ok, %{block: block, block_id: id, position: paper_top_level_index(new_blocks, id)}}

      _ ->
        # The op block carried no id — `ensure_block_ids` minted one in
        # `new_blocks`. The inserted block sits directly after `afterId`.
        position =
          case paper_top_level_index(new_blocks, after_id) do
            nil -> nil
            anchor_idx -> anchor_idx + 1
          end

        stored = position && Enum.at(new_blocks, position)

        {:ok,
         %{block: stored || block, block_id: stored && Map.get(stored, "id"), position: position}}
    end
  end

  defp locate_paper_affected(%{"op" => kind, "id" => id}, new_blocks)
       when kind in ["patch-block", "replace-block"] do
    block = paper_find_block(new_blocks, id)
    {:ok, %{block: block, block_id: id, position: paper_top_level_index(new_blocks, id)}}
  end

  defp locate_paper_affected(%{"op" => "remove-block", "id" => id}, _new_blocks) do
    {:ok, %{block: nil, block_id: id, position: nil}}
  end

  # move-block: the moved block kept its id + content; report it at its NEW
  # top-level index so the View-pane stream can re-place it correctly.
  defp locate_paper_affected(%{"op" => "move-block", "id" => id}, new_blocks) do
    block = paper_find_block(new_blocks, id)
    {:ok, %{block: block, block_id: id, position: paper_top_level_index(new_blocks, id)}}
  end

  defp locate_paper_affected(op, _new_blocks), do: {:error, {:invalid_op, op}}

  defp paper_top_level_index(blocks, id) do
    Enum.find_index(blocks, fn b -> Map.get(b, "id") == id end)
  end

  defp paper_find_block(blocks, id) do
    Enum.find_value(blocks, fn block ->
      cond do
        Map.get(block, "id") == id -> block
        Map.get(block, "type") == "section" -> paper_find_block(Map.get(block, "blocks", []), id)
        true -> nil
      end
    end)
  end

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

  @doc """
  Normalize legacy FLAT-STRING list items to the canonical inline-ARRAY shape
  (the obsidian list-item-crash corpus fix).

  ## Why

  The canonical `list` block stores each item as an INLINE ARRAY —
  `%{"type" => "list", "items" => [[%{"type" => "text", "value" => "…"}], …]}`.
  But 7 legacy papers (webhook-* / qstash-* / ga4-* specs) store list items as
  FLAT STRINGS — `"items" => ["text one", "text two"]`. The continuous canvas
  (and the per-block editor) project a list through `convert.js`'s
  `inlineArrayToTiptap`, which runs `.forEach` on each item — a flat string
  THROWS ("forEach is not a function"), crashing BOTH editors the moment such a
  paper opens. `convert.js` now coerces a string item defensively so it never
  throws; this normalizer fixes the STORED data so the editor's reconstructed
  (inline-array) shape matches what is on disk — no spurious shape-flip patch on
  the first canvas load (the same churn the id-less backfill prevents).

  ## Contract

    * **Render-IDENTICAL** — a string item `"x"` becomes
      `[%{"type" => "text", "value" => "x"}]`. `compose.ex` renders BOTH the same
      (`compose_inline_children("x") == compose_inline_children([%{…value=>"x"}])`
      → `["x"]`), so `content["body_html"]` is byte-identical before and after.
      The change is item SHAPE only; item CONTENT (the text) is unchanged.
    * **Additive + idempotent** — a canonical inline-ARRAY item is left BYTE-
      IDENTICAL (the fast path), so re-running over an already-normalized list
      writes nothing. Only a non-array (string / scalar) item is coerced.
    * **Recurses into sections** — exactly like `ensure_block_ids`, it recurses
      into a block's `"blocks"` list (sections) so a list nested in a section is
      normalized too.

  Coverage (the item shapes a list can carry):

    * STRING — `"text"` → `[%{"type" => "text", "value" => "text"}]`.
    * INLINE ARRAY — `[%{"type" => "text", …}]` → unchanged (canonical).
    * other scalar (number) → its string form as one text node.
    * `nil` item → `[]` (an empty list item), never a crash.

  This is routed through the SAME write chokepoints `ensure_block_ids` uses (the
  paper upsert path, the document write path, the op-fold paths, the scaffold),
  so a flat-string list item can never reach storage from a fresh write; the
  backfill Mix task repairs the EXISTING corpus.
  """
  @spec normalize_list_items(list()) :: list()
  def normalize_list_items(blocks) when is_list(blocks) do
    Enum.map(blocks, &normalize_block_list_items/1)
  end

  def normalize_list_items(other), do: other

  # Normalize ONE block. A `list` block has its `items` coerced item-by-item to
  # canonical inline arrays; every other block is untouched EXCEPT for recursion
  # into a nested `"blocks"` container (sections), mirroring ensure_block_ids.
  defp normalize_block_list_items(%{"type" => "list", "items" => items} = block)
       when is_list(items) do
    Map.put(block, "items", Enum.map(items, &normalize_list_item/1))
  end

  defp normalize_block_list_items(block) when is_map(block) do
    case Map.get(block, "blocks") do
      children when is_list(children) ->
        Map.put(block, "blocks", normalize_list_items(children))

      _ ->
        block
    end
  end

  defp normalize_block_list_items(block), do: block

  # Coerce ONE list item to a canonical inline ARRAY. A list (already an inline
  # array) is returned BYTE-IDENTICAL — the idempotent fast path. A binary becomes
  # a single text inline node (render-identical, see the moduledoc). Any other
  # scalar coerces to its string form; nil → an empty item.
  defp normalize_list_item(item) when is_list(item), do: item

  defp normalize_list_item(item) when is_binary(item),
    do: [%{"type" => "text", "value" => item}]

  defp normalize_list_item(nil), do: []

  defp normalize_list_item(item) when is_number(item),
    do: [%{"type" => "text", "value" => to_string(item)}]

  defp normalize_list_item(item), do: item

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

  # `documents.title` is derived, in priority order, from:
  #   1. the PROJECTED bound title field (`content["title"]`) — Exp-P2: a bound
  #      title field-block is the explicit, editor-authored title, so it wins
  #      and the Classic query (Envelope) surfaces it as the row title;
  #   2. the first heading block's text (legacy heading-driven papers);
  #   3. the slug (the desk list always needs a title).
  defp paper_title(content, slug) when is_map(content) do
    blocks = Map.get(content, "blocks")

    heading_text =
      if is_list(blocks) do
        Enum.find_value(blocks, fn b ->
          if Map.get(b, "type") == "heading", do: blank_to_nil(Map.get(b, "text"))
        end)
      end

    blank_to_nil(Map.get(content, "title")) || heading_text || slug
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s
  defp blank_to_nil(_), do: nil

  defp broadcast_paper_update(%Document{} = doc) do
    content = doc.content || %{}

    msg =
      {:paper_updated,
       %{
         slug: doc.doc_id,
         dataset: doc.dataset,
         html: Map.get(content, "body_html"),
         rev: Map.get(content, "rev"),
         source_doc: Map.get(content, "source_doc"),
         goal_id: Map.get(content, "goal_id"),
         event_type: Map.get(content, "event_type")
       }}

    # Workspace-scope the topic (barkpark-n56v): stamp the doc's own
    # workspace_id so the frame only reaches subscribers of THIS tenant. nil
    # (legacy) normalizes to the Default ws inside paper_topic, matching the
    # public viewer's resolved workspace.
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      Broadcast.paper_topic(doc.doc_id, doc.workspace_id, doc.dataset),
      msg
    )
  end

  defp broadcast_paper_block(slug, workspace_id, dataset, frame) do
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      Broadcast.paper_topic(slug, workspace_id, dataset),
      {:paper_block, frame}
    )
  end

  # Allow callers to pass atom OR string keys (controller params are strings,
  # internal callers/tests may use atoms). Stringify, dropping nils.
  defp normalize_paper_attrs(attrs) do
    Enum.reduce(attrs, %{}, fn {k, v}, acc ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      if is_nil(v), do: acc, else: Map.put(acc, key, v)
    end)
  end

  defp maybe_put_paper(map, _key, nil), do: map
  defp maybe_put_paper(map, key, value), do: Map.put(map, key, value)

  # W1.5-C: build [workspace_id: …, project_id: …] from an EXPLICIT scope the
  # caller threaded through paper attrs (string keys, post-normalize). Returns
  # [] when no workspace_id is present — the Default-fallback path then applies.
  # project_id is only meaningful alongside a workspace_id (matches the
  # scope_to_workspace contract).
  defp paper_scope_opts(attrs) do
    case attrs["workspace_id"] do
      ws when is_binary(ws) and ws != "" ->
        case attrs["project_id"] do
          proj when is_binary(proj) and proj != "" -> [workspace_id: ws, project_id: proj]
          _ -> [workspace_id: ws]
        end

      _ ->
        []
    end
  end

  # The pre-write existing-paper lookup, SCOPED to this write's tenant so a
  # same-slug write in workspace B never finds (and clobbers) workspace A's row
  # (barkpark-w9dg). The scope mirrors the write-stamp fallback: an explicit
  # workspace in attrs wins; absent it, the seeded Default workspace — so the
  # flat, unscoped paper ingest keeps upserting its own Default-scoped row.
  defp get_existing_paper_for_write(slug, dataset, attrs) do
    case paper_scope_opts(attrs) do
      [_ | _] = opts ->
        Papers.get_paper(slug, dataset, opts)

      [] ->
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: ws_id} when is_binary(ws_id) ->
            Papers.get_paper(slug, dataset, workspace_id: ws_id)

          # No seeded Default (fresh sandbox) — fall back to the prior unscoped
          # lookup so the very first single-tenant write still self-locates.
          _ ->
            Papers.get_paper(slug, dataset)
        end
    end
  end

  # The block-op doc load, SCOPED so a streaming op never resolves (and mutates)
  # a same-slug paper in another workspace (barkpark-af50). Mirrors the
  # write-side scope contract (get_existing_paper_for_write / get_public_paper):
  # an explicit workspace in opts wins; absent it, the seeded Default workspace
  # — the deterministic public/ingest tenant. Only when no Default is seeded
  # (fresh sandbox) does it fall back to the prior unscoped lookup so a first
  # single-tenant op still self-locates.
  defp get_block_op_paper(slug, dataset, opts) do
    case Keyword.get(opts, :workspace_id) do
      ws when is_binary(ws) and ws != "" ->
        Papers.get_paper(slug, dataset,
          workspace_id: ws,
          project_id: Keyword.get(opts, :project_id)
        )

      _ ->
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: ws_id} when is_binary(ws_id) ->
            Papers.get_paper(slug, dataset, workspace_id: ws_id)

          _ ->
            Papers.get_paper(slug, dataset)
        end
    end
  end

  # Project-on-write only when this write actually carries a block list. An
  # HTML-only legacy paper write (no blocks) leaves content[fieldName]/body
  # untouched — projection is the SOLE writer, so a no-block write must not
  # invent an empty body.
  defp maybe_project(content, blocks, dataset) when is_list(blocks) do
    Projection.project(content, blocks, Labels.render_opts(dataset))
  end

  defp maybe_project(content, _blocks, _dataset), do: content

  # Field-encryption CHOKEPOINT for the paper write path. Encrypt the bound
  # block values of any schema field marked `encrypted: true` by routing the
  # block list through `Encryption.encrypt_marked/3` (its `encrypt_bound_blocks`
  # half). This is the SAME chokepoint Writer uses; running it on the block list
  # BEFORE render+projection means: (a) the body_html cache and delta fragments
  # redact the encrypted field (Render redacts envelope values) instead of
  # leaking plaintext, and (b) Projection copies the resulting envelope into
  # content[fieldName], so content is ciphertext-at-rest by the changeset.
  # Idempotent (re-encrypting an envelope is a no-op) and a byte-identical no-op
  # when the "paper" schema marks nothing encrypted or this is an HTML-only
  # (block-less) write.
  defp encrypt_paper_blocks(blocks, dataset) when is_list(blocks) and is_binary(dataset) do
    %{"blocks" => blocks}
    |> Encryption.encrypt_marked(@paper_type, dataset)
    |> Map.get("blocks", blocks)
  end

  defp encrypt_paper_blocks(blocks, _dataset), do: blocks

  # Next monotonic streaming rev for a paper. Starts at 1 for a fresh paper;
  # increments the stored integer otherwise.
  defp paper_next_rev(nil), do: 1

  defp paper_next_rev(%Document{content: content}) when is_map(content) do
    case Map.get(content, "rev") do
      n when is_integer(n) -> n + 1
      _ -> 1
    end
  end

  defp paper_next_rev(_), do: 1

  # The document's opaque string `rev` (mutation-spine version), distinct from
  # the integer streaming `content["rev"]`. Pure helper duplicated here so the
  # Papers module owns its own row-rev generation without coupling to the hub's
  # private `generate_rev/0` (concern E, Step 13).
  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
