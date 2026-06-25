defmodule Mix.Tasks.Barkpark.Paper.BackfillBlockIds do
  @moduledoc """
  Backfill canonical block SHAPE onto LEGACY papers — two passes:

    1. **id-less blocks** (R2 corpus fix) — a stored block with no `id` projects
       to `bpId: null` in the continuous canvas; the next edit can't match it,
       mints a fresh id, and the server inserts a DUPLICATE block — editing such
       a paper corrupts it. This pass adds ids to id-less blocks.
    2. **flat-string list items** (obsidian list-item-crash fix) — 7 legacy
       papers store list items as flat strings (`items:["a","b"]`) instead of the
       canonical inline arrays (`items:[[{type:text,value:a}],…]`). The editors
       now coerce a string item defensively (no crash), but the stored string
       shape no longer matches the editor's reconstructed inline-array shape — a
       spurious shape-flip patch on the first canvas load. This pass canonicalizes
       the stored items. It is render-IDENTICAL (a string item and its inline-
       array form render to byte-identical `body_html`).

  Both passes are ADDITIVE (only id + list-item SHAPE change; list item CONTENT is
  identical), IDEMPOTENT (a re-run over a fixed corpus writes nothing), and
  TENANCY-COMPLETE (scans every workspace / project / dataset).

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
  @shortdoc "Backfill ids + normalize flat-string list items on legacy papers (dry-run by default; --apply to write)"

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
