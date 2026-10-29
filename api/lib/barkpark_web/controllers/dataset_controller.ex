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
  | still deleting after 5 s: send the DELETE again | 202 | — |
  | the delete failed or was cut off and rolled back | 503 | `storage_unavailable` |
  | no such dataset in the project, or not a dataset slug | 404 | `not_found` |
  | `name` is `production` | 409 | `production_dataset_protected` |
  | global (no-workspace) search rows hang off it | 409 | `dataset_in_shared_search` |
  | another dataset's document embeds its media | 409 | `dataset_media_referenced` |

  The 200 body names the dataset and what left with it:
  `{deleted, dataset: {id, slug, name}, documents, media_files, swept: {table: N}, detached: {table: N}, tokens_revoked}`.
  `detached` counts other workspaces' rows that pointed at the dataset and keep
  living with `dataset_id` NULL. The delete is on the workspace's audit chain.
  After the commit the workspace's cached search surface config for the slug is
  dropped (`SurfaceConfigs.forget/2`), so a recreated name starts untuned.

  The delete runs off the request (`Tenancy.DatasetDelete.Runs`). A 202 is
  `{deleting: true, dataset}`; the next DELETE of the name waits again and
  answers the run's 200 or error once. A 503 carries `details.reason`
  `dataset_delete_timeout`, `_contended`, `_database` or `_interrupted`, and
  the dataset is untouched. A 404 after a 202 means another caller read the receipt.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.DatasetDelete.Runs
  alias BarkparkWeb.ErrorResponse

  action_fallback BarkparkWeb.FallbackController

  # ANCHORED DELETE/REVOKE ROW — EDITING THIS BODY REDS A GATE IN scripts/.
  # Re-derive its @exclusion_anchors values from
  #   elixir scripts/pds-elixir-receipt-census.exs --exclusion-keys
  # in the same commit: docs/ops/exclusion-anchor-rederive.md
  def delete(conn, %{"dataset" => name}) do
    with true <- Tenancy.Dataset.valid_slug?(name),
         %Tenancy.Project{} = project <- conn.assigns[:current_project],
         dataset = Tenancy.get_dataset(project, name),
         {:ok, receipt} <-
           Runs.delete(project.id, name, dataset, run_opts(conn, project, name), wait_ms()) do
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
      :running ->
        conn
        |> put_status(:accepted)
        |> json(%{deleting: true, dataset: name})

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
          "no dataset #{inspect(name)} in this project",
          %{},
          "`bp workspace dataset-ls` lists the datasets you can delete."
        )

      {:error, {:delete_failed, reason}} ->
        ErrorResponse.emit_custom(
          conn,
          503,
          "storage_unavailable",
          "the dataset delete stopped (#{reason}) and rolled back; the dataset is whole",
          %{reason: "dataset_delete_#{reason}"},
          failed_hint(reason)
        )

      {:error, _} = err ->
        err
    end
  end

  defp run_opts(conn, project, name) do
    [
      actor: conn.assigns[:api_token],
      on_deleted: fn receipt ->
        if Map.has_key?(receipt.swept, "shares"), do: Barkpark.Sharing.refresh()
        Barkpark.Search.SurfaceConfigs.forget(project.workspace_id, name)
      end
    ]
  end

  defp failed_hint(:database),
    do: "Nothing was deleted. If the DELETE keeps failing, report the request_id."

  defp failed_hint(_reason), do: "Transient: nothing was deleted. Send the DELETE again."

  defp wait_ms, do: Application.get_env(:barkpark, :dataset_delete_wait_ms, 5_000)
end
