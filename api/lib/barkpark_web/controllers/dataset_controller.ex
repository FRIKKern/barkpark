defmodule BarkparkWeb.DatasetController do
  @moduledoc """
  `DELETE /w/:ws/p/:proj/v1/datasets/:name` — permanently delete one dataset of
  the resolved project (task-a944250b938671bd). `bp dataset delete <name>`.

  Mounted on `:scoped_api` + `:scoped_admin`: an unknown workspace is 404, a
  caller whose seat is not `owner`/`admin` is 403, both before this action runs.

  | Case | Status | `error.code` |
  |---|---|---|
  | deleted | 200 | — |
  | no dataset `name` in the project | 404 | `not_found` |
  | `name` is `production` | 409 | `production_dataset_protected` |

  The 200 body names the dataset and what left with it:
  `{deleted: true, dataset: {id, slug, name}, documents: N, media_files: N, swept: {table: N}}`.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy
  alias BarkparkWeb.ErrorResponse

  action_fallback BarkparkWeb.FallbackController

  def delete(conn, %{"name" => name}) do
    with %Tenancy.Project{} = project <- conn.assigns[:current_project],
         %Tenancy.Dataset{} = dataset <- Tenancy.get_dataset(project, name),
         {:ok, receipt} <- Tenancy.delete_dataset(dataset) do
      if Map.has_key?(receipt.swept, "shares"), do: Barkpark.Sharing.refresh()

      json(conn, %{
        deleted: true,
        dataset: %{id: receipt.dataset.id, slug: receipt.dataset.slug, name: receipt.dataset.name},
        documents: receipt.documents,
        media_files: receipt.media_files,
        swept: receipt.swept
      })
    else
      nil ->
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
end
