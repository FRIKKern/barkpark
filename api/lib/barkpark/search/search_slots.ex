defmodule Barkpark.Search.SearchSlots do
  @moduledoc """
  The weighted title and author slots of the search vector
  (task-3c6d02392d430c98, migration 20261014150000).

  `documents.search_title` and `documents.search_author` hold the text the
  search vector weights 'A' and 'B' when the `title` column is not the search
  title: the field a schema marks `"search": "title"`, the `list_preview.title`
  field of a type without a title field, or a declared `name` / `displayName` /
  `label` / `heading` / `headline` field; and the fields marked
  `"search": "author"`, else the declared `Author` / `Authors` fields. The SQL
  function `bp_search_slots/6` holds the rule; a BEFORE trigger applies it on
  every document write and a schema trigger re-applies it to a type's
  documents when the schema's fields or list preview change.

  `refresh/1` re-applies it to rows written with triggers disabled: a
  workspace bundle import (`Barkpark.Tenancy.WorkspaceBundle`) disables user
  triggers for its COPY, so it calls the same SQL function,
  `bp_refresh_search_slots/1`, for the imported workspace once the import has
  committed. Only rows whose slots differ are written.
  """

  alias Barkpark.Repo

  @doc """
  Recompute the search slots of every document of one workspace
  (`workspace_id: id`) or of every workspace, writing only the rows whose
  slots differ. Returns the number of rows written.
  """
  @spec refresh(keyword()) :: non_neg_integer()
  def refresh(opts \\ []) do
    workspace_id =
      case Keyword.get(opts, :workspace_id) do
        id when is_binary(id) -> Ecto.UUID.dump!(id)
        _ -> nil
      end

    %{rows: [[n]]} =
      Repo.query!("SELECT bp_refresh_search_slots($1::uuid)", [workspace_id], timeout: :infinity)

    n
  end
end
