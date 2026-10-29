defmodule BarkparkWeb.DatasetController do
  @moduledoc """
  `DELETE /w/:ws/p/:proj/v1/datasets/:dataset` — permanently delete one dataset of
  the resolved project (task-a944250b938671bd). `bp dataset delete <name>`.

  Mounted on `:scoped_api` + `:scoped_admin`: an unknown workspace is 404, a
  caller whose seat is not `owner`/`admin` is 403, and a dataset-bound token
  naming another dataset is 403 `forbidden_dataset`, all before this action
  runs. The segment is `:dataset` so that last guard sees it.

  | Case | Status | `error.code` |
  |---|---|---|
  | deleted | 200 | — |
  | no such dataset in the project, or not a dataset slug | 404 | `not_found` |
  | `name` is `production` | 409 | `production_dataset_protected` |
  | global (no-workspace) search rows hang off it | 409 | `dataset_in_shared_search` |
  | another dataset's document embeds its media | 409 | `dataset_media_referenced` |

  The 200 body names the dataset and what left with it:
  `{deleted, dataset: {id, slug, name}, documents, media_files, swept: {table: N}, detached: {table: N}, tokens_revoked}`.
  `detached` counts other workspaces' rows that pointed at the dataset and keep
  living with `dataset_id` NULL. The delete is on the workspace's audit chain.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy
  alias BarkparkWeb.ErrorResponse

  action_fallback BarkparkWeb.FallbackController

  # ANCHORED DELETE/REVOKE ROW — EDITING THIS BODY REDS A GATE IN scripts/.
  # Re-derive its @exclusion_anchors values from
  #   elixir scripts/pds-elixir-receipt-census.exs --exclusion-keys
  # in the same commit: docs/ops/exclusion-anchor-rederive.md
  def delete(conn, %{"dataset" => name}) do
    with true <- Tenancy.Dataset.valid_slug?(name),
         %Tenancy.Project{} = project <- conn.assigns[:current_project],
         %Tenancy.Dataset{} = dataset <- Tenancy.get_dataset(project, name),
         {:ok, receipt} <- Tenancy.delete_dataset(dataset, actor(conn)) do
      if Map.has_key?(receipt.swept, "shares"), do: Barkpark.Sharing.refresh()

      json(conn, %{
        deleted: true,
        dataset: %{id: receipt.dataset.id, slug: receipt.dataset.slug, name: receipt.dataset.name},
        documents: receipt.documents,
        media_files: receipt.media_files,
        swept: receipt.swept,
        detached: receipt.detached,
        tokens_revoked: receipt.tokens_revoked
      })
    else
      falsy when falsy in [nil, false] ->
        ErrorResponse.emit_custom(
          conn,
          404,
          "not_found",
          "no dataset #{inspect(name)} in this project",
          %{},
          "`bp workspace dataset-ls` lists the datasets you can delete."
        )

      {:error, :production_dataset} ->
        ErrorResponse.emit_custom(
          conn,
          409,
          "production_dataset_protected",
          "the production dataset cannot be deleted; delete the workspace to remove it"
        )

      {:error, {:shared_search, held}} ->
        ErrorResponse.emit_custom(
          conn,
          409,
          "dataset_in_shared_search",
          "global search rows every workspace inherits are keyed to this dataset",
          %{held: held},
          "Keep the dataset; deleting it would cascade the shared synonyms and search intel."
        )

      {:error, {:media_referenced, files}} ->
        ErrorResponse.emit_custom(
          conn,
          409,
          "dataset_media_referenced",
          "documents outside this dataset embed #{length(files)} of its media files",
          %{media: files},
          "Remove those references, then delete the dataset again."
        )

      {:error, :not_found} ->
        ErrorResponse.emit_custom(
          conn,
          404,
          "not_found",
          "no dataset #{inspect(name)} in this project"
        )

      {:error, _} = err ->
        err
    end
  end

  defp actor(conn) do
    case conn.assigns[:api_token] do
      %{id: id} -> [actor_type: "api_token", actor_id: to_string(id)]
      _ -> []
    end
  end
end
