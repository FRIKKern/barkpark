defmodule Mix.Tasks.Barkpark.Shape.StatusToPhase do
  @moduledoc """
  Move a project's old `status` choice into `content.phase` (owner ruling
  #45). DRY RUN by default; `--apply` writes. See
  `Barkpark.Content.ShapeMigrations.StatusToPhase` for what changes and the
  release (`bin/barkpark eval`) form.

      mix barkpark.shape.status_to_phase                 # census + dry run
      mix barkpark.shape.status_to_phase --apply         # write
      mix barkpark.shape.status_to_phase --type project --field phase
  """
  @shortdoc "Move non-lifecycle row statuses into content.phase (dry-run by default)"

  use Mix.Task

  alias Barkpark.Content.ShapeMigrations.StatusToPhase

  @switches [apply: :boolean, dry_run: :boolean, type: :string, field: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("Unknown arguments: #{inspect(invalid)}")

    apply? = Keyword.get(opts, :apply, false) and not Keyword.get(opts, :dry_run, false)

    Mix.shell().info("census: #{inspect(StatusToPhase.census())}")

    result =
      StatusToPhase.run(
        apply: apply?,
        type: Keyword.get(opts, :type, "project"),
        field: Keyword.get(opts, :field, "phase")
      )

    for row <- result.rows do
      Mix.shell().info(
        "#{row.doc_id}: status #{row.old_status} -> #{row.new_status}" <>
          if(row.kept_existing,
            do: " (phase already set, kept)",
            else: ", phase := #{row.old_status}"
          )
      )
    end

    Mix.shell().info(
      "scanned=#{result.scanned} changed=#{result.changed} applied=#{result.applied?}"
    )

    unless apply?,
      do: Mix.shell().info("Dry run — nothing was written. Re-run with --apply to write.")
  end
end
