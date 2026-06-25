defmodule Mix.Tasks.Barkpark.Paper.BackfillBlockIds do
  @moduledoc """
  Backfill stable per-block ids onto LEGACY id-less paper blocks (R2 corpus fix).

  A stored block with no `id` projects to `bpId: null` in the continuous canvas;
  the next edit can't match it, mints a fresh id, and the server inserts a
  DUPLICATE block — editing such a paper corrupts it. This task repairs the
  existing corpus by adding ids to id-less blocks. It is ADDITIVE (ids only,
  nothing else changes), IDEMPOTENT (a re-run over a fixed corpus writes
  nothing), and TENANCY-COMPLETE (scans every workspace / project / dataset).

  ## Safe by default

  A bare invocation is a DRY RUN — it reports what WOULD change and writes
  nothing. Pass `--apply` to actually write.

      # report only (writes nothing) — the safe default
      mix barkpark.paper.backfill_block_ids
      mix barkpark.paper.backfill_block_ids --dry-run

      # write the ids
      mix barkpark.paper.backfill_block_ids --apply

  ## Recommended prod workflow

      mix barkpark.paper.backfill_block_ids            # dry-run: inspect counts
      mix barkpark.paper.backfill_block_ids --apply    # then apply
  """
  @shortdoc "Backfill ids onto id-less paper blocks (dry-run by default; --apply to write)"

  use Mix.Task

  alias Barkpark.Content.Papers.BackfillBlockIds

  @switches [dry_run: :boolean, apply: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown arguments: #{inspect(invalid)}")
    end

    # Safe default: write ONLY when --apply is explicitly given (and not negated
    # by --dry-run). Any other combination is a dry run.
    dry_run? = not (Keyword.get(opts, :apply, false) and not Keyword.get(opts, :dry_run, false))

    {:ok, stats} = BackfillBlockIds.run(dry_run: dry_run?)

    BackfillBlockIds.log_report(stats, fn line -> Mix.shell().info(line) end)

    if dry_run? do
      Mix.shell().info("\nDry run — nothing was written. Re-run with --apply to write.")
    end
  end
end
