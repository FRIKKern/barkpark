defmodule Barkpark.Content.FixedDocuments do
  @moduledoc """
  A type with a fixed set of documents (task-f4c80d82cc25b19b): HSO's two
  side pages, `side-om-oss` and `side-hva-vi-jobber-med`, which an editor
  opens and edits but never creates, duplicates or deletes.

  The schema says it as data: `fixed_documents` (`fixedDocuments` on the
  wire) is the list of the type's document ids. On such a type:

    * creating a document whose id (without `drafts.`) is not in the list is
      refused, unless a row of that id and type already exists (an edit, or a
      `createOrReplace` over it). A duplicate is a create of a new id, so it
      is refused. `[]` means nothing new may be created;
    * a listed id that does not exist yet may be created: the first import or
      seed, and an admin restoring a deleted page;
    * deleting a listed document is refused. An unlisted one (left over from
      before the list was set) may still be deleted;
    * edits, publish, unpublish and discarding a draft are unchanged.

  No list (`nil`, every schema stored before this key) is exactly today's
  behaviour. A document id is (id, type), so moving a document into the type
  is a create of a new row and meets the same rule.

  The Writer asks `check_create/4` on every create and upsert, and
  `Lifecycle.delete_document/4` asks `check_delete/4`. Bulk removals that
  empty a whole dataset or workspace, and the sync mirror, pass
  `fixed_documents: :skip` and are unchanged.
  """

  import Ecto.Changeset, only: [get_change: 2, add_error: 3, put_change: 3]

  alias Barkpark.Content
  alias Barkpark.Content.DraftId

  @typedoc "The refusal `Content.Errors` renders as 409 `fixed_document`."
  @type refusal :: {:error, {:fixed_document, :create | :delete, String.t(), String.t()}}

  @doc """
  `:ok`, or the refusal, for writing `attrs` (a create or an upsert) as a
  document of `type`. Costs one schema read (memoised per request) and, only
  for an unlisted id on a fixed type, a read of the existing row.
  """
  @spec check_create(term(), term(), String.t(), keyword()) :: :ok | refusal()
  def check_create(type, attrs, dataset, opts) do
    with false <- Keyword.get(opts, :fixed_documents) == :skip,
         ids when is_list(ids) <- fixed(type, dataset, opts) do
      id = attrs_id(attrs)
      base = is_binary(id) && DraftId.published_id(id)

      cond do
        is_binary(base) and base in ids -> :ok
        is_binary(base) and exists?(base, type, dataset, opts) -> :ok
        true -> {:error, {:fixed_document, :create, type, base || ""}}
      end
    else
      _ -> :ok
    end
  end

  @doc "`:ok`, or the refusal, for deleting `doc_id` (either spelling) of `type`."
  @spec check_delete(term(), term(), String.t(), keyword()) :: :ok | refusal()
  def check_delete(doc_id, type, dataset, opts) when is_binary(doc_id) do
    with false <- Keyword.get(opts, :fixed_documents) == :skip,
         ids when is_list(ids) <- fixed(type, dataset, opts),
         base = DraftId.published_id(doc_id),
         true <- base in ids do
      {:error, {:fixed_document, :delete, type, base}}
    else
      _ -> :ok
    end
  end

  def check_delete(_doc_id, _type, _dataset, _opts), do: :ok

  @doc "The 409 `fixed_document` envelope `Content.Errors` renders for a refusal."
  def envelope(action, type, id) do
    message =
      case action do
        :create ->
          "type #{inspect(type)} has a fixed set of documents; #{inspect(id)} is not one of them, so it cannot be created"

        :delete ->
          "#{inspect(id)} is one of type #{inspect(type)}'s fixed documents, so it cannot be deleted"
      end

    %{
      code: "fixed_document",
      message: message,
      status: 409,
      details: %{"action" => Atom.to_string(action), "type" => type, "id" => id}
    }
  end

  @doc "The type's fixed ids, or `nil` when it has no list (or no schema)."
  @spec fixed(term(), String.t(), keyword()) :: [String.t()] | nil
  def fixed(type, dataset, opts) when is_binary(type) and is_binary(dataset) do
    case Content.resolve_schema(type, dataset, opts) do
      {:ok, %{fixed_documents: ids}} when is_list(ids) -> ids
      _ -> nil
    end
  end

  def fixed(_type, _dataset, _opts), do: nil

  @doc """
  Schema changeset check: a list of document ids, each a non-empty string
  without the `drafts.` or `versions.` prefix. The cast already refused a
  value that is not a list of strings. The raw input is read, not the cast
  value, because the cast drops `""` items. Duplicates are dropped.
  """
  @spec validate(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate(changeset) do
    with {:ok, raw} when is_list(raw) <- Map.fetch(changeset.params || %{}, "fixed_documents"),
         true <- Enum.all?(raw, &valid_id?/1) do
      case get_change(changeset, :fixed_documents) do
        ids when is_list(ids) -> put_change(changeset, :fixed_documents, Enum.uniq(ids))
        _ -> changeset
      end
    else
      false ->
        add_error(
          changeset,
          :fixed_documents,
          "must list document ids, without drafts. or versions."
        )

      _ ->
        changeset
    end
  end

  @doc "`fixedDocuments` (the wire spelling) is accepted for `fixed_documents`."
  def alias_key(%{"fixedDocuments" => ids} = attrs) when not is_map_key(attrs, "fixed_documents"),
    do: Map.put(attrs, "fixed_documents", ids)

  def alias_key(attrs), do: attrs

  defp valid_id?(id) do
    is_binary(id) and id != "" and String.length(id) <= 255 and
      not String.starts_with?(id, ["drafts.", "versions."])
  end

  defp attrs_id(attrs) when is_map(attrs),
    do: Map.get(attrs, "doc_id") || Map.get(attrs, :doc_id) || Map.get(attrs, "_id")

  defp attrs_id(_attrs), do: nil

  defp exists?(base, type, dataset, opts) do
    Enum.any?([base, DraftId.draft_id(base)], fn id ->
      match?({:ok, _}, Content.get_document(id, type, dataset, opts))
    end)
  end
end
