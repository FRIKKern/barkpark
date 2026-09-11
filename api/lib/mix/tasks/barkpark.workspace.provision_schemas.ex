defmodule Mix.Tasks.Barkpark.Workspace.ProvisionSchemas do
  @moduledoc """
  Provision a workspace's content-type schemas by COPYING them from a source
  workspace (the Default workspace by default) into the target workspace's
  scope.

  The Studio desk is built from the schemas registered in the workspace being
  viewed (`Barkpark.Structure.build/2`), so a dedicated workspace only
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

  ## Pulled target rows require `--force`

  A target row can be PULLED DATA: a dataset restored from another server
  (`bp dev pull`) stamps its workspace with a `pull_provenance` entry for that
  dataset slug, and the schema rows sitting in that slot are the restored
  server's declarations, not this one's. Copying a source workspace's schema
  over such a row reverts it — `Content.upsert_schema/3` updates in place, and
  this task hands it five keys (`name`/`title`/`icon`/`visibility`/`fields`),
  so those five are replaced while `owner_scoped` / `cors_origins` /
  `desk_groups` / `list_preview` survive from the pulled row. A half-source,
  half-pulled row is the worst of both.

  So every target row that sits in a stamped slot is MARKED in the output —
  `(would update — TARGET IS PULLED DATA)` in the dry run, `(update — TARGET IS
  PULLED DATA)` on apply — and `--apply` alone REFUSES when any of them is
  stamped, exiting non-zero and naming `--force`. The refusal, not a warning,
  is the decision (`pds-bl-provision-schemas-pulled-warning`): an operator who
  has just restored a workspace from a bundle is exactly the operator who runs
  this task to fill in missing surfaces, and the failure mode — silently
  reverting restored schema rows to a source workspace's version — is invisible
  at the moment it happens and expensive to notice later. A dry run still lists
  the stamped rows plainly, so the refusal costs one flag, never information.

  `--force` proceeds and prints the stamped rows it overwrote. The write itself
  stays UNCONDITIONAL once allowed: this task never degenerates into a silent
  no-op that skips stamped rows while reporting success. The stamp's own escape
  hatch remains `Tenancy.set_pull_provenance(ws, slug, %{})`.

      # refuses, exit 1, names --force
      mix barkpark.workspace.provision_schemas restored --apply

      # proceeds, marks and reports what it overwrote
      mix barkpark.workspace.provision_schemas restored --apply --force
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
    apply: :boolean,
    force: :boolean
  ]

  @pulled_marker " — TARGET IS PULLED DATA"

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
    force? = Keyword.get(opts, :force, false)
    names = schema_names(opts)

    target =
      Tenancy.get_project(target_slug, project) ||
        Mix.raise("no project #{target_slug}/#{project}")

    source =
      Tenancy.get_project(source_slug, project) ||
        Mix.raise("no source project #{source_slug}/#{project}")

    target_scope = [workspace_id: target.workspace_id, project_id: target.id]
    source_scope = [workspace_id: source.workspace_id, project_id: source.id]

    Mix.shell().info(
      "#{if apply?, do: "PROVISION", else: "DRY RUN"}: " <>
        "#{source_slug} → #{target_slug}/#{project} (dataset #{dataset})"
    )

    entries =
      Enum.map(names, &survey_one(&1, dataset, source_scope, target_scope, source_slug))

    stamped = Enum.filter(entries, & &1.pulled?)

    if apply? and stamped != [] and not force? do
      Enum.each(entries, &report_planned/1)
      warn_stamped(stamped, :refuse)

      Mix.raise(
        "refusing to overwrite #{length(stamped)} pull-provenance-stamped target row(s) " <>
          "(#{stamped_names(stamped)}) — re-run with --force to overwrite them"
      )
    end

    Enum.each(entries, fn entry ->
      if apply?, do: write_one(entry, dataset, target_scope), else: report_planned(entry)
    end)

    warn_stamped(stamped, if(apply?, do: :forced, else: :dry))

    unless apply?, do: Mix.shell().info("(dry run — re-run with --apply to write)")
  end

  defp schema_names(opts) do
    case Keyword.get(opts, :schemas) do
      nil -> @default_schemas
      csv -> csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  # ── survey: what WOULD happen to each name, before anything is written ──────
  #
  # The pulled? read is the SCOPED face of the canonical predicate
  # (`Tenancy.pulled_schema_row?/2` handed the target-scope row). Asking it by
  # NAME here would answer about the Default dataset slot, not about the target
  # workspace this task is writing into.
  defp survey_one(name, dataset, source_scope, target_scope, source_slug) do
    case Content.get_schema(name, dataset, source_scope) do
      {:ok, src} ->
        {verb, pulled?} =
          case Content.get_schema(name, dataset, target_scope) do
            {:ok, existing} -> {"update", Tenancy.pulled_schema_row?(existing, dataset)}
            _ -> {"create", false}
          end

        %{name: name, src: src, verb: verb, pulled?: pulled?, missing_source: nil}

      {:error, :not_found} ->
        %{name: name, src: nil, verb: nil, pulled?: false, missing_source: source_slug}
    end
  end

  defp report_planned(%{missing_source: slug, name: name}) when is_binary(slug) do
    Mix.shell().error("  ! #{name}: not found in source '#{slug}' — skipped")
  end

  defp report_planned(entry) do
    Mix.shell().info("  • #{entry.name} (would #{entry.verb}#{marker(entry)})")
  end

  defp write_one(%{missing_source: slug} = entry, _dataset, _target_scope)
       when is_binary(slug) do
    report_planned(entry)
  end

  defp write_one(entry, dataset, target_scope) do
    src = entry.src

    attrs = %{
      "name" => src.name,
      "title" => src.title,
      "icon" => src.icon,
      "visibility" => src.visibility,
      "fields" => src.fields
    }

    case Content.upsert_schema(attrs, dataset, target_scope) do
      {:ok, _} ->
        Mix.shell().info("  ✓ #{entry.name} (#{entry.verb}#{marker(entry)})")

      {:error, %Ecto.Changeset{} = cs} ->
        Mix.shell().error("  ✗ #{entry.name}: #{inspect(cs.errors)}")

      # Fail-closed scope stamp (felix-w26): dataset resolution can now
      # refuse with a non-changeset reason ({:invalid_dataset, _} / :conflict).
      {:error, reason} ->
        Mix.shell().error("  ✗ #{entry.name}: #{inspect(reason)}")
    end
  end

  defp marker(%{pulled?: true}), do: @pulled_marker
  defp marker(_entry), do: ""

  defp stamped_names(stamped), do: stamped |> Enum.map(& &1.name) |> Enum.join(", ")

  defp warn_stamped([], _mode), do: :ok

  defp warn_stamped(stamped, mode) do
    n = length(stamped)

    Mix.shell().info(
      "  ⚠ #{n} target row(s) sit in a pull-provenance-stamped slot: #{stamped_names(stamped)}"
    )

    case mode do
      :forced ->
        Mix.shell().info("  ⚠ --force: overwrote #{n} pull-provenance-stamped target row(s)")

      _ ->
        Mix.shell().info("  ⚠ writing over them requires --apply --force")
    end
  end
end
