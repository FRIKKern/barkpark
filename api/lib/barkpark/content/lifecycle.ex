defmodule Barkpark.Content.Lifecycle do
  @moduledoc """
  The publish-lifecycle concern (F) — publish / unpublish / discard-draft /
  delete. Each fires its halt-capable `:before_*` hook, performs the draft⇄
  published row moves, and fires the async `:after_*` hook.

  Extracted from `Barkpark.Content` (decomposition Step 13, concern F).
  `Barkpark.Content` keeps facade delegations so every external caller is
  unchanged; reads (`get_document`) are called back through
  `Barkpark.Content.*`, rev generation through `Content.Writer`.

  ## Atomicity + stale-delete races

  The two-row moves (publish/unpublish) and the multi-row delete run inside a
  single `Repo.transaction/1` so a crash between the upsert and the row delete
  can no longer strand a phantom "pending changes" draft. Every row delete uses
  `stale_error_field: :doc_id`, so a row already consumed by a concurrent writer
  surfaces as a changeset error (`stale?/1`) instead of an uncaught
  `Ecto.StaleEntryError` (a 500). The loser of a concurrent publish/unpublish/
  discard therefore gets `{:error, :not_found}` — the winner already moved the
  row. Broadcasts fire AFTER the transaction commits (never inside — see
  `Broadcast`'s deferred-broadcast protocol), preserving the exact
  `tap_broadcast` argument tuples the surfaces depend on.
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

        # Hook stays BEFORE the transaction. NOTE: the pre-existing TOCTOU
        # (two writers both passing the hook before either commits) is only
        # NARROWED by the transaction below, not eliminated — the loser now
        # gets a clean {:error, :not_found} instead of a 500.
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
                    # A stale draft means a concurrent publish already consumed
                    # it — the loser gets {:error, :not_found}, not a 500.
                    case Repo.delete(draft, stale_error_field: :doc_id) do
                      {:ok, _} -> {published, prev_pub_rev}
                      {:error, cs} -> Repo.rollback(if stale?(cs), do: :not_found, else: cs)
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
                    # A stale published row means a concurrent unpublish/delete
                    # already consumed it — the loser gets {:error, :not_found}.
                    case Repo.delete(pub, stale_error_field: :doc_id) do
                      {:ok, _} -> {draft, prev_draft_rev}
                      {:error, cs} -> Repo.rollback(if stale?(cs), do: :not_found, else: cs)
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

        # Single row — no transaction needed. A stale delete means a concurrent
        # writer already removed the draft: report {:error, :not_found}, not 500.
        case Repo.delete(draft, stale_error_field: :doc_id) do
          {:error, cs} ->
            if stale?(cs), do: {:error, :not_found}, else: {:error, cs}

          ok ->
            Broadcast.tap_broadcast(
              ok,
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
                results = Enum.map(docs, &Repo.delete(&1, stale_error_field: :doc_id))

                # A non-stale error means a variant survived — delete must not
                # report success while a row remains, so roll the whole thing back.
                case Enum.find(results, fn
                       {:error, cs} -> not stale?(cs)
                       _ -> false
                     end) do
                  {:error, cs} ->
                    Repo.rollback(cs)

                  nil ->
                    # A stale result on ONE variant while the other deleted is
                    # overall success (the rows are gone). Only if EVERY delete
                    # was stale was the doc already fully gone → :not_found.
                    case Enum.find(results, &match?({:ok, _}, &1)) do
                      nil -> Repo.rollback(:not_found)
                      {:ok, _} = ok -> {ok, target.rev}
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

  # Repo.delete(struct, stale_error_field: :doc_id) turns a would-be
  # Ecto.StaleEntryError into a changeset error tagged `stale: true` in the
  # error opts (default message "is stale"). Match on that tag.
  defp stale?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, error_opts}} -> Keyword.get(error_opts, :stale) == true
      _ -> false
    end)
  end

  defp stale?(_), do: false
end
