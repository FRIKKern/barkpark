defmodule Barkpark.Content.Lifecycle do
  @moduledoc """
  The publish-lifecycle concern (F) — publish / unpublish / discard-draft /
  delete. Each fires its halt-capable `:before_*` hook, performs the draft⇄
  published row moves, and fires the async `:after_*` hook.

  Extracted from `Barkpark.Content` (decomposition Step 13, concern F).
  `Barkpark.Content` keeps facade delegations so every external caller is
  unchanged; reads (`get_document`) are called back through
  `Barkpark.Content.*`, rev generation through `Content.Writer`.

  ## Atomicity + rev-fenced deletes

  The two-row moves (publish/unpublish) and the multi-row delete run inside a
  single `Repo.transaction/1` so a crash between the upsert and the row delete
  can no longer strand a phantom "pending changes" draft. Every row delete is
  **rev-fenced** (`fenced_delete/1`): it only removes the row if its `rev` still
  matches the one READ at the top of the operation. A bare
  `stale_error_field: :doc_id` delete only fires when the row is GONE, so a
  concurrent write (Studio canvas per-op writes, autosave, a `mutate` patch)
  that bumped the draft between the read and the delete would still succeed —
  silently destroying the newer edits while the stale snapshot published. The
  fence turns that race into a clean `{:error, {:rev_mismatch, %{expected,
  actual}}}` (412) instead: the loser re-fetches and retries. A row that
  vanished entirely (a concurrent delete already consumed it) still resolves to
  `{:error, :not_found}`, preserving the prior loser semantics. Broadcasts fire
  AFTER the transaction commits (never inside — see `Broadcast`'s
  deferred-broadcast protocol), preserving the exact `tap_broadcast` argument
  tuples the surfaces depend on.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Barkpark.Repo
  alias Barkpark.Content

  alias Barkpark.Content.{
    AuthoringWall,
    Broadcast,
    Document,
    DraftId,
    Sheets,
    Writer,
    WriteScope
  }

  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.PortableDoc.Projection
  alias Barkpark.Tasks.Transitions

  # TIMED: the publish/lifecycle hot path had ZERO telemetry, so "what is p95 of
  # a publish?" was unanswerable. `:telemetry.span` emits
  # `[:barkpark, :content, :lifecycle, :start | :stop | :exception]` with a
  # `:duration`; BarkparkWeb.Telemetry subscribes a Prometheus histogram to
  # `:stop`, tagged by `:op`, so p95-per-operation (publish/unpublish/
  # discard_draft/delete) is derivable via histogram_quantile. Wraps the whole
  # op — before-hook, transaction, and after-hook — the true caller-visible cost.
  # `workspace_id` tags the span so per-workspace publish/lifecycle volume is
  # derivable (perfect-plan-build W1, D12). The value rides `opts` via
  # `scope_opts(conn)`; nil (unscoped caller) coerces to "global" so the
  # Prometheus tag is always present and never crashes the reporter handler.
  defp span_write(op, opts, fun) do
    meta = %{op: op, workspace_id: Keyword.get(opts, :workspace_id) || "global"}

    :telemetry.span([:barkpark, :content, :lifecycle], meta, fn ->
      {fun.(), meta}
    end)
  end

  @doc """
  Publish a document: copy draft content to published ID, delete draft.
  If no draft exists, returns error.

  `opts` accepts `:source` and `:user_id` for lifecycle-hook context.
  Fires `:before_publish` (halt-capable) and `:after_publish` (async).
  """
  def publish_document(published_doc_id, type, dataset, opts \\ []),
    do:
      span_write(:publish, opts, fn ->
        do_publish_document(published_doc_id, type, dataset, opts)
      end)

  defp do_publish_document(published_doc_id, type, dataset, opts) do
    did = DraftId.draft_id(published_doc_id)
    pid = DraftId.published_id(published_doc_id)

    case Content.get_document(did, type, dataset, opts) do
      {:ok, draft} ->
        # The publish-door lifecycle gate — immediately after the draft read,
        # BEFORE the wall and the :before_publish hook fire, so a refusal is
        # side-effect-free (the Writer-seam gate-position precedent).
        with {:ok, draft} <- prepare_paper_render_shapes(draft, type),
             :ok <- ensure_bound_title_agrees(draft),
             :ok <- ensure_task_publish_transition_legal(type, draft, pid, dataset, opts) do
          publish_after_gate(draft, pid, type, dataset, opts)
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # THE GATE'S SCOPE DESCENDS FROM THE READER, NOT FROM THE WRITER'S KEY.
  #
  # This used to pattern-match ONLY `%Document{content: %{"blocks" => blocks}}`,
  # so a Paper whose block list lived under `content["body"]["blocks"]` or
  # `content["body"]` — the shape `Projection.project/3` writes and the shape a
  # `bp doc patch --set body:=` author produces — fell to the catch-all and
  # published UNGATED. Same server, same bytes, opposite verdict, decided by
  # which key the writer used. The readers do not care which key it is:
  # `Barkpark.PortableDoc.Projection.read_blocks/1` is the ONE locator the
  # Studio paper reader, the share-link renderer, the content envelope and the
  # body_html rehydrator all go through, and it accepts three STORED locations
  # in this precedence — top-level `"blocks"`, `"body"."blocks"`, `"body"`.
  # The gate now reads through that same locator and normalises back into the
  # location it read from, so the verdict is a property of the CONTENT.
  #
  # The fourth `read_blocks/1` clause — a markdown STRING body — is deliberately
  # out of scope: its block list is synthesised at read time by `FromMarkdown`
  # and never stored, so there is nothing to normalise back into `content` and
  # no authored shape to refuse.
  defp prepare_paper_render_shapes(%Document{content: content} = draft, "paper")
       when is_map(content) do
    cond do
      # A DECLARED but malformed top-level `"blocks"` keeps its pre-existing
      # refusal even when a readable body list sits beside it: the key is a
      # claim about the document, and this arm is strictly a superset of the
      # refusals the key-matched gate already issued. Written as an explicit
      # case because the old arm returned `validate_render_shapes/1`'s BARE
      # `:ok` straight into a `with` that binds `{:ok, draft}` — unreachable
      # today only because that function's catch-all always errors on a
      # non-list, and one edit away from silently returning `:ok` from
      # `publish_document/4` in place of the published document.
      is_map_key(content, "blocks") and not is_list(content["blocks"]) ->
        case BlockOps.validate_render_shapes(content["blocks"]) do
          :ok -> {:ok, draft}
          {:error, _reason} = error -> error
        end

      true ->
        case {Projection.read_blocks(content), paper_block_path(content)} do
          {blocks, path} when is_list(blocks) and is_list(path) ->
            normalized = BlockOps.normalize_render_shapes(blocks)

            case BlockOps.validate_render_shapes(normalized) do
              :ok -> {:ok, %{draft | content: put_in(content, path, normalized)}}
              {:error, _reason} = error -> error
            end

          _ ->
            {:ok, draft}
        end
    end
  end

  defp prepare_paper_render_shapes(draft, _type), do: {:ok, draft}

  # THE PUBLISH-DOOR TITLE-DIVERGENCE REFUSAL.
  #
  # `content["blocks"]` is the SOLE source of every projected `content[fieldName]`
  # on a write that carries a block list: `Writer.maybe_project_document_content/2`
  # re-derives them through `Projection.project/3`, and its own comment states
  # that "projection remains the SOLE writer of the projected keys". The row
  # `title` COLUMN is written OUTSIDE that projection — `Content.Mutations`
  # builds `attrs["title"]` from the patch's `set` map while DROPPING `"title"`
  # from the merged content — so `doc patch <type> <id> --set title=X` on a
  # blocks-bearing document lands the column while the bound title block
  # overwrites `content["title"]` straight back to its create-time value. The
  # patch answers 200 with a freshly bumped `_rev`; only a read of the stored row
  # shows the value was discarded.
  #
  # This gate does not repair that write. It stops the divergence being COPIED
  # ONTO THE PUBLISHED ROW, which is where it stops being recoverable:
  # `publish_after_gate/5` builds `pub_attrs` with `"title" => draft.title` (the
  # column) and `"content" => pub_content` (carrying the stale block/preview
  # title), the generated `search_vector` then indexes BOTH, `doc get` answers
  # one title, and the Studio editor and every preview card read the other. A
  # reader of the published row has no way to tell which of the two the author
  # meant.
  #
  # DELIBERATELY NARROW, so it can only fire on the measured shape:
  #
  #   * only when `content["blocks"]` is a LIST — the exact discriminator the
  #     projector itself keys on. A document the projector never touches cannot
  #     have had a projected key discarded.
  #   * only the block BOUND to `"title"` (`Projection.bound?/1` plus a
  #     `fieldName` of `"title"`), never a FREE `role: "title"` block. A paper's
  #     title block is free, so the paper path is untouched.
  #   * only when both sides are non-blank strings AND they differ. A nil or
  #     blank block value is a cleared index entry (`Projection.projected_value/1`
  #     documents `nil` as exactly that), not two competing titles.
  #
  # It never guesses which side wins. Choosing one would invent an authorial
  # intent the document does not record — the column and the block are equally
  # plausible, and picking silently is the same class of defect as the discard
  # that produced them. So it REFUSES and names both values plus the write that
  # reconciles them.
  #
  # It rides `{:halted, reason}` — the publish door's existing veto vocabulary
  # (`Content.Errors` renders it as a 409 `halted` carrying the reason verbatim:
  # deterministic, terminal, already in the CLI exit-code table and the served
  # OpenAPI `Error.code` enum). A new tag would render as a bare 500
  # `internal_error`, which is the opaque shape this gate exists to end.
  defp ensure_bound_title_agrees(%Document{title: column, content: content})
       when is_map(content) do
    with blocks when is_list(blocks) <- Map.get(content, "blocks"),
         %{} = block <- Enum.find(blocks, &bound_title_block?/1),
         block_title <- Projection.projected_value(block),
         true <- present?(column) and present?(block_title) and column != block_title do
      {:error,
       {:halted,
        "publish refused: this document carries two different titles. The row title column is " <>
          "#{inspect(column)} while the bound title block (and therefore the projected " <>
          "content[\"title\"] and content[\"preview\"]) is #{inspect(block_title)}. " <>
          "Publishing would put both on one row and index both for search, with nothing to say " <>
          "which was meant. `doc patch --set title=` writes the COLUMN ONLY — the block is what " <>
          "projection re-derives the content title from — so set the title through the title " <>
          "block, then publish."}}
    else
      _ -> :ok
    end
  end

  defp ensure_bound_title_agrees(_draft), do: :ok

  defp bound_title_block?(block),
    do: is_map(block) and Projection.bound?(block) and Map.get(block, "fieldName") == "title"

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # The STORED location `Projection.read_blocks/1` would read this content's
  # block list from, in that function's own clause order, or nil when the list
  # is synthesised (markdown body) or absent. Kept adjacent to the gate so the
  # normalised list is written back exactly where the readers look for it —
  # never promoted to a top-level `"blocks"` key the document did not have.
  defp paper_block_path(content) do
    body = Map.get(content, "body")

    cond do
      is_list(Map.get(content, "blocks")) -> ["blocks"]
      is_map(body) and is_list(Map.get(body, "blocks")) -> ["body", "blocks"]
      is_list(body) -> ["body"]
      true -> nil
    end
  end

  defp publish_after_gate(%Document{} = draft, pid, type, dataset, opts) do
    ctx = WriteScope.build_ctx(opts)

    payload = %{
      event: :before_publish,
      doc: draft,
      dataset: dataset,
      prev_doc: draft,
      ctx: ctx
    }

    # The publish wall (authoring-excellence D1): fail-closed enforcement
    # lives in CORE, immediately BEFORE the before_publish hook fire — the
    # hook chain is plugin-droppable and coerces raising hooks to :ok, so
    # it is the wrong home for a correctness gate (the hook stays for
    # optional tenant policies). The whole chain — exemption read ONCE →
    # label spine (E1/E2) → E3 tag registry → E4 dedup → clear-on-full-pass
    # → main_tag stamp — lives in `Barkpark.Content.AuthoringWall` (charter
    # D26: the ONE shared wall, also mounted by BlockOps.upsert_paper for
    # the direct paper-birth path). The delegation is behaviour-identical:
    # the three raw error tuples ({:label_spine, …} 422, {:unknown_tag, …}
    # 422, {:duplicate_of, …} 409) fall straight out of the `with` —
    # nothing below runs, each emitting its telemetry at AuthoringWall's own
    # else seam — and `pub_content` is the draft's content with the D7
    # main_tag stamp applied (put on derivation, DROPPED when stale).
    with {:ok, pub_content} <- AuthoringWall.enforce(draft, type, pid, dataset, opts) do
      # Hook stays BEFORE the transaction. The rev-fenced delete below
      # closes the publish-during-edit TOCTOU: a concurrent write that
      # bumps the draft between the read above and the delete now surfaces
      # a {:error, {:rev_mismatch, …}} (412) instead of silently
      # destroying the newer edit while this stale snapshot publishes.
      case Barkpark.Plugins.Hooks.fire(:before_publish, payload) do
        {:halt, reason} ->
          {:error, {:halted, reason}}

        :ok ->
          # Upsert the published version with draft's content (main_tag
          # denormalized — see AuthoringWall.stamp_main_tag/2, applied to
          # `pub_content` above). Inherit the draft's tenancy scope so a
          # publish never drops workspace_id/project_id on the published row.
          pub_attrs =
            %{
              "doc_id" => pid,
              "type" => type,
              "dataset" => dataset,
              "title" => draft.title,
              "status" => "published",
              "content" => pub_content,
              "rev" => Writer.generate_rev()
            }
            |> WriteScope.inherit_scope_attrs(draft)

          # [acrc-publish-atomicity-txn-boundary] The published upsert, the
          # fenced draft delete AND the `mutation_events` row now share ONE
          # boundary. Before this wrap the `Repo.transaction` below closed and
          # COMMITTED the publish, and only then did `tap_broadcast` insert the
          # event — so a fault there left a published document that no webhook,
          # SSE listener or cache-revalidation consumer ever learned about, with
          # nothing to retry and no error to see on the next request.
          #
          # `write_atomically/1` (not a bare wrap) because `maybe_broadcast/2`
          # DEFERS once a transaction is open: something has to flush the queue
          # on commit and drop it on rollback, or publishing would go silent.
          # The `Repo.transaction` below simply JOINS it; its `Repo.rollback/1`
          # arms (a changeset error, a `:rev_mismatch` from `fenced_delete`)
          # surface as the same `{:error, reason}` this code returned before.
          result =
            Broadcast.write_atomically(fn ->
              txn =
                Repo.transaction(fn ->
                  {pub_result, prev_pub_rev} =
                    case Content.get_document(pid, type, dataset, opts) do
                      {:ok, existing} ->
                        {existing |> Document.changeset(pub_attrs) |> Repo.update(), existing.rev}

                      _ ->
                        {%Document{} |> Document.changeset(pub_attrs) |> Repo.insert(), nil}
                    end

                  case pub_result do
                    {:error, cs} ->
                      Repo.rollback(cs)

                    {:ok, published} ->
                      # Rev-fenced: if a concurrent write bumped the draft since
                      # the read above, delete nothing and surface a rev_mismatch
                      # (412) instead of destroying the newer edit. A vanished
                      # draft resolves to {:error, :not_found} (prior semantics).
                      case fenced_delete(draft) do
                        :ok -> {published, prev_pub_rev}
                        {:error, reason} -> Repo.rollback(reason)
                      end
                  end
                end)

              case txn do
                {:ok, {published, prev_pub_rev}} ->
                  Broadcast.tap_broadcast(
                    {:ok, published},
                    dataset,
                    type,
                    "publish",
                    prev_pub_rev,
                    Keyword.get(opts, :source, :api),
                    Keyword.get(opts, :user_id)
                  )

                {:error, reason} ->
                  {:error, reason}
              end
            end)

          # Publishing a SHEET refreshes its PUBLISHED embedders with the
          # now-published content (the draft-save path deliberately skips
          # them — see Sheets.refresh_sheet_embeds). Publish writes the
          # published row directly (not through Writer's upsert tap), so
          # the write-through must be invoked here explicitly.
          Sheets.tap_sheet_writethrough(result)

          # Publishing a doc that declares `content.supersedes` stamps the
          # predecessor with `superseded_by` (the DedupWall exemption's other
          # half): a correction nobody can find from the row they are reading
          # is not a correction. Best-effort AFTER the publish committed — a
          # stamp failure must never fail the publish that carries the fix.
          tap_supersession_stamp(result, type, dataset, opts)

          WriteScope.fire_after(result, :after_publish, payload)
      end
    else
      # ── THE REFUSAL MUST NOT MANUFACTURE A STRANDED DRAFT ──────────────────
      #
      # `duplicate_of` (E4) is the ONE wall code whose refusal is TERMINAL: it
      # says the content this draft carries is ALREADY PUBLISHED, and it names
      # the incumbent (`payload.duplicate_of`, rendered into the 409 body as
      # `details.duplicate_of` by `Content.Errors`). Leaving the draft behind
      # after that verdict manufactures a `drafts.<id>` row that every
      # canonical reader — `bp task ready`, the board, the epic roster, all
      # published-first — is blind to. 409 such rows had accumulated by the
      # 2026-09-04 census (31 of them carrying a published row's byte-identical
      # title). So the draft is discarded HERE, in the same operation that
      # refused it, and the caller is told where the surviving copy is.
      #
      # THE OTHER FOUR REFUSALS DELIBERATELY KEEP THE DRAFT:
      #
      #   * `label_spine`, `unknown_tag`, `invalid_epic_paper_quality` are
      #     AUTHOR-FIXABLE — the remedy is to edit this draft's tags/content
      #     and republish it. Discarding it would delete the exact work the
      #     refusal is asking the author to correct.
      #   * `dedup_unavailable` is TRANSIENT by construction (`DedupWall`'s
      #     bounded scan could not RUN) — the remedy is to resend, which needs
      #     the draft to still be there.
      #
      # Under `Content.Mutations` this delete is inside the batch transaction
      # and is rolled back with it; `Mutations.compensating_discard/4` re-runs
      # it after the rollback off `payload.refused_draft_id`, so both doors
      # (a direct `publish_document/4` and `POST /v1/data/mutate`) end with no
      # draft. A batch that CREATED the draft in the same transaction needs
      # neither: the rollback already removed it.
      {:error, {:duplicate_of, payload}} ->
        discard_draft_refused_as_duplicate(draft, payload, type, dataset, opts)

      # Every other wall rejection ({:label_spine,…}/{:unknown_tag,…}/
      # {:invalid_epic_paper_quality,…}/{:dedup_unavailable,…}) falls straight
      # out of `AuthoringWall.enforce` UNCHANGED (each shape emitted its
      # telemetry at AuthoringWall's own else seam), and the controllers map it
      # to 422/422/422/503.
      {:error, _reason} = error ->
        error
    end
  end

  # Rev-fenced discard of the draft a `duplicate_of` refusal just rejected.
  # The refusal tuple is returned UNCHANGED except for two additions, both of
  # which `Content.Errors.build/1` keeps out of the wire body
  # (`Map.take(payload, [:duplicate_of, :similar, :advise])`) EXCEPT the
  # message: `:refused_draft_id` is the compensation key `Mutations` reads
  # after a batch rollback, and the message gains the sentence that names what
  # happened to the draft alongside the incumbent that survived.
  #
  # A fenced-delete refusal (a concurrent write bumped the draft, or it already
  # vanished) does NOT become the caller's error: the publish was refused on its
  # merits and that is the answer the caller must see. The draft simply stays,
  # and the census's population is the place that shows it.
  defp discard_draft_refused_as_duplicate(%Document{} = draft, payload, type, dataset, opts) do
    payload = payload |> Map.put(:refused_draft_id, draft.doc_id) |> annotate_discard(draft)

    case fenced_delete(draft) do
      :ok ->
        Broadcast.tap_broadcast(
          {:ok, draft},
          dataset,
          type,
          "discardDraft",
          draft.rev,
          Keyword.get(opts, :source, :api),
          Keyword.get(opts, :user_id)
        )

        {:error, {:duplicate_of, payload}}

      {:error, reason} ->
        Logger.warning(
          "publish refused as duplicate_of but the draft #{draft.doc_id} could not be " <>
            "discarded (#{inspect(reason)}) — it survives the refusal"
        )

        {:error, {:duplicate_of, payload}}
    end
  end

  defp annotate_discard(%{message: message} = payload, %Document{} = draft)
       when is_binary(message) do
    Map.put(
      payload,
      :message,
      message <>
        " The refused draft #{draft.doc_id} was discarded, so this publish left nothing behind; " <>
        "the published document named above is the surviving copy."
    )
  end

  defp annotate_discard(payload, _draft), do: payload

  # ── Supersession stamp (the DedupWall pairwise exemption's other half) ─────
  #
  # A successor that published under `content.supersedes: <doc_id>` marks the
  # predecessor's PUBLISHED row with `superseded_by: <successor id>`, so the
  # pointer is visible from the row being replaced. Best-effort by design:
  # the successor's publish already committed, and refusing/raising here would
  # strand the correction behind bookkeeping — so every miss (no such
  # predecessor, unpublished predecessor, changeset error) logs a warning and
  # returns the publish result unchanged. Idempotent: an already-correct stamp
  # is left untouched (no rev churn on republish).
  defp tap_supersession_stamp({:ok, %Document{} = published} = result, type, dataset, opts) do
    content = if is_map(published.content), do: published.content, else: %{}

    case normalize_supersedes(Map.get(content, "supersedes")) do
      nil ->
        :ok

      target_pid when target_pid == published.doc_id ->
        # Self-supersession is meaningless; never stamp a row as replaced by itself.
        :ok

      target_pid ->
        stamp_superseded_by(target_pid, published.doc_id, type, dataset, opts)
    end

    result
  end

  defp tap_supersession_stamp(result, _type, _dataset, _opts), do: result

  defp normalize_supersedes(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      id -> DraftId.published_id(id)
    end
  end

  defp normalize_supersedes(_), do: nil

  defp stamp_superseded_by(target_pid, successor_pid, type, dataset, opts) do
    case Content.get_document(target_pid, type, dataset, opts) do
      {:ok, %Document{status: "published", content: content} = predecessor} ->
        current = if is_map(content), do: content, else: %{}

        if Map.get(current, "superseded_by") == successor_pid do
          :ok
        else
          prev_rev = predecessor.rev

          attrs = %{
            "content" => Map.put(current, "superseded_by", successor_pid),
            "rev" => Writer.generate_rev()
          }

          case predecessor |> Document.changeset(attrs) |> Repo.update() do
            {:ok, _} = stamped ->
              Broadcast.tap_broadcast(
                stamped,
                dataset,
                type,
                "update",
                prev_rev,
                Keyword.get(opts, :source, :api),
                Keyword.get(opts, :user_id)
              )

              :ok

            {:error, reason} ->
              Logger.warning(
                "supersession stamp failed: could not mark #{target_pid} " <>
                  "superseded_by #{successor_pid}: #{inspect(reason)}"
              )

              :ok
          end
        end

      _ ->
        Logger.warning(
          "supersession stamp skipped: #{successor_pid} declares supersedes " <>
            "#{target_pid}, but no published #{type} row with that id exists in #{dataset}"
        )

        :ok
    end
  end

  # ── The publish-door lifecycle gate (task-lifecycle-visibility, D7/D21) ────
  #
  # `publish_document` bypasses `Content.Writer` entirely and copies the ENTIRE
  # draft content — `lifecycle_status`, `claim`, epoch and all — onto the
  # published row. Proven at L1 (run probe 2026-07-22): claim+close a published
  # task through the SANCTIONED verbs, then republish a coexisting stale open
  # draft → the published row silently reverts done→open and content.claim
  # becomes nil, obliterating the attribution record. The Writer-seam gate
  # (D7b, `Writer.ensure_task_transition_legal/6`) cannot see this door.
  #
  # Contract — mirrors the Writer-seam gate, adapted to the publish seam (the
  # collapse target IS the published row, so `was` is simply its current
  # `lifecycle_status`; no draft-fallback resolution is needed):
  #
  #   * FIRST publish (no published row) is a birth — exempt, including the
  #     importer's legitimately-born-`done` draft.
  #   * `source: :sync` mirrors upstream state verbatim — exempt from the
  #     TRANSITION and CLAIM checks only; the CRITERIA FENCE applies to every
  #     source (see below). `:source` is server-set (MutateController prepends
  #     `source: :api`), so a request body can never reach the exemption.
  #   * a published row with no `lifecycle_status` (legacy / non-task-kind
  #     content) exempts the transition check; the claim check still runs.
  #   * an ILLEGAL implied transition (`Transitions.legal?/2`, the ONE D7
  #     table) is refused naming from, to and the sanctioned verb — e.g.
  #     `open → done` forged through the publish door (a done-carrying draft
  #     can exist legally via `source: :sync`; publishing it may not flip the
  #     published row).
  #   * a TABLE-LEGAL transition can still be a stale-draft RESURRECTION
  #     (`done → open` is legal — the false-done reopen recipe). The staleness
  #     signal is the CLAIM: the published row's claim state is written ONLY by
  #     the sanctioned primitives (claim/renew/pulse/release/close, all
  #     rev-CAS'd), so a draft that does not carry it verbatim predates it —
  #     refused. A draft derived from the CURRENT published content
  #     (patch-then-publish: the met-flip republish flow, the reopen recipe,
  #     the github bookkeeping collapse) carries the claim byte-identical and
  #     passes untouched.
  #   * a CLAIM-IDENTICAL draft can STILL erase evidence (PDS wave 26,
  #     PDS-D360/D362, observed end-to-end): `bp task stamp` writes the
  #     PUBLISHED row directly (`Tasks.Stamp`, `Repo.update_all`) and never
  #     touches the draft twin, and a draft NEVER rebases. So a draft minted
  #     DURING an active claim carries that claim verbatim, sails past
  #     `stale_claim?/2`, and this door then replaces the published content
  #     WHOLESALE — `met: true` becomes `met: false`, evidence becomes `""`,
  #     rc=0, no warning. The second staleness signal is therefore the
  #     ACCEPTANCE CRITERIA themselves: a publish that would clear a
  #     `met: true` flag, blank a non-empty `evidence` string, or drop the row
  #     holding one is refused. Keyed on `acceptance_criteria` ONLY — this is
  #     deliberately NOT a general content diff, so every other field a draft
  #     legitimately rewrites still publishes. Preserving or ADVANCING the
  #     criteria passes; a reopen (`done → open`) that keeps its evidence
  #     passes.
  #
  # Refusals use the `{:invalid_task_content, %{field => [msg]}}` family
  # (→ 422 validation_failed via Content.Errors), NEVER `{:halted, _}` (that
  # shape is reserved for plugin vetoes). EMITTER TWIN:
  # `Writer.illegal_transition_error/2` + `Writer.sanctioned_verb/1` — a
  # contract-shape change must update BOTH seams (the error-emitters-duplicated
  # rule).
  #
  # THE EXACT COVERAGE, re-derived at review rather than assumed (wave 26):
  #
  #   * COVERED — `source: :sync`, for the CRITERIA FENCE only
  #     (pds-bl-sync-source-bypasses-publish-door). The exemption used to be
  #     taken BEFORE any gate ran, so a PULL-applied mirror write could blank a
  #     `met: true` flag or a non-empty evidence string with no guard at all —
  #     strictly worse than the `:api` hole PDS-D362 closed. RULED: the fence
  #     is source-blind, the mirror exemptions are not. Transition + claim
  #     checks stay exempt for `:sync` because a verbatim mirror legitimately
  #     carries upstream's lifecycle (`done → open` reopens, foreign claim
  #     state) — but no LEGITIMATE upstream can need to erase a stamped proof:
  #     every write door upstream (api, github, and now sync itself) refuses
  #     that erasure, so a sync payload that regresses criteria is evidence of
  #     drift or forgery, never of replication. The refusal is safe on the
  #     apply side: `Sync.Applier.error_class/1` classes
  #     `{:invalid_task_content, _}` as :terminal (no retry wedge), and the
  #     Pusher's synthesized publish executes on the REMOTE box through its
  #     MutateController (`source: :api` there), where this same fence already
  #     gates it.
  #   * COVERED, and this is wider than the slice brief assumed — the GitHub
  #     automatic publishers thread `source: :github`, NOT `:sync`
  #     (`plugins/github/link.ex:193` via `mirror_job.ex:560` /
  #     `inbound_events.ex:172`, and `plugins/github/adopt.ex:178`), so they
  #     fall through to this gate and the criteria fence applies to them. That
  #     is the intended direction: `Link.collapse_draft_twin/5` already handles
  #     a rejected collapse without raising or looping — it logs the reason,
  #     leaves the draft twin in place and still returns `{:ok, _}`, and the
  #     next reconcile converges — so a fence refusal degrades to "bookkeeping
  #     deferred", never to a broken mirror. `pds-bl-github-linkput-auto-publish-erasure`
  #     stays open for the audit-trail half it does not answer.
  defp ensure_task_publish_transition_legal("task", %Document{} = draft, pid, dataset, opts) do
    case Content.get_document(pid, "task", dataset, opts) do
      {:ok, %Document{content: pub_content}} ->
        if Keyword.get(opts, :source, :api) == :sync do
          # Mirror-verbatim: transition + claim exempt, criteria fence NOT —
          # see the :sync coverage note above.
          criteria_fence(pub_content || %{}, draft.content || %{})
        else
          gate_task_publish(pub_content || %{}, draft.content || %{})
        end

      _ ->
        # First publish — a birth. Never consult legal?/2 (legal?(nil, x)
        # is false by design and would refuse every first publish).
        :ok
    end
  end

  defp ensure_task_publish_transition_legal(_type, _draft, _pid, _dataset, _opts), do: :ok

  defp gate_task_publish(pub_content, draft_content) do
    was = pub_content["lifecycle_status"]
    now = draft_content["lifecycle_status"]

    cond do
      not (is_nil(was) or Transitions.legal?(was, now)) ->
        {:error, {:invalid_task_content, publish_transition_error(was, now)}}

      stale_claim?(pub_content, draft_content) ->
        {:error, {:invalid_task_content, stale_claim_error(pub_content)}}

      true ->
        criteria_fence(pub_content, draft_content)
    end
  end

  # The criteria fence as a standalone gate: the ONE check that applies to
  # every publish source, `:sync` included (a stamped proof is erasable by no
  # replication payload).
  defp criteria_fence(pub_content, draft_content) do
    case criteria_regression(pub_content, draft_content) do
      nil -> :ok
      regression -> {:error, {:invalid_task_content, criteria_regression_error(regression)}}
    end
  end

  defp stale_claim?(pub_content, draft_content) do
    pub_claim = pub_content["claim"]
    is_map(pub_claim) and map_size(pub_claim) > 0 and draft_content["claim"] != pub_claim
  end

  # The criteria fence. Returns the FIRST regression as
  # `%{index:, criterion:, kind: :dropped | :met | :evidence}`, or nil when the
  # draft preserves (or advances) every proof the published row holds.
  #
  # Only PROOF-BEARING published rows are consulted — `met: true`, or a
  # non-blank `evidence` string. An unmet, evidence-less criterion is free to
  # be reworded, reordered, deleted or added by any draft: authoring a task's
  # criteria list stays a plain content edit right up until a stamp lands on it.
  defp criteria_regression(pub_content, draft_content) do
    draft_list = criteria_list(draft_content)

    pub_content
    |> criteria_list()
    |> Enum.with_index()
    |> Enum.find_value(fn {pub_row, index} -> regression_at(pub_row, index, draft_list) end)
  end

  defp criteria_list(content) do
    case content["acceptance_criteria"] do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp regression_at(pub_row, index, draft_list) when is_map(pub_row) do
    met? = pub_row["met"] == true
    evidence = present_string(pub_row["evidence"])

    if met? or evidence do
      case criteria_counterpart(pub_row, index, draft_list) do
        nil ->
          regression(index, pub_row, :dropped)

        draft_row ->
          cond do
            met? and draft_row["met"] != true ->
              regression(index, pub_row, :met)

            evidence && is_nil(present_string(draft_row["evidence"])) ->
              regression(index, pub_row, :evidence)

            true ->
              nil
          end
      end
    end
  end

  defp regression_at(_pub_row, _index, _draft_list), do: nil

  defp regression(index, pub_row, kind),
    do: %{index: index, criterion: present_string(pub_row["criterion"]), kind: kind}

  # Match the draft's counterpart by criterion TEXT first so a legitimate
  # REORDER carries its stamp along, and fall back to the positional slot (the
  # index a stamp is addressed by) so a legitimate REWORD of an already-met
  # criterion is not mistaken for a drop.
  defp criteria_counterpart(pub_row, index, draft_list) do
    text = present_string(pub_row["criterion"])

    by_text =
      text &&
        Enum.find(draft_list, fn row ->
          is_map(row) and present_string(row["criterion"]) == text
        end)

    case by_text || Enum.at(draft_list, index) do
      row when is_map(row) -> row
      _ -> nil
    end
  end

  defp present_string(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp publish_transition_error(was, now) do
    %{
      "lifecycle_status" => [
        "illegal lifecycle transition #{inspect(was)} → #{inspect(now)}: publishing this " <>
          "draft would rewrite the published row's lifecycle — " <> publish_sanctioned_verb(now)
      ]
    }
  end

  defp stale_claim_error(pub_content) do
    worker = get_in(pub_content, ["claim", "worker"])
    epoch = get_in(pub_content, ["claim", "epoch"])

    %{
      "claim" => [
        "stale draft: the published row carries claim state (worker #{inspect(worker)}, " <>
          "epoch #{inspect(epoch)}) this draft does not — publishing would obliterate it. " <>
          "Re-derive the draft from the published row (patch, then publish), or move the " <>
          "claim through the sanctioned verbs (`bp task claim` / `bp task release` / " <>
          "`bp task close`)."
      ]
    }
  end

  # Twin in shape and intent of `stale_claim_error/1`: name the exact row that
  # would lose its proof, say WHY the draft cannot see it, and name the
  # recovery. A refusal an operator cannot act on is a different bug.
  defp criteria_regression_error(%{index: index, criterion: criterion, kind: kind}) do
    %{
      "acceptance_criteria" => [
        "stale draft: publishing this draft would #{criteria_regression_verb(kind)} for " <>
          "acceptance criterion #{index}#{criterion_label(criterion)} — the published row " <>
          "holds that proof and this draft does not. A stamp is written DIRECTLY to the " <>
          "published row (`bp task stamp`) and never rebases an open draft, so a draft " <>
          "minted before the stamp still carries the pre-stamp criteria. Re-derive the " <>
          "draft from the published row (discard it, patch again, then publish), or move " <>
          "the criterion through the sanctioned verbs (`bp task stamp` / `bp task close`)."
      ]
    }
  end

  defp criteria_regression_verb(:dropped), do: "drop the proof-bearing row"
  defp criteria_regression_verb(:met), do: "clear the `met: true` flag"
  defp criteria_regression_verb(:evidence), do: "blank the recorded evidence"

  defp criterion_label(nil), do: ""
  defp criterion_label(criterion), do: " (#{inspect(String.slice(criterion, 0, 80))})"

  # Names the sanctioned verb per refused target — the refusal TEACHES (the
  # tasks_controller stage/close precedent). Twin of Writer.sanctioned_verb/1.
  defp publish_sanctioned_verb("done"),
    do:
      "`done` is reached only through the close primitive (`bp task close <id> <worker> " <>
        "<epoch>`, POST /v1/tasks/:id/close), which records who closed it."

  defp publish_sanctioned_verb("in_progress"),
    do:
      "a live claim is minted only by the claim primitive (`bp task claim <id> <worker>`, " <>
        "POST /v1/tasks/:id/claim), which fences on the claim epoch."

  defp publish_sanctioned_verb(to) when to in ~w(considering researching),
    do:
      "thought states move through the sanctioned stage verb (`bp task stage <id> #{to}`, " <>
        "POST /v1/tasks/:id/stage), which enforces the same legality table."

  defp publish_sanctioned_verb(_to),
    do:
      "move through the sanctioned task lifecycle verbs instead (`bp task stage` for " <>
        "considering|researching|open, `bp task claim`, `bp task close`)."

  @doc """
  Unpublish: move published doc back to draft, delete published version.

  `opts` accepts `:source` and `:user_id`. Fires `:before_unpublish`
  (halt-capable) and `:after_unpublish` (async).
  """
  def unpublish_document(published_doc_id, type, dataset, opts \\ []),
    do:
      span_write(:unpublish, opts, fn ->
        do_unpublish_document(published_doc_id, type, dataset, opts)
      end)

  defp do_unpublish_document(published_doc_id, type, dataset, opts) do
    pid = DraftId.published_id(published_doc_id)
    did = DraftId.draft_id(published_doc_id)

    case Content.get_document(pid, type, dataset, opts) do
      {:ok, pub} ->
        ctx = WriteScope.build_ctx(opts)

        payload = %{
          event: :before_unpublish,
          doc: pub,
          dataset: dataset,
          prev_doc: pub,
          ctx: ctx
        }

        # Hook stays BEFORE the transaction (see publish_document's TOCTOU note).
        case Barkpark.Plugins.Hooks.fire(:before_unpublish, payload) do
          {:halt, reason} ->
            {:error, {:halted, reason}}

          :ok ->
            # Create draft with published content. Inherit the published row's
            # tenancy scope so an unpublish keeps workspace_id/project_id.
            draft_attrs =
              %{
                "doc_id" => did,
                "type" => type,
                "dataset" => dataset,
                "title" => pub.title,
                "status" => "draft",
                "content" => pub.content,
                "rev" => Writer.generate_rev()
              }
              |> WriteScope.inherit_scope_attrs(pub)

            txn =
              Repo.transaction(fn ->
                {draft_result, prev_draft_rev} =
                  case Content.get_document(did, type, dataset, opts) do
                    {:ok, existing} ->
                      {existing |> Document.changeset(draft_attrs) |> Repo.update(), existing.rev}

                    _ ->
                      {%Document{} |> Document.changeset(draft_attrs) |> Repo.insert(), nil}
                  end

                case draft_result do
                  {:error, cs} ->
                    Repo.rollback(cs)

                  {:ok, draft} ->
                    # Rev-fenced: a concurrent write to the published row since
                    # the read above surfaces a rev_mismatch (412); a vanished
                    # row resolves to {:error, :not_found} (prior semantics).
                    case fenced_delete(pub) do
                      :ok -> {draft, prev_draft_rev}
                      {:error, reason} -> Repo.rollback(reason)
                    end
                end
              end)

            result =
              case txn do
                {:ok, {draft, prev_draft_rev}} ->
                  Broadcast.tap_broadcast(
                    {:ok, draft},
                    dataset,
                    type,
                    "unpublish",
                    prev_draft_rev,
                    Keyword.get(opts, :source, :api),
                    Keyword.get(opts, :user_id)
                  )

                {:error, reason} ->
                  {:error, reason}
              end

            WriteScope.fire_after(result, :after_unpublish, payload)
        end

      error ->
        error
    end
  end

  @doc "Discard a draft without publishing. Published version (if any) remains."
  def discard_draft(published_doc_id, type, dataset, opts \\ []),
    do:
      span_write(:discard_draft, opts, fn ->
        do_discard_draft(published_doc_id, type, dataset, opts)
      end)

  defp do_discard_draft(published_doc_id, type, dataset, opts) do
    did = DraftId.draft_id(published_doc_id)

    case Content.get_document(did, type, dataset, opts) do
      {:ok, draft} ->
        prev_rev = draft.rev

        # Single row — no transaction needed. Rev-fenced: a concurrent write
        # that bumped the draft since the read surfaces a rev_mismatch (412)
        # rather than discarding the newer edit; a vanished row resolves to
        # {:error, :not_found}.
        case fenced_delete(draft) do
          {:error, reason} ->
            {:error, reason}

          :ok ->
            Broadcast.tap_broadcast(
              {:ok, draft},
              dataset,
              type,
              "discardDraft",
              prev_rev,
              Keyword.get(opts, :source, :api),
              Keyword.get(opts, :user_id)
            )
        end

      error ->
        error
    end
  end

  @doc """
  Delete both the published and draft variants of a document.

  `opts` accepts `:source` and `:user_id`. Fires `:before_delete`
  (halt-capable) and `:after_delete` (async). The payload's `:doc` and
  `:prev_doc` carry the about-to-be-deleted document (the published row
  if present, otherwise the draft).
  """
  def delete_document(doc_id, type, dataset, opts \\ []),
    do: span_write(:delete, opts, fn -> do_delete_document(doc_id, type, dataset, opts) end)

  defp do_delete_document(doc_id, type, dataset, opts) do
    pid = DraftId.published_id(doc_id)
    did = DraftId.draft_id(doc_id)

    existing =
      [pid, did]
      |> Enum.map(fn id -> Content.get_document(id, type, dataset, opts) end)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, doc} -> doc end)

    case existing do
      [] ->
        {:error, :not_found}

      [target | _] = docs ->
        ctx = WriteScope.build_ctx(opts)

        payload = %{
          event: :before_delete,
          doc: target,
          dataset: dataset,
          prev_doc: target,
          ctx: ctx
        }

        case Barkpark.Plugins.Hooks.fire(:before_delete, payload) do
          {:halt, reason} ->
            {:error, {:halted, reason}}

          :ok ->
            txn =
              Repo.transaction(fn ->
                # Each variant is fenced against ITS OWN read rev — a concurrent
                # write to either row aborts the whole delete with a rev_mismatch
                # (412) rather than dropping a row the caller no longer intends.
                results = Enum.map(docs, &fenced_delete/1)

                # A rev_mismatch means a variant was concurrently edited — delete
                # must not report success while a live row remains, so roll back.
                case Enum.find(results, &match?({:error, {:rev_mismatch, _}}, &1)) do
                  {:error, {:rev_mismatch, _} = reason} ->
                    Repo.rollback(reason)

                  nil ->
                    # A :not_found on ONE variant while the other deleted is
                    # overall success (the rows are gone). Only if EVERY delete
                    # was :not_found was the doc already fully gone → :not_found.
                    case Enum.find(results, &(&1 == :ok)) do
                      nil -> Repo.rollback(:not_found)
                      :ok -> {{:ok, target}, target.rev}
                    end
                end
              end)

            result =
              case txn do
                {:ok, {ok, prev_rev}} ->
                  Broadcast.tap_broadcast(
                    ok,
                    dataset,
                    type,
                    "delete",
                    prev_rev,
                    Keyword.get(opts, :source, :api),
                    Keyword.get(opts, :user_id)
                  )

                {:error, reason} ->
                  {:error, reason}
              end

            WriteScope.fire_after(result, :after_delete, payload)
        end
    end
  end

  # Rev-fenced delete. Removes the row ONLY if its `rev` still matches the one
  # carried on `doc` (READ at the top of the calling operation). A bare
  # `Repo.delete` with `stale_error_field` fires only when the row is GONE, so a
  # concurrent write that bumped the rev between the read and here would still
  # succeed — destroying the newer edit. The `WHERE id = _ AND rev = _` guard
  # closes that TOCTOU:
  #
  #   * `{1, _}` — the fence held, the row was ours → `:ok`.
  #   * `{0, _}` — the fence failed. Re-read to distinguish:
  #       - row gone      → `{:error, :not_found}` (a concurrent delete won).
  #       - row, new rev  → `{:error, {:rev_mismatch, %{expected, actual}}}`
  #                         (a concurrent write bumped it; errors.ex maps this
  #                         to a 412 precondition_failed).
  #
  # `id` is the physical PK (see `Content.Document`); fencing on it plus `rev`
  # is sufficient — the logical `(doc_id, type, dataset_id)` identity is already
  # pinned by the struct we read.
  defp fenced_delete(%Document{} = doc) do
    case Repo.delete_all(from(d in Document, where: d.id == ^doc.id and d.rev == ^doc.rev)) do
      {1, _} ->
        :ok

      {0, _} ->
        case Repo.get(Document, doc.id) do
          nil ->
            {:error, :not_found}

          %Document{rev: current} ->
            {:error, {:rev_mismatch, %{expected: doc.rev, actual: current}}}
        end
    end
  end
end
