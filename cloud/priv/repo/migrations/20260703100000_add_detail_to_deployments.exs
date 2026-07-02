defmodule BarkparkCloud.Repo.Migrations.AddDetailToDeployments do
  use Ecto.Migration

  # dwb-19: the LIVE sub-caption for a Deployment — the build-side twin of the
  # provision step caption. The off-box builder reports a plain-language caption
  # at each real sub-boundary (fetch source → build → save image → hand off);
  # unlike the append-only console, `detail` is a SINGLE latest-wins string the
  # site-detail deploy row renders under the deployment's status pill while it is
  # active. One text column on the existing row (no new table) — surfaced on the
  # deployment JSON as :detail. Best-effort telemetry: a missing caption just
  # means no sub-line under the status.
  def up do
    alter table(:deployments) do
      add :detail, :string
    end
  end

  def down do
    alter table(:deployments) do
      remove :detail
    end
  end
end
