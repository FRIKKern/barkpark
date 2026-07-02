defmodule BarkparkCloud.Repo.Migrations.ProvisionJobErrorToText do
  use Ecto.Migration

  # The worker's compound fallback-ladder error ("failed on all 5 candidate
  # type/locations: ...") exceeds varchar(255), so the /fail report itself
  # 500'd and the job could never leave "claimed" — an eternal stall instead
  # of a clean FAILED with one-click Retry (bit the first live stopwatch run).
  # deployments.failure_reason is already :text; align provision_jobs.error.
  def up do
    alter table(:provision_jobs) do
      modify :error, :text
    end
  end

  def down do
    alter table(:provision_jobs) do
      modify :error, :string
    end
  end
end
