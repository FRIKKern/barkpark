defmodule Barkpark.Content.Papers.Proposals do
  @moduledoc """
  The AI-proposes loop (lvw-t4, living-values v1): an agent-facing write path
  that inserts suggested blocks (typically paragraphs carrying `valueref`
  inline nodes) into a paper as a DRAFT edit, with mandatory provenance —
  never touching the published revision.

  ## The loop, end to end

    1. **Propose** — `propose_paper_blocks/5` applies INSERT-ONLY block ops
       (`append-block` / `insert-after`) to the paper's `drafts.<slug>` twin,
       seeding that draft from the published row on first proposal. The
       published row is NEVER written — "never silently overwrite prose" is
       enforced structurally: mutating op kinds (`patch-block`,
       `replace-block`, `remove-block`) are REJECTED outright.
    2. **Provenance** — every proposal carries a `source` (`doc_id` + `agent`);
       the write records it twice, atomically with the draft edit:
         * a `content_edges` row `draft → source doc` of kind
           `"proposal-source"` (free-string kind — zero migration), pinned to
           the DRAFT row's PK so the publish-gated projector never wipes it;
         * a `content["proposals"][block_id]` sidecar entry, so provenance
           rides the draft's content THROUGH the publish copy and the Bulldocs
           body extractor re-materializes the edge on the PUBLISHED row after
           approval (the draft row — and its cascade-deleted edge — die at
           publish; the sidecar is what survives the gate).
       Unresolvable source ⇒ the WHOLE proposal rolls back (fail closed): no
       draft write, no edge. Provenance is mandatory, not best-effort.
    3. **Review/approve** — the EXISTING draft→publish gate, no new state
       machine: `POST /v1/data/mutate/:dataset {"mutations":[{"publish":
       {"id":"<slug>","type":"paper"}}]}` (`Content.publish_document/4`)
       copies the draft content onto the published row and deletes the draft.
       Rejecting a proposal is the existing `discardDraft` mutation.

  ## Idempotency

  Every proposed block MUST carry an explicit `"id"` — that id is the
  idempotency key. Re-POSTing the same proposal skips ops whose block id
  already exists anywhere in the draft's block list (no duplicate block, no
  spurious rev bump), keeps the first-written provenance sidecar entry
  (`Map.put_new`), and re-upserts the edge (a no-op on the unique
  `(from_id, to_id, kind)` triple).

  Deliberately NOT here (deferred by the living-values spec §6): review UI,
  confidence floats, a proposal state machine, per-op sources, external
  (non-document) provenance targets.
  """

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId, Edges, Encryption, Labels, WriteScope}
  alias Barkpark.Content.Papers
  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.PortableDoc.{Patch, Projection, Render}

  @paper_type "paper"

  # The proposal edge kind — spelled with the noun first so a graph reader
  # scanning kinds sees `proposal-source` next to `valueref`/`references`.
  @edge_kind "proposal-source"

  # Proposals may only INSERT. This allowlist is the "never overwrite prose"
  # keep-sacred rule made structural: no op kind that can touch an existing
  # block is accepted, so a proposal cannot mutate prose even in the DRAFT.
  @insert_op_kinds ~w(append-block insert-after)

  @doc "The edge kind a proposal's provenance edge carries."
  def proposal_edge_kind, do: @edge_kind

  @doc """
  Apply INSERT-ONLY block `ops` to the `drafts.` twin of the paper at `slug`,
  recording provenance from `source` (`%{"doc_id" => …, "agent" => …,
  "note" => optional}`) — atomically: the draft edit, the sidecar and the
  provenance edge commit together or not at all.

  Returns `{:ok, receipt}` where the receipt carries `slug`, `draft_id`,
  `rev` (the draft's streaming rev after the write — unchanged when every op
  was an idempotent replay), `applied_block_ids`, `skipped_block_ids` and
  `provenance` (`%{from, to, kind}`).

  Errors: `{:error, :not_found}` (no published paper at `slug`),
  `{:error, {:invalid_proposal, reason}}` (non-insert op kind / id-less block /
  malformed source), `{:error, :source_not_found}` (source doc unresolvable in
  scope — nothing was written), or a patch/changeset error from the op fold.
  """
  @spec propose_paper_blocks(String.t(), [map()], map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def propose_paper_blocks(slug, ops, source, dataset \\ nil, opts \\ [])
      when is_binary(slug) and is_list(ops) and is_map(source) do
    dataset = dataset || Papers.paper_default_dataset()

    with :ok <- validate_source(source),
         :ok <- validate_ops(ops),
         %Document{} = pub <- get_scoped_paper(slug, dataset, opts) do
      case Repo.transaction(fn -> propose_txn(pub, slug, ops, source, dataset) end) do
        {:ok, receipt} -> {:ok, receipt}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # ── The transactional body ─────────────────────────────────────────────────

  defp propose_txn(pub, slug, ops, source, dataset) do
    draft = get_or_seed_draft(pub, dataset)
    blocks = get_in(draft.content || %{}, ["blocks"]) || []
    existing_ids = collect_block_ids(blocks)

    {replayed, fresh} =
      Enum.split_with(ops, fn op -> MapSet.member?(existing_ids, op_block_id(op)) end)

    skipped_ids = Enum.map(replayed, &op_block_id/1)
    applied_ids = Enum.map(fresh, &op_block_id/1)

    draft =
      case fresh do
        [] -> draft
        fresh -> write_proposed_blocks(draft, blocks, fresh, applied_ids, source, dataset)
      end

    edge = add_provenance_edge(draft, pub, source, dataset)

    %{
      slug: slug,
      draft_id: draft.doc_id,
      rev: current_rev(draft),
      applied_block_ids: applied_ids,
      skipped_block_ids: skipped_ids,
      provenance: %{from: draft.doc_id, to: source["doc_id"], kind: edge.kind}
    }
  end

  # Fold the fresh ops into the draft's block list and persist the draft row —
  # the same normalize → encrypt → render → project chokepoints as the
  # published ops path (`BlockOps.apply_paper_block_ops/4`), minus the
  # broadcast: a draft has no live reader to stream to, and the mutation
  # becomes visible through the drafts perspective + the publish gate.
  defp write_proposed_blocks(draft, blocks, fresh_ops, applied_ids, source, dataset) do
    with {:ok, folded} <- fold_ops(blocks, fresh_ops),
         normalized = folded |> BlockOps.ensure_block_ids() |> BlockOps.normalize_list_items(),
         {:ok, new_blocks} <- encrypt_blocks(normalized, dataset) do
      rev = current_rev(draft) + 1
      style = get_in(draft.content || %{}, ["style"])
      render_opts = Labels.paper_render_opts(dataset, style)
      body_html = Render.render_blocks(new_blocks, render_opts)

      content =
        (draft.content || %{})
        |> Map.put("blocks", new_blocks)
        |> Map.put("body_html", body_html)
        |> Map.put("rev", rev)
        |> Projection.project(blocks, new_blocks, render_opts)
        |> record_provenance(applied_ids, source)

      case draft
           |> Document.changeset(%{"content" => content, "rev" => generate_rev()})
           |> Repo.update() do
        {:ok, saved} -> saved
        {:error, changeset} -> Repo.rollback(changeset)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp fold_ops(blocks, ops) do
    Enum.reduce_while(ops, {:ok, blocks}, fn op, {:ok, acc} ->
      case Patch.apply_patch(acc, op) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # The `content["proposals"]` sidecar: one entry per proposed block id,
  # first-write-wins (`Map.put_new` — an idempotent replay never rewrites the
  # original provenance). This is the half of provenance that SURVIVES the
  # publish gate: `publish_document` copies the draft content verbatim, and
  # `Barkpark.Plugins.Bulldocs.extract_edges/2` re-emits a `proposal-source`
  # edge from it on the published row.
  defp record_provenance(content, applied_ids, source) do
    entry =
      %{
        "source" => source["doc_id"],
        "agent" => source["agent"],
        "proposed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
      |> maybe_put("note", source["note"])

    proposals =
      Enum.reduce(applied_ids, Map.get(content, "proposals", %{}), fn id, acc ->
        Map.put_new(acc, id, entry)
      end)

    Map.put(content, "proposals", proposals)
  end

  # The provenance edge, pinned to the DRAFT row by passing its UUID PK as
  # `from` — `Edges.resolve_doc_pk` resolves a slug published-preferred, so a
  # slug `from` would silently pin the edge to the PUBLISHED row, where the
  # projector's rebuild (DELETE-outbound + re-add from extraction) would wipe
  # it. Hung off the draft PK it lives exactly as long as the proposal does:
  # the projector's corpus is published-only (D1), and both publish and
  # discardDraft delete the draft row, cascading the edge away with it.
  # Unresolvable source ⇒ rollback — provenance is mandatory (fail closed).
  defp add_provenance_edge(draft, pub, source, dataset) do
    attrs =
      %{
        "dataset" => dataset,
        "plugin_source" => "bulldocs-proposal:" <> source["agent"]
      }
      |> maybe_put("workspace_id", pub.workspace_id)

    case Edges.add_edge(draft.id, source["doc_id"], @edge_kind, attrs) do
      {:ok, edge} -> edge
      {:error, :no_target} -> Repo.rollback(:source_not_found)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # Load the paper's draft twin, seeding it from the published row on the
  # first proposal — the same row shape `unpublish_document` creates (content
  # copied verbatim, status "draft", tenancy scope inherited), so the existing
  # publish gate closes the loop without special-casing proposals.
  defp get_or_seed_draft(pub, dataset) do
    case Content.get_document(DraftId.draft_id(pub.doc_id), @paper_type, dataset, []) do
      {:ok, draft} ->
        draft

      {:error, :not_found} ->
        attrs =
          %{
            "doc_id" => DraftId.draft_id(pub.doc_id),
            "type" => @paper_type,
            "dataset" => dataset,
            "title" => pub.title,
            "status" => "draft",
            "content" => pub.content || %{},
            "rev" => generate_rev()
          }
          |> WriteScope.inherit_scope_attrs(pub)

        case %Document{} |> Document.changeset(attrs) |> Repo.insert() do
          {:ok, draft} -> draft
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
  end

  # ── Validation ─────────────────────────────────────────────────────────────

  defp validate_source(source) do
    cond do
      not present?(source["doc_id"]) ->
        {:error, {:invalid_proposal, "source.doc_id (the provenance document) is required"}}

      not present?(source["agent"]) ->
        {:error, {:invalid_proposal, "source.agent (who/what proposed this) is required"}}

      true ->
        :ok
    end
  end

  defp validate_ops([]), do: {:error, {:invalid_proposal, "ops must be a non-empty list"}}

  defp validate_ops(ops) do
    Enum.find_value(ops, :ok, fn op ->
      cond do
        not is_map(op) or Map.get(op, "op") not in @insert_op_kinds ->
          {:error,
           {:invalid_proposal,
            "proposals may only insert (#{Enum.join(@insert_op_kinds, ", ")}) — " <>
              "mutating an existing block would overwrite prose"}}

        not present?(op_block_id(op)) ->
          {:error,
           {:invalid_proposal,
            "every proposed block must carry an explicit id " <>
              "(the idempotency key)"}}

        true ->
          nil
      end
    end)
  end

  defp op_block_id(op) when is_map(op), do: get_in(op, ["block", "id"])
  defp op_block_id(_), do: nil

  # ── Small helpers ──────────────────────────────────────────────────────────

  # Scoped published-paper load, mirroring the block-op writers' contract
  # (`BlockOps.get_block_op_paper/3`): explicit workspace in opts wins, else
  # the seeded Default workspace, else (fresh sandbox) unscoped.
  defp get_scoped_paper(slug, dataset, opts) do
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

  # Every block id in the list, recursing into section children — the
  # idempotency lookup set.
  defp collect_block_ids(blocks) when is_list(blocks) do
    Enum.reduce(blocks, MapSet.new(), fn block, acc ->
      acc =
        case is_map(block) && Map.get(block, "id") do
          id when is_binary(id) and id != "" -> MapSet.put(acc, id)
          _ -> acc
        end

      case is_map(block) && Map.get(block, "blocks") do
        children when is_list(children) -> MapSet.union(acc, collect_block_ids(children))
        _ -> acc
      end
    end)
  end

  defp encrypt_blocks(blocks, dataset) do
    case Encryption.encrypt_marked(%{"blocks" => blocks}, @paper_type, dataset) do
      {:ok, %{"blocks" => encrypted}} -> {:ok, encrypted}
      {:ok, _} -> {:ok, blocks}
      {:error, _} = err -> err
    end
  end

  defp current_rev(%Document{content: content}) when is_map(content) do
    case Map.get(content, "rev") do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp current_rev(_), do: 0

  defp generate_rev, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp present?(v), do: is_binary(v) and v != ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
