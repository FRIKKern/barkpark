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

  # No import: the module loads under plain `elixir` with DraftId alone, so the
  # Studio's case table is answered by `answer/4` itself (see its doc).
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
         ids when is_list(ids) <- fixed(type, dataset, opts),
         id = attrs_id(attrs),
         :refused <- answer(ids, :create, id, fn -> exists?(id, type, dataset, opts) end) do
      {:error,
       {:fixed_document, :create, type, if(is_binary(id), do: DraftId.published_id(id), else: "")}}
    else
      _ -> :ok
    end
  end

  @doc "`:ok`, or the refusal, for deleting `doc_id` (either spelling) of `type`."
  @spec check_delete(term(), term(), String.t(), keyword()) :: :ok | refusal()
  def check_delete(doc_id, type, dataset, opts) do
    with false <- Keyword.get(opts, :fixed_documents) == :skip,
         ids when is_list(ids) <- fixed(type, dataset, opts),
         :refused <- answer(ids, :delete, doc_id, fn -> true end) do
      {:error, {:fixed_document, :delete, type, DraftId.published_id(doc_id)}}
    else
      _ -> :ok
    end
  end

  @doc """
  The rule alone: `:ok` or `:refused` for `action` (`:create` or `:delete`) on
  `id` (either spelling) of a type whose list is `ids` (`nil` = no list).
  `exists?` says whether a row of that id and type already exists; it is called
  only for a create of an unlisted id. barkpark-studio's
  `fixtures/fixed-document-cases.json` is answered by this function.
  """
  @spec answer([String.t()] | nil, :create | :delete, term(), (-> boolean())) :: :ok | :refused
  def answer(nil, _action, _id, _exists?), do: :ok

  def answer(ids, :create, id, exists?) when is_list(ids) and is_binary(id),
    do: if(DraftId.published_id(id) in ids or exists?.(), do: :ok, else: :refused)

  def answer(ids, :create, _id, _exists?) when is_list(ids), do: :refused

  def answer(ids, :delete, id, _exists?) when is_list(ids) and is_binary(id),
    do: if(DraftId.published_id(id) in ids, do: :refused, else: :ok)

  def answer(_ids, :delete, _id, _exists?), do: :ok

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
  def validate(changeset), do: changeset |> validate_ids() |> validate_singleton()

  # A singleton's one document has the type's name as its id: a list without
  # it means that document can never be created (task-f235c9f16a976e57). Only
  # a write that changes singleton, the list or the name is refused, so a
  # schema already stored that way still saves unchanged.
  defp validate_singleton(changeset) do
    name = Ecto.Changeset.get_field(changeset, :name)
    ids = Ecto.Changeset.get_field(changeset, :fixed_documents)

    touched? =
      Enum.any?([:singleton, :fixed_documents, :name], &Ecto.Changeset.changed?(changeset, &1))

    if touched? and Ecto.Changeset.get_field(changeset, :singleton) == true and is_list(ids) and
         is_binary(name) and name not in ids do
      Ecto.Changeset.add_error(
        changeset,
        :fixed_documents,
        "must hold the singleton's own id, #{name}"
      )
    else
      changeset
    end
  end

  defp validate_ids(changeset) do
    with {:ok, raw} when is_list(raw) <- Map.fetch(changeset.params || %{}, "fixed_documents"),
         true <- Enum.all?(raw, &valid_id?/1) do
      case Ecto.Changeset.get_change(changeset, :fixed_documents) do
        ids when is_list(ids) ->
          Ecto.Changeset.put_change(changeset, :fixed_documents, Enum.uniq(ids))

        _ ->
          changeset
      end
    else
      false ->
        Ecto.Changeset.add_error(
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

  defp exists?(id, type, dataset, opts) do
    base = DraftId.published_id(id)

    Enum.any?([base, DraftId.draft_id(base)], fn id ->
      match?({:ok, _}, Content.get_document(id, type, dataset, opts))
    end)
  end
end
