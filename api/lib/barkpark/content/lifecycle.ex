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

  alias Barkpark.Repo
  alias Barkpark.Content

  alias Barkpark.Content.{
    Broadcast,
    DedupWall,
    Document,
    DraftId,
    Exemptions,
    LabelSpine,
    Sheets,
    TagRegistry,
    Warnings,
    Writer,
    WriteScope
  }

  # The publish wall (authoring-excellence D1/D6) enforces the label spine on
  # Barkpark's own knowledge types — the corpus the epic exists to keep
  # findable. Deliberately a module attribute, not schema-sniffing: the E4
  # dedup wall scopes to the same pair ("on publish of paper/task types"), and
  # widening the wall to a new type must be a reviewed one-line decision, never
  # an accident of registering a schema. User content types (posts, products,
  # …) publish exactly as before.
  @walled_types ~w(paper task)

  # The 2–4 tag-count norm (advisory FROM BIRTH, never promoted — charter D5).
  @tag_count_norm 2..4

  # TIMED: the publish/lifecycle hot path had ZERO telemetry, so "what is p95 of
  # a publish?" was unanswerable. `:telemetry.span` emits
  # `[:barkpark, :content, :lifecycle, :start | :stop | :exception]` with a
  # `:duration`; BarkparkWeb.Telemetry subscribes a Prometheus histogram to
  # `:stop`, tagged by `:op`, so p95-per-operation (publish/unpublish/
  # discard_draft/delete) is derivable via histogram_quantile. Wraps the whole
  # op — before-hook, transaction, and after-hook — the true caller-visible cost.
  defp span_write(op, fun) do
    :telemetry.span([:barkpark, :content, :lifecycle], %{op: op}, fn ->
      {fun.(), %{op: op}}
    end)
  end

  @doc """
  Publish a document: copy draft content to published ID, delete draft.
  If no draft exists, returns error.

  `opts` accepts `:source` and `:user_id` for lifecycle-hook context.
  Fires `:before_publish` (halt-capable) and `:after_publish` (async).
  """
  def publish_document(published_doc_id, type, dataset, opts \\ []),
    do: span_write(:publish, fn -> do_publish_document(published_doc_id, type, dataset, opts) end)

  defp do_publish_document(published_doc_id, type, dataset, opts) do
    did = DraftId.draft_id(published_doc_id)
    pid = DraftId.published_id(published_doc_id)

    case Content.get_document(did, type, dataset, opts) do
      {:ok, draft} ->
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
        # optional tenant policies). Gates run in charter order:
        #
        #   1. label spine (E1/E2, @walled_types) → 422 {:label_spine, details}
        #   2. tag registry (E3, self-scoping to the weighted-tag shape): every
        #      weighted tags[].tag must resolve to a PUBLISHED type:tag doc in
        #      the dataset scope → 422 {:unknown_tag, …} with trgm-nearest
        #      suggestions
        #   3. dedup wall (E4, @walled_types) → refuse is 409
        #      {:duplicate_of, payload}; the advise band rides the warnings
        #      channel and never blocks
        #
        # An error tuple falls straight out of the `with` — nothing below runs.
        #
        # Exemption is read ONCE at wall entry: a grandfathered (pre-wall) doc
        # passes the WHOLE wall unchanged (D6 — "grandfathered republishes
        # pass unchanged"), including E4: the legacy corpus contains
        # legitimately similar-titled documents, and holding their republishes
        # to the dedup wall would strand them behind each other. The label
        # gate still CLEARS the exemption when the spine passes (the ratchet),
        # so a doc that opts into the new world is walled fully from its NEXT
        # publish on.
        exempt? = type in @walled_types and Exemptions.member?(pid, dataset)

        with :ok <- authoring_wall(draft, type, pid, dataset, exempt?),
             :ok <- TagRegistry.validate_publish(draft, dataset, opts),
             :ok <- dedup_wall(draft, type, dataset, opts, exempt?) do
          # Hook stays BEFORE the transaction. The rev-fenced delete below
          # closes the publish-during-edit TOCTOU: a concurrent write that
          # bumps the draft between the read above and the delete now surfaces
          # a {:error, {:rev_mismatch, …}} (412) instead of silently
          # destroying the newer edit while this stale snapshot publishes.
          case Barkpark.Plugins.Hooks.fire(:before_publish, payload) do
            {:halt, reason} ->
              {:error, {:halted, reason}}

            :ok ->
              # Upsert the published version with draft's content. Inherit the
              # draft's tenancy scope so a publish never drops workspace_id/
              # project_id on the published row.
              pub_attrs =
                %{
                  "doc_id" => pid,
                  "type" => type,
                  "dataset" => dataset,
                  "title" => draft.title,
                  "status" => "published",
                  "content" => draft.content,
                  "rev" => Writer.generate_rev()
                }
                |> WriteScope.inherit_scope_attrs(draft)

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

              result =
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

              # Publishing a SHEET refreshes its PUBLISHED embedders with the
              # now-published content (the draft-save path deliberately skips
              # them — see Sheets.refresh_sheet_embeds). Publish writes the
              # published row directly (not through Writer's upsert tap), so
              # the write-through must be invoked here explicitly.
              Sheets.tap_sheet_writethrough(result)

              WriteScope.fire_after(result, :after_publish, payload)
          end
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # ── the publish wall (authoring-excellence) ────────────────────────────────
  #
  # Gate semantics (charter D6, amended):
  #
  #   * `LabelSpine.validate` PASSES → `Exemptions.clear(pid, dataset)` — the
  #     ratchet shrink: a doc that has once proven itself well-labeled is held
  #     to the wall forever after (stripping the tags back off re-hits it) —
  #     then `:ok`, plus the 2–4 tag-count norm advisory on the warnings
  #     channel when the count is legal but outside the norm.
  #   * validate FAILS → grandfathered (`Exemptions.member?`) publishes pass
  #     unchanged; everything else is the fail-closed 422
  #     (`{:error, {:label_spine, details}}`).
  #
  # Drafts stay free by construction — this runs only on publish. `exempt?` is
  # the grandfathered flag read once at wall entry (see publish_document).
  defp authoring_wall(draft, type, pid, dataset, exempt?) when type in @walled_types do
    case LabelSpine.validate(draft.content) do
      :ok ->
        if exempt?, do: Exemptions.clear(pid, dataset)
        emit_tag_norm_advisory(draft, pid)
        :ok

      {:error, {:label_spine, _details}} = error ->
        if exempt?, do: :ok, else: error
    end
  end

  defp authoring_wall(_draft, _type, _pid, _dataset, _exempt?), do: :ok

  # Advisory, never blocking (charter D5): a legal tag count (1–12) outside
  # the 2–4 norm rides the mutate success envelope as a warning. Emitted only
  # AFTER a validate pass, so the count is known-legal here.
  defp emit_tag_norm_advisory(draft, pid) do
    count = draft.content |> Map.get("tags", []) |> length()

    unless count in @tag_count_norm do
      Warnings.put(
        "label_norm",
        "#{pid}: #{count} tag(s) — the norm is 2–4. " <>
          "Every extra label dilutes the strong ones; weak entries are pruning candidates."
      )
    end
  end

  # E4 dedup wall (charter D4), scoped to the same @walled_types pair as the
  # label spine (the S4 brief's own wording: "on publish of paper/task types" —
  # an unscoped mount would 409 unrelated user content types on title
  # similarity). Refuse → {:error, {:duplicate_of, payload}} (409 with the
  # incumbent published id); the advise band NEVER blocks — its entries ride
  # the mutate success envelope via the warnings channel (D5), each keeping the
  # severity DedupWall stamped ("warning" — a sharper signal than the tag-count
  # norm's "advisory").
  # A grandfathered doc (exempt at wall entry) skips E4 entirely — the legacy
  # corpus predates the dedup rule and holds legitimately similar titles.
  defp dedup_wall(_draft, _type, _dataset, _opts, true), do: :ok

  defp dedup_wall(draft, type, dataset, opts, _exempt?) when type in @walled_types do
    case DedupWall.check(draft, type, dataset, opts) do
      :ok ->
        :ok

      {:ok, warnings} when is_list(warnings) ->
        Enum.each(warnings, &Warnings.put(&1.code, &1.message, &1.severity))
        :ok

      {:error, {:duplicate_of, _payload}} = error ->
        error
    end
  end

  defp dedup_wall(_draft, _type, _dataset, _opts, _exempt?), do: :ok

  @doc """
  Unpublish: move published doc back to draft, delete published version.

  `opts` accepts `:source` and `:user_id`. Fires `:before_unpublish`
  (halt-capable) and `:after_unpublish` (async).
  """
  def unpublish_document(published_doc_id, type, dataset, opts \\ []),
    do:
      span_write(:unpublish, fn -> do_unpublish_document(published_doc_id, type, dataset, opts) end)

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
    do: span_write(:discard_draft, fn -> do_discard_draft(published_doc_id, type, dataset, opts) end)

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
    do: span_write(:delete, fn -> do_delete_document(doc_id, type, dataset, opts) end)

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
