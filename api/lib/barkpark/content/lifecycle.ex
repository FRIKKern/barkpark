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
  alias Barkpark.Content.{Broadcast, Document, DraftId, Writer, WriteScope}

  @doc """
  Publish a document: copy draft content to published ID, delete draft.
  If no draft exists, returns error.

  `opts` accepts `:source` and `:user_id` for lifecycle-hook context.
  Fires `:before_publish` (halt-capable) and `:after_publish` (async).
  """
  def publish_document(published_doc_id, type, dataset, opts \\ []) do
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

        # Hook stays BEFORE the transaction. The rev-fenced delete below closes
        # the publish-during-edit TOCTOU: a concurrent write that bumps the
        # draft between the read above and the delete now surfaces a
        # {:error, {:rev_mismatch, …}} (412) instead of silently destroying the
        # newer edit while this stale snapshot publishes.
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
                    Keyword.get(opts, :source, :api)
                  )

                {:error, reason} ->
                  {:error, reason}
              end

            WriteScope.fire_after(result, :after_publish, payload)
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Unpublish: move published doc back to draft, delete published version.

  `opts` accepts `:source` and `:user_id`. Fires `:before_unpublish`
  (halt-capable) and `:after_unpublish` (async).
  """
  def unpublish_document(published_doc_id, type, dataset, opts \\ []) do
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
                    Keyword.get(opts, :source, :api)
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
  def discard_draft(published_doc_id, type, dataset, opts \\ []) do
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
              Keyword.get(opts, :source, :api)
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
  def delete_document(doc_id, type, dataset, opts \\ []) do
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
                    Keyword.get(opts, :source, :api)
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
          nil -> {:error, :not_found}
          %Document{rev: current} -> {:error, {:rev_mismatch, %{expected: doc.rev, actual: current}}}
        end
    end
  end
end
