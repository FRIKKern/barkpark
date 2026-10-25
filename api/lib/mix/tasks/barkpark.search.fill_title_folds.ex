defmodule Mix.Tasks.Barkpark.Search.FillTitleFolds do
  @moduledoc """
  Store the title search folds of documents written before migration
  20261016190000 (`Barkpark.Search.SearchSlots.fill_title_folds/1`).

  An operator step, never run by a deploy: searches are right without it, only
  slower on rows that have no stored folds.

      # count only (writes nothing): the safe default
      mix barkpark.search.fill_title_folds

      # write, in batches of 1,000 rows
      mix barkpark.search.fill_title_folds --apply
      mix barkpark.search.fill_title_folds --apply --batch 500
  """
  @shortdoc "Store title search folds on older documents (count by default; --apply to write)"

  use Mix.Task

  alias Barkpark.Search.SearchSlots

  @switches [apply: :boolean, batch: :integer]

  @impl Mix.Task
  def run(args) do
    # Not `app.start`: a one-shot must not bind the live slot's port
    # (task-557cf9a71e949768). OneShot.boot!/0 starts the narrowed tree.
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("Unknown arguments: #{inspect(invalid)}")

    stats =
      SearchSlots.fill_title_folds(
        apply: Keyword.get(opts, :apply, false),
        batch: Keyword.get(opts, :batch, 1_000),
        log: fn line -> Mix.shell().info(line) end
      )

    Mix.shell().info(
      "rows without title folds: #{stats.to_fill}; written: #{stats.written}; #{stats.ms} ms"
    )

    unless Keyword.get(opts, :apply, false),
      do: Mix.shell().info("Dry run: nothing was written. Re-run with --apply to write.")
  end
end
