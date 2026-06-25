defmodule Mix.Tasks.Barkpark.Workspace.ProvisionSchemas do
  @moduledoc """
  Provision a workspace's content-type schemas by COPYING them from a source
  workspace (the Default workspace by default) into the target workspace's
  scope.

  The Studio desk is built from the schemas registered in the workspace being
  viewed (`Barkpark.Structure.build/3`), so a dedicated workspace only
  surfaces the plugin features whose schemas it actually owns. Creating a
  workspace (`Tenancy.create_workspace_with_owner/_`) does NOT register plugin
  schemas, so a fresh dedicated workspace starts with an empty desk — this
  task is how it gets its Papers / Sheets / Media / Tasks surfaces.

  Idempotent (upsert on `(name, dataset)` within the target scope) and safe by
  default: a bare invocation is a DRY RUN that reports what WOULD change and
  writes nothing. Pass `--apply` to write.

      # report only (the safe default)
      mix barkpark.workspace.provision_schemas gyldendal

      # provision Gyldendal's default plugin surfaces
      mix barkpark.workspace.provision_schemas gyldendal --apply

      # custom set / source / scope
      mix barkpark.workspace.provision_schemas acme --project default \\
        --dataset production --from default \\
        --schemas paper,sheet,task --apply

  Defaults: project `default`, dataset `production`, source workspace
  `default`, schemas `paper,sheet,mediaAsset,mediaCollection,task` (the
  Bulldocs / Sheets / Media / Tasks plugin surfaces).
  """
  @shortdoc "Copy plugin schemas into a workspace's scope (dry-run by default; --apply to write)"

  use Mix.Task

  alias Barkpark.{Content, Tenancy}

  @default_schemas ~w(paper sheet mediaAsset mediaCollection task)

  @switches [
    project: :string,
    dataset: :string,
    from: :string,
    schemas: :string,
    apply: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)
    unless invalid == [], do: Mix.raise("unknown option(s): #{inspect(invalid)}")

    target_slug =
      case argv do
        [slug | _] -> slug
        [] -> Mix.raise("usage: mix barkpark.workspace.provision_schemas <ws-slug> [--apply]")
      end

    project = Keyword.get(opts, :project, "default")
    dataset = Keyword.get(opts, :dataset, "production")
    source_slug = Keyword.get(opts, :from, "default")
    apply? = Keyword.get(opts, :apply, false)
    names = schema_names(opts)

    target = Tenancy.get_project(target_slug, project) || Mix.raise("no project #{target_slug}/#{project}")

    source =
      Tenancy.get_project(source_slug, project) ||
        Mix.raise("no source project #{source_slug}/#{project}")

    target_scope = [workspace_id: target.workspace_id, project_id: target.id]
    source_scope = [workspace_id: source.workspace_id, project_id: source.id]

    Mix.shell().info(
      "#{if apply?, do: "PROVISION", else: "DRY RUN"}: " <>
        "#{source_slug} → #{target_slug}/#{project} (dataset #{dataset})"
    )

    Enum.each(names, &provision_one(&1, dataset, source_scope, target_scope, source_slug, apply?))

    unless apply?, do: Mix.shell().info("(dry run — re-run with --apply to write)")
  end

  defp schema_names(opts) do
    case Keyword.get(opts, :schemas) do
      nil -> @default_schemas
      csv -> csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp provision_one(name, dataset, source_scope, target_scope, source_slug, apply?) do
    case Content.get_schema(name, dataset, source_scope) do
      {:ok, src} ->
        verb = if match?({:ok, _}, Content.get_schema(name, dataset, target_scope)), do: "update", else: "create"

        if apply? do
          attrs = %{
            "name" => src.name,
            "title" => src.title,
            "icon" => src.icon,
            "visibility" => src.visibility,
            "fields" => src.fields
          }

          case Content.upsert_schema(attrs, dataset, target_scope) do
            {:ok, _} -> Mix.shell().info("  ✓ #{name} (#{verb})")
            {:error, cs} -> Mix.shell().error("  ✗ #{name}: #{inspect(cs.errors)}")
          end
        else
          Mix.shell().info("  • #{name} (would #{verb})")
        end

      {:error, :not_found} ->
        Mix.shell().error("  ! #{name}: not found in source '#{source_slug}' — skipped")
    end
  end
end
