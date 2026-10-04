defmodule BarkparkCloud.Repo.Migrations.AddEnqueuedOwnerToProvisionJobs do
  use Ecto.Migration

  # task-0cf611238d4ad597 CQ7c (owner ruling #36). The agent-key, attach-domain
  # and enable-apply jobs SSH to a barkpark's host as root. The job now records
  # which team owned the row and which host it had when the job was enqueued,
  # and the claim re-checks both before handing the job to the worker.
  #
  # ADDITIVE AND NULLABLE: rows enqueued before this migration keep NULL, and
  # the claim treats NULL as "no snapshot". It skips the two equality checks
  # and still runs the live "is this host another team's box?" check. No
  # backfill, no default, nothing rewritten.
  def change do
    alter table(:provision_jobs) do
      add :enqueued_team_id, :binary_id
      add :enqueued_host, :string
    end
  end
end
