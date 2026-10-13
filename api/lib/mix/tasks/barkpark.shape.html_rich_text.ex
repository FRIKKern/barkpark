defmodule Mix.Tasks.Barkpark.Shape.HtmlRichText do
  @moduledoc """
  Census and convert of plain rich text stored as HTML (owner ruling #44).
  DRY RUN by default; `--apply` writes. See
  `Barkpark.Content.ShapeMigrations.HtmlRichText` for what changes and the
  release (`bin/barkpark eval`) form.

      mix barkpark.shape.html_rich_text           # census + dry run
      mix barkpark.shape.html_rich_text --apply   # write
  """
  @shortdoc "Count HTML rich text and convert it to Portable Text (dry-run by default)"

  use Mix.Task

  alias Barkpark.Content.ShapeMigrations.HtmlRichText

  @switches [apply: :boolean, dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("Unknown arguments: #{inspect(invalid)}")

    apply? = Keyword.get(opts, :apply, false) and not Keyword.get(opts, :dry_run, false)

    Mix.shell().info("census: #{inspect(HtmlRichText.census())}")
    result = HtmlRichText.run(apply: apply?)

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
