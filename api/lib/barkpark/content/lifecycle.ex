defmodule Barkpark.Content.Lifecycle do
  @moduledoc """
  The publish-lifecycle concern (F) — publish / unpublish / discard-draft /
  delete. Each fires its halt-capable `:before_*` hook, performs the draft⇄
  published row moves, and fires the async `:after_*` hook.

  Extracted from `Barkpark.Content` (decomposition Step 13, concern F).
  `Barkpark.Content` keeps facade delegations so every external caller is
  unchanged; reads (`get_document`) are called back through
  `Barkpark.Content.*`, rev generation through `Content.Writer`.
  """

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

            {pub_result, prev_pub_rev} =
              case Content.get_document(pid, type, dataset, opts) do
                {:ok, existing} ->
                  {existing |> Document.changeset(pub_attrs) |> Repo.update(), existing.rev}

                _ ->
                  {%Document{} |> Document.changeset(pub_attrs) |> Repo.insert(), nil}
              end

            result =
              case pub_result do
                {:ok, published} ->
                  # Delete the draft
                  Repo.delete(draft)

                  Broadcast.tap_broadcast(
                    {:ok, published},
                    dataset,
                    type,
                    "publish",
                    prev_pub_rev,
                    Keyword.get(opts, :source, :api)
                  )

                error ->
                  error
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

            {draft_result, prev_draft_rev} =
              case Content.get_document(did, type, dataset, opts) do
                {:ok, existing} ->
                  {existing |> Document.changeset(draft_attrs) |> Repo.update(), existing.rev}

                _ ->
                  {%Document{} |> Document.changeset(draft_attrs) |> Repo.insert(), nil}
              end

            result =
              case draft_result do
                {:ok, draft} ->
                  Repo.delete(pub)

                  Broadcast.tap_broadcast(
                    {:ok, draft},
                    dataset,
                    type,
                    "unpublish",
                    prev_draft_rev,
                    Keyword.get(opts, :source, :api)
                  )

                error ->
                  error
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

        Repo.delete(draft)
        |> Broadcast.tap_broadcast(
          dataset,
          type,
          "discardDraft",
          prev_rev,
          Keyword.get(opts, :source, :api)
        )

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
            [{first_result, prev_rev} | _] =
              Enum.map(docs, fn doc -> {Repo.delete(doc), doc.rev} end)

            result =
              Broadcast.tap_broadcast(
                first_result,
                dataset,
                type,
                "delete",
                prev_rev,
                Keyword.get(opts, :source, :api)
              )

            WriteScope.fire_after(result, :after_delete, payload)
        end
    end
  end
end
