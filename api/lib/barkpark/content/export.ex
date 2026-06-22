defmodule Barkpark.Content.Export do
  @moduledoc """
  Streaming document export.

  Leaf concern — streams all documents for a dataset as envelope maps,
  optionally filtered by type. Read-only; must be consumed inside a
  `Repo.transaction` (uses `Repo.stream`).

  Extracted from `Barkpark.Content`, which keeps a thin delegating facade.

  Dataset scope mirrors `Barkpark.Content`'s private `scope_to_dataset/3`
  (concern K, still on the facade): resolved via the still-on-facade public
  `resolve_read_dataset_id/2`, then the NULL-tolerant legacy-string OR.
  Workspace scope rides the shared
  `Barkpark.Content.Scope.scope_to_workspace_or_global/3`.
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Document, Envelope}

  import Barkpark.Content.Scope, only: [scope_to_workspace_or_global: 3]

  @doc "Stream all documents for a dataset as envelope maps. Optionally filter by type."
  def export_stream(dataset, opts \\ []) do
    type = Keyword.get(opts, :type)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> then(fn q ->
      if type, do: where(q, [d], d.type == ^type), else: q
    end)
    |> order_by([d], asc: d.inserted_at)
    |> Repo.stream()
    |> Stream.map(&Envelope.render/1)
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
