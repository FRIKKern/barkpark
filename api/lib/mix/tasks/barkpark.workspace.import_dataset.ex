defmodule Mix.Tasks.Barkpark.Workspace.ImportDataset do
  @moduledoc """
  Import a dataset bundle as a NEW dataset in a workspace on this instance.

      mix barkpark.workspace.import_dataset BUNDLE.tar \\
        --workspace acme --project default --dataset production-copy

  `BUNDLE.tar` must be a dataset-scoped export (`GET
  /api/workspaces/:slug/export?dataset=<slug>`, or `bp dev pull`). The import
  creates dataset `--dataset` under project `--project` of workspace
  `--workspace`, with a fresh dataset id and fresh row ids, and rewrites every
  pointer to the source dataset. It is `WorkspaceBundle.import_bundle_file/2`
  with the `:into_dataset` option; the table of what is rewritten, what is not
  carried and what refuses the import lives in
  `Barkpark.Tenancy.WorkspaceBundle.DatasetRemap`.

  Everything runs in one transaction. On a refusal the task exits non-zero,
  names the engine's reason (for example `dataset_slug_conflict` or
  `unhandled_dataset_rows`) and writes nothing.

  This task has no HTTP authorization in front of it: whoever can run a mix
  task on the box already holds the database credentials. The HTTP route
  (`POST /api/workspaces/:workspace_slug/import?into_dataset=…&into_project=…`)
  is the surface for everyone else, and it requires write on the target
  workspace.
  """
  @shortdoc "Import a dataset bundle as a new dataset (fresh ids, pointers rewritten)"

  use Mix.Task

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.{DatasetRemapError, InvalidBundleError}

  @switches [workspace: :string, project: :string, dataset: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)
    unless invalid == [], do: Mix.raise("unknown option(s): #{inspect(invalid)}")

    bundle =
      case argv do
        [path] -> path
        _ -> Mix.raise(usage())
      end

    [ws_slug, project_slug, new_slug] =
      Enum.map([:workspace, :project, :dataset], fn key ->
        case opts[key] do
          value when is_binary(value) and value != "" -> value
          _ -> Mix.raise("missing --#{key}\n\n" <> usage())
        end
      end)

    workspace =
      Tenancy.get_workspace_by_slug(ws_slug) || Mix.raise("no workspace #{inspect(ws_slug)}")

    project =
      Tenancy.get_project(ws_slug, project_slug) ||
        Mix.raise("workspace #{inspect(ws_slug)} has no project #{inspect(project_slug)}")

    target = [workspace_id: workspace.id, project_id: project.id, slug: new_slug]

    case import_into(bundle, target) do
      {:ok, stats} ->
        report(stats)
        stats

      {:error, reason} ->
        Mix.raise("import failed: #{inspect(reason)}")
    end
  end

  defp import_into(bundle, target) do
    WorkspaceBundle.import_bundle_file(bundle, into_dataset: target)
  rescue
    e in DatasetRemapError ->
      Mix.raise("import refused (#{e.code}): #{e.message}")

    e in InvalidBundleError ->
      Mix.raise("not a usable bundle (#{e.code}): #{e.message}")
  end

  defp report(%{remap: remap} = stats) do
    Mix.shell().info(
      "imported dataset #{remap.dataset_slug} (#{remap.dataset_id}) from source dataset " <>
        "#{remap.source.dataset_slug} (#{remap.source.dataset_id}): #{stats.total_rows} row(s)"
    )

    for {table, n} <- Enum.sort(stats.tables),
        do: Mix.shell().info("  #{table}: #{n}")

    for {label, counts} <- [
          {"dropped (another dataset's rows)", remap.dropped_out_of_dataset},
          {"not imported (workspace-scoped)", remap.skipped_workspace_scoped},
          {"not carried (source credentials and access)", remap.not_carried}
        ],
        counts != %{} do
      Mix.shell().info(
        "#{label}: " <> Enum.map_join(Enum.sort(counts), ", ", fn {t, n} -> "#{t} #{n}" end)
      )
    end
  end

  defp usage do
    "usage: mix barkpark.workspace.import_dataset BUNDLE.tar " <>
      "--workspace SLUG --project SLUG --dataset NEW_SLUG"
  end
end
