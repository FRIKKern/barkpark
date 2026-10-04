defmodule Mix.Tasks.Barkpark.Shape.NaiveDatetimes do
  @moduledoc """
  Census and rewrite of zone-less datetime values (owner ruling #46). DRY RUN
  by default; `--apply` writes. See
  `Barkpark.Content.ShapeMigrations.NaiveDatetimes`.

      mix barkpark.shape.naive_datetimes                       # census only
      mix barkpark.shape.naive_datetimes --offset +02:00       # dry run: every rewrite
      mix barkpark.shape.naive_datetimes --offset +02:00 --apply
  """
  @shortdoc "Count/rewrite zone-less datetime values as UTC instants (dry-run by default)"

  use Mix.Task

  alias Barkpark.Content.ShapeMigrations.NaiveDatetimes

  @switches [apply: :boolean, dry_run: :boolean, offset: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("Unknown arguments: #{inspect(invalid)}")

    Mix.shell().info("census: #{inspect(NaiveDatetimes.census())}")

    case Keyword.get(opts, :offset) do
      nil ->
        Mix.shell().info("No --offset given: census only. Nothing was written.")

      offset ->
        apply? = Keyword.get(opts, :apply, false) and not Keyword.get(opts, :dry_run, false)
        result = NaiveDatetimes.run(offset: offset, apply: apply?)

        for row <- result.rows do
          Mix.shell().info("#{row.type}/#{row.doc_id}.#{row.field}: #{row.from} -> #{row.to}")
        end

        Mix.shell().info("rows=#{length(result.rows)} applied=#{result.applied?}")

        unless apply?,
          do: Mix.shell().info("Dry run — nothing was written. Re-run with --apply to write.")
    end
  end
end
