defmodule Barkpark.Content.Mutations do
  @moduledoc """
  The batch-mutation concern (H) — `apply_mutations/2` wraps the per-mutation
  `apply_one` dispatch in a `Repo.transaction`, driving broadcast-deferral:
  PubSub frames queued inside the transaction are flushed after a successful
  commit and discarded on rollback (no ghost SSE events on a failed batch).

  Extracted from `Barkpark.Content` (decomposition Step 13, concern H).
  `Barkpark.Content` keeps facade delegations so every external caller is
  unchanged; the per-mutation write/publish primitives are called back through
  `Barkpark.Content.*`, rev generation through `Content.Writer`, deferral
  through `Content.Broadcast`.
  """

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Broadcast, DraftId, Envelope, Writer}

  @doc """
  Apply a batch of mutations atomically. Returns `{:ok, {transaction_id, results}}`
  or `{:error, reason}` with rollback on any failure.

  `opts` accepts `:source` and `:user_id` and is threaded into every
  per-mutation Content call so lifecycle-hook context (`ctx.source`,
  `ctx.user_id`) is set correctly for each fired hook.

  PubSub broadcasts queued inside the transaction are flushed AFTER a
  successful commit, and discarded on rollback — no ghost events on
  the SSE stream when a batch fails partway through.
  """
  def apply_mutations(mutations, dataset, opts \\ []) when is_list(mutations) do
    # Initialise the deferred-broadcast queue for this process so
    # tap_broadcast/5 knows to queue instead of broadcast immediately.
    Process.put(:barkpark_deferred_broadcasts, [])

    try do
      result =
        Repo.transaction(fn ->
          tx_id = Writer.generate_rev()

          results =
            Enum.map(mutations, fn m ->
              case apply_one(m, dataset, opts) do
                {:ok, doc, op} -> %{id: doc.doc_id, operation: op, document: Envelope.render(doc)}
                {:error, reason} -> Repo.rollback(reason)
              end
            end)

          {tx_id, results}
        end)

      case result do
        {:ok, _} ->
          Broadcast.flush_deferred_broadcasts()
          result

        _ ->
          Broadcast.clear_deferred_broadcasts()
          result
      end
    rescue
      e ->
        Broadcast.clear_deferred_broadcasts()
        reraise(e, __STACKTRACE__)
    end
  end

  defp apply_one(%{"create" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    # A create must NOT overwrite an existing draft. Skip the lookup when
    # type/id are missing — let create_document/3 surface a validation error
    # (Ecto rejects nil equality comparisons in queries).
    existing =
      if id && type do
        case Content.get_document(DraftId.draft_id(id), type, dataset, opts) do
          {:ok, doc} -> doc
          _ -> nil
        end
      end

    case existing do
      %_{} = doc ->
        case if_rev(attrs) do
          nil -> {:error, :conflict}
          expected -> {:error, {:rev_mismatch, %{expected: expected, actual: doc.rev}}}
        end

      _ ->
        with {:ok, doc} <- Content.create_document(type, attrs, dataset, opts), do: {:ok, doc, "create"}
    end
  end

  defp apply_one(%{"createOrReplace" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]
    expected = if_rev(attrs)

    existing =
      case id && Content.get_document(DraftId.draft_id(id), type, dataset, opts) do
        {:ok, doc} -> doc
        _ -> nil
      end

    with :ok <- ensure_rev(existing, expected),
         {:ok, doc} <- Content.create_document(type, attrs, dataset, opts) do
      {:ok, doc, "createOrReplace"}
    end
  end

  defp apply_one(%{"createIfNotExists" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    case id && Content.get_document(DraftId.draft_id(id), type, dataset, opts) do
      {:ok, existing} ->
        case ensure_rev(existing, if_rev(attrs)) do
          :ok -> {:ok, existing, "noop"}
          err -> err
        end

      _ ->
        with {:ok, doc} <- Content.create_document(type, attrs, dataset, opts), do: {:ok, doc, "create"}
    end
  end

  defp apply_one(%{"publish" => %{"id" => id, "type" => type}}, dataset, opts) do
    with {:ok, doc} <- Content.publish_document(id, type, dataset, opts), do: {:ok, doc, "publish"}
  end

  defp apply_one(%{"unpublish" => %{"id" => id, "type" => type}}, dataset, opts) do
    with {:ok, doc} <- Content.unpublish_document(id, type, dataset, opts), do: {:ok, doc, "unpublish"}
  end

  defp apply_one(%{"discardDraft" => %{"id" => id, "type" => type}}, dataset, opts) do
    with {:ok, doc} <- Content.discard_draft(id, type, dataset, opts), do: {:ok, doc, "discardDraft"}
  end

  defp apply_one(%{"delete" => %{"id" => id, "type" => type} = op}, dataset, opts) do
    case if_rev(op) do
      nil ->
        with {:ok, doc} <- Content.delete_document(id, type, dataset, opts), do: {:ok, doc, "delete"}

      expected ->
        with {:ok, existing} <- Content.get_document(id, type, dataset, opts),
             :ok <- ensure_rev(existing, expected),
             {:ok, doc} <- Content.delete_document(id, type, dataset, opts) do
          {:ok, doc, "delete"}
        end
    end
  end

  defp apply_one(%{"replace" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    with {:ok, existing} <- Content.get_document(id && DraftId.draft_id(id), type, dataset, opts),
         :ok <- ensure_rev(existing, if_rev(attrs)),
         {:ok, doc} <- Content.create_document(type, attrs, dataset, opts) do
      {:ok, doc, "replace"}
    end
  end

  defp apply_one(
         %{"patch" => %{"id" => id, "type" => type, "set" => fields} = patch},
         dataset,
         opts
       ) do
    with {:ok, existing} <- Content.get_document(id, type, dataset, opts),
         :ok <- ensure_rev(existing, if_rev(patch)) do
      merged =
        Map.merge(
          existing.content || %{},
          Map.drop(fields, ~w(title status _id _type _rev))
        )

      attrs = %{
        "doc_id" => id,
        "title" => fields["title"] || existing.title,
        "content" => merged
      }

      with {:ok, doc} <- Content.upsert_document(type, attrs, dataset, opts), do: {:ok, doc, "update"}
    end
  end

  defp apply_one(_, _, _), do: {:error, :malformed}

  defp if_rev(%{} = attrs), do: attrs["ifRevisionID"] || attrs["ifMatch"]
  defp if_rev(_), do: nil

  defp ensure_rev(_doc, nil), do: :ok
  defp ensure_rev(_doc, ""), do: :ok

  defp ensure_rev(nil, expected),
    do: {:error, {:rev_mismatch, %{expected: expected, actual: nil}}}

  defp ensure_rev(%{rev: r}, r), do: :ok

  defp ensure_rev(%{rev: actual}, expected),
    do: {:error, {:rev_mismatch, %{expected: expected, actual: actual}}}
end
