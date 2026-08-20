defmodule BarkparkCloud.Repo.Migrations.DeploymentDetailToText do
  use Ecto.Migration

  # cch-w34-s5: `deployments.detail` was `add :detail, :string` = varchar(255)
  # (20260703100000), but every writer of it validates through the SHARED
  # `Registry.validate_console_line/1`, whose cap is 2 KB. So a caption of
  # 256..2_000 characters was neither refused NOR trimmed: it reached
  # `Repo.update/1` and raised `Postgrex.Error 22001`, out of a function whose
  # @doc promises telemetry that "NEVER affects the build's outcome" and through
  # a route documenting only 200/404/422.
  #
  # It is reachable with ordinary product data: the builder narrates
  # `"Starting your build (%s)…"` around `git_ref` (internal/builder/builder.go),
  # +23 characters over the ref, and `git_ref` is itself varchar(255) with no
  # validate_length — so any ref of 233..255 chars inserts fine and then makes
  # its OWN caption overflow.
  #
  # Widening rather than capping at 255: a detail-specific 255 cap would keep
  # captions silently cut, which is the same lie in a quieter voice. The shared
  # 2 KB validator becomes the single bound. Same remedy provision_jobs.error
  # took in 20260702130000.
  #
  # varchar(n) -> text is METADATA-ONLY in Postgres (no table rewrite since 9.1):
  # verified on this database — relfilenode unchanged across the ALTER — so it is
  # safe on the live deployments table on an auto-deploying surface.
  def up do
    alter table(:deployments) do
      modify :detail, :text
    end
  end

  # Reversible, but NOT lossless: rows whose caption already exceeds 255 chars
  # would fail the narrowing cast, which is the correct loud failure — a down
  # that silently truncated stored captions would be the same defect again.
  def down do
    alter table(:deployments) do
      modify :detail, :string
    end
  end
end
