defmodule Mix.Tasks.Barkpark.Search.ReindexPublic do
  @moduledoc """
  Check, and on request repair, the public full-text index
  (`documents.public_search_vector`, owner ruling #20).

  A bare run is a DRY RUN: it counts, per type, the documents whose stored
  public vector differs from what the trigger computes now, and writes nothing.

      mix barkpark.search.reindex_public                 # count only
      mix barkpark.search.reindex_public --type memo     # one type
      mix barkpark.search.reindex_public --apply         # recompute the stale rows

  The triggers from migration 20261003200000 keep the column current on every
  document and schema write, so on a healthy box the count is zero. A non-zero
  count means rows were written with triggers disabled (a raw restore, an
  import under `session_replication_role = replica`); `--apply` recomputes
  exactly those rows and writes nothing else. Running it twice is a no-op.
  """
  @shortdoc "Count (default) or recompute stale public search vectors"

  use Mix.Task

  alias Barkpark.Search.PublicIndex

  @switches [apply: :boolean, dry_run: :boolean, type: :string]

  @impl Mix.Task
  def run(args) do
    # Same narrowed boot as the other one-shots (barkpark.preview.backfill):
    # Repo only — no endpoint, no Oban.
    Mix.Task.run("app.config")
    Barkpark.OneShot.boot!()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("Unknown arguments: #{inspect(invalid)}")

    apply? = Keyword.get(opts, :apply, false) and not Keyword.get(opts, :dry_run, false)
    scope = Keyword.take(opts, [:type])

    rows = PublicIndex.census(scope)
    total = rows |> Enum.map(& &1.stale) |> Enum.sum()

    Enum.each(rows, fn %{type: t, stale: n} -> Mix.shell().info("#{t}\t#{n} stale") end)
    Mix.shell().info("total\t#{total} stale")

    cond do
      not apply? ->
        Mix.shell().info("Dry run: nothing was written. Re-run with --apply to recompute.")

      total == 0 ->
        Mix.shell().info("Nothing to recompute.")

      true ->
        n = PublicIndex.reindex(scope)
        Mix.shell().info("Recomputed #{n} public search vectors.")
    end
  end
end
