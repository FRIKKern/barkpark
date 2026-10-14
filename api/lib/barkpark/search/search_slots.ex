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
  triggers for its COPY, so it calls this for the imported workspace once the
  import has committed. Only rows whose slots differ are written.
  """

  alias Barkpark.Repo

  # Static SQL only: `$1` is the optional workspace id (NULL = every workspace).
  @refresh_sql """
  UPDATE documents d
  SET search_title = x.slots[1], search_author = x.slots[2]
  FROM (
    SELECT d2.id,
           bp_search_slots(d2.type, d2.dataset, d2.dataset_id, d2.workspace_id,
                           d2.title, d2.content) AS slots
    FROM documents d2
    WHERE ($1::uuid IS NULL OR d2.workspace_id = $1::uuid)
  ) x
  WHERE d.id = x.id
    AND (d.search_title IS DISTINCT FROM x.slots[1]
         OR d.search_author IS DISTINCT FROM x.slots[2])
  """

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

    %{num_rows: n} = Repo.query!(@refresh_sql, [workspace_id], timeout: :infinity)
    n
  end
end
