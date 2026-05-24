defmodule Mix.Tasks.Barkpark.Media.Backfill do
  @moduledoc """
  Create missing `mediaAsset` documents for existing `media_files` rows.

      mix barkpark.media.backfill
      mix barkpark.media.backfill --dataset production
      mix barkpark.media.backfill --dry-run
  """
  @shortdoc "Backfill mediaAsset documents for existing uploads"

  use Mix.Task

  @switches [dataset: :string, dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown arguments: #{inspect(invalid)}")
    end

    dataset = Keyword.get(opts, :dataset, "production")
    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      Mix.shell().info("Dry run — no documents will be created.")
    end

    case Barkpark.Plugins.Media.Assets.backfill(dataset, dry_run: dry_run?) do
      {:ok, stats} ->
        Mix.shell().info("""
        mediaAsset backfill (#{dataset}):
          created: #{stats.created}
          skipped: #{stats.skipped} (already linked)
          errors:  #{length(stats.errors)}
        """)

        if stats.errors != [] do
          Mix.shell().error("Failures:\n#{inspect(stats.errors, pretty: true)}")
          System.halt(1)
        end
    end
  end
end
