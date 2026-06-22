defmodule Barkpark.Content.Analytics do
  @moduledoc """
  Pure-read document analytics aggregates.

  Counts documents grouped by type (with published/draft breakdown), totals,
  and recent mutation activity. Leaf concern — read-only Ecto aggregates over
  `Document` / `MutationEvent`, scoped by dataset + tenancy.

  Extracted from `Barkpark.Content`, which keeps a thin delegating facade.

  Dataset scope mirrors `Barkpark.Content`'s private `scope_to_dataset/3`:
  resolved via the still-on-facade public `resolve_read_dataset_id/2` (concern
  K, not yet relocated), then the NULL-tolerant legacy-string OR. Workspace
  scope rides the shared `Barkpark.Content.Scope.scope_to_workspace_or_global/3`.
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Document, MutationEvent}

  import Barkpark.Content.Scope, only: [scope_to_workspace_or_global: 3]

  @doc "Count documents grouped by type, with published/draft breakdown."
  def document_stats(dataset, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> group_by([d], d.type)
    |> select([d], %{
      type: d.type,
      total: count(d.id),
      published: count(fragment("CASE WHEN ? NOT LIKE 'drafts.%' THEN 1 END", d.doc_id)),
      drafts: count(fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 END", d.doc_id))
    })
    |> order_by([d], asc: d.type)
    |> Repo.all()
  end

  @doc "Count total documents in a dataset."
  def total_documents(dataset, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> select([d], count(d.id))
    |> Repo.one()
  end

  @doc "Recent mutation activity — last N events."
  def recent_activity(dataset, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    MutationEvent
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> select([e], %{
      id: e.id,
      type: e.type,
      doc_id: e.doc_id,
      mutation: e.mutation,
      timestamp: e.inserted_at
    })
    |> Repo.all()
  end

  # Mirrors `Barkpark.Content`'s private `scope_to_dataset/3` (concern K, still
  # on the facade). Resolves the read dataset_id through the facade's public
  # `resolve_read_dataset_id/2`, then applies the NULL-tolerant legacy-string OR.
  defp scope_to_dataset(query, dataset, opts) do
    case Content.resolve_read_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [x], x.dataset_id == ^id or (is_nil(x.dataset_id) and x.dataset == ^dataset))

      _ ->
        where(query, [x], x.dataset == ^dataset)
    end
  end
end
