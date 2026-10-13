defmodule Mix.Tasks.Barkpark.Shape.StringifiedImages do
  @moduledoc """
  Census and repair of image fields Beta stored as a JSON string
  (task-b44972b2869fb54a). DRY RUN by default; `--apply` writes. See `Barkpark.Content.ShapeMigrations.StringifiedImages`
  for what changes and the release (`bin/barkpark eval`) form.

      mix barkpark.shape.stringified_images           # census + dry run
      mix barkpark.shape.stringified_images --apply   # write
  """
  @shortdoc "Count image fields stored as a JSON string and repair them (dry-run by default)"

  use Mix.Task

  alias Barkpark.Content.ShapeMigrations.StringifiedImages

  @switches [apply: :boolean, dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("Unknown arguments: #{inspect(invalid)}")

    apply? = Keyword.get(opts, :apply, false) and not Keyword.get(opts, :dry_run, false)

    Mix.shell().info("census: #{inspect(StringifiedImages.census())}")
    result = StringifiedImages.run(apply: apply?)

    for row <- result.rows do
      Mix.shell().info(
        "#{row.type}/#{row.doc_id}.#{row.field}: #{inspect(row.from)} -> #{inspect(row.to)}"
      )
    end

    Mix.shell().info(
      "scanned=#{result.scanned} changed=#{result.changed} applied=#{result.applied?}"
    )

    unless apply?,
      do: Mix.shell().info("Dry run — nothing was written. Re-run with --apply to write.")
  end
end
