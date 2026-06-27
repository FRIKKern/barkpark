defmodule BarkparkCloud.Repo.Migrations.AddProvisionJobsAttempts do
  use Ecto.Migration

  # Stale-claim recovery (control-plane robustness fix).
  #
  # The bug this enables a fix for: claim_next_job only ever selected
  # status="pending", and nothing ever reaped a "claimed" row. So a worker that
  # claimed a job and then crashed (or whose succeed/fail report failed in
  # transit) wedged that job in "claimed" forever — the box was never (re)built
  # and the customer's barkpark stayed provisioning indefinitely.
  #
  # The fix re-claims a "claimed" row once it has been claimed for longer than the
  # worker's provision timeout + margin, and bounds the retries so a permanently
  # failing job stops looping. `attempts` is that bound: it counts how many times
  # the row has been (re)claimed, so the reaper can fail it once it has burned
  # through @max_provision_attempts.
  #
  # Reversible: the down side just drops the column.
  def change do
    alter table(:provision_jobs) do
      add :attempts, :integer, null: false, default: 0
    end
  end
end
