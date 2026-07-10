defmodule Mix.Tasks.Barkpark.Paper.CompositionMigrate do
  @moduledoc """
  Migrate legacy composite blocks — `cards` / `notes` / `pipeline` — to their
  ratified widget compositions (`section{grid}` of `card` / `note` / `stage`
  widgets) across the whole paper corpus (epic `composition-doctrine`, task
  `ct-rollout`).

  ## Safe by default — dry-run

  A bare invocation is a DRY RUN — it reports what WOULD change and writes
  NOTHING. Pass `--apply` to write.

      # report only (writes nothing) — the safe default
      mix barkpark.paper.composition_migrate
      mix barkpark.paper.composition_migrate --dry-run

      # perform the migration
      mix barkpark.paper.composition_migrate --apply

  ## The safety law

  Every migrated block's per-item re-render is PROVEN against the legacy render
  by executing the real emitters before anything is written: notes/pipeline
  items must be BYTE-EQUAL; cards items must match under the two-rule model-B
  chrome map (`bp-card__t` → `<h2>`, `bp-card__d` → `<p>` — the graduated card
  contract). A block that cannot be proven is SKIPPED and reported with its
  reason, never force-migrated. Intentional fixtures (`portabledoc-showcase`)
  and wave papers are EXCLUDED. Full contract:
  `Barkpark.Content.Papers.CompositionMigration`.

  ## Human runbook (the apply is HUMAN-GATED)

  Do NOT run `--apply` against prod / guerrilla data unattended:

      # 1. Dry-run — inspect every planned block (its parity proof) and every
      #    skip (its reason). Writes nothing.
      mix barkpark.paper.composition_migrate

      # 2. Review the SKIPPED list and the pipeline wrapper notes (arrows and
      #    horizontal scroll are legacy chrome and do not survive) by hand.

      # 3. Apply, then re-run the dry-run to confirm papers-to-migrate → 0
      #    (the migration is idempotent).
      mix barkpark.paper.composition_migrate --apply
  """
  @shortdoc "Migrate legacy cards/notes/pipeline blocks to widget compositions (dry-run by default; --apply to write)"

  use Mix.Task

  alias Barkpark.Content.Papers.CompositionMigration

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

    {:ok, stats} = CompositionMigration.run(dry_run: dry_run?)

    CompositionMigration.log_report(stats, fn line -> Mix.shell().info(line) end)

    if dry_run? do
      Mix.shell().info("\nDry run — nothing was written. Re-run with --apply to write.")
    end
  end
end
