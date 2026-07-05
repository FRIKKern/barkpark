defmodule Mix.Tasks.Barkpark.Paper.DoctrineBackfill do
  @moduledoc """
  Backfill the PortableDoc **doctrine template** (a locked `role: "title"` heading
  at block 0, a locked `role: "featured"` image at block 1) onto LEGACY papers
  that predate the template (paper `pd-doctrine`, task pdd-t5).

  Enforcement is ADDITIVE, so nothing is bricked — but a legacy paper that never
  opens in the canvas also never gains the doctrine shape. This task scans the
  whole paper corpus and, per paper, reports whether it already conforms, plans
  the backfill (synthesize the title block, promote an existing image to the
  featured block), or reports why it cannot be fixed automatically.

  ## Safe by default — dry-run (D3)

  A bare invocation is a DRY RUN — it reports what WOULD change and writes
  NOTHING. Pass `--apply` to write.

      # report only (writes nothing) — the safe default
      mix barkpark.paper.doctrine_backfill
      mix barkpark.paper.doctrine_backfill --dry-run

      # perform the backfill
      mix barkpark.paper.doctrine_backfill --apply

  ## Human runbook (the apply is HUMAN-GATED)

  Do NOT run `--apply` against prod / guerrilla data unattended. Recommended order:

      # 1. Dry-run — inspect the per-paper report:
      #      already conforms / to backfill (title source + featured present-or-
      #      skipped) / UNFIXABLE with a reason.
      mix barkpark.paper.doctrine_backfill

      # 2. Review the UNFIXABLE list by hand. HTML-only papers and papers with no
      #    derivable title are reported, never guessed at.

      # 3. Apply on a snapshot / staging copy first, then re-run the dry-run to
      #    confirm everything now conforms (papers-to-backfill → 0 on the second
      #    dry-run — the migration is idempotent).
      mix barkpark.paper.doctrine_backfill --apply

  ## What `--apply` does per non-conforming, fixable paper

    * Synthesize the locked title block at index 0 (stamped per the template seed
      shape); text derived from `doc.title`, else the first heading. A block-0
      heading is REPLACED (no double title).
    * Promote an existing image asset (an `image` block with a non-blank `src`) to
      the locked featured block at index 1 — moved, not duplicated. NO asset ⇒ no
      featured block (assets are never invented; t13's placeholder handles the
      asset-less featured case).
    * Re-render `content["body_html"]` from the new blocks so the cache stays
      honest (render parity). Row scope columns are preserved.

  A paper that would still violate `Template.validate/1` after the plan is
  REFUSED (never written) and surfaced as UNFIXABLE. Conforming papers are left
  BYTE-IDENTICAL.
  """
  @shortdoc "Backfill the doctrine template (title@0 + featured@1) onto legacy papers (dry-run by default; --apply to write)"

  use Mix.Task

  alias Barkpark.Content.Papers.DoctrineBackfill

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

    {:ok, stats} = DoctrineBackfill.run(dry_run: dry_run?)

    DoctrineBackfill.log_report(stats, fn line -> Mix.shell().info(line) end)

    if dry_run? do
      Mix.shell().info("\nDry run — nothing was written. Re-run with --apply to write.")
    end
  end
end
