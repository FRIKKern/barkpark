defmodule BarkparkCloud.Repo.Migrations.AddStepsToProvisionJobs do
  use Ecto.Migration

  # dwb-14: honest SSE progress narration. The Go worker reports step transitions
  # (create/secure/configure/content/ready → started|done|failed) to a new
  # internal endpoint; each is APPENDED to this array on the job row so a
  # freshly-loaded /new page can render mid-provision state after a refresh (the
  # array survives independent of the coarse SSE invalidation tick).
  #
  # Each element: %{"step" => "create", "status" => "started",
  #                 "detail" => nil, "at" => "2026-07-02T…Z"}.
  # Cheapest persistence that survives a refresh: one column on the existing row,
  # no new table, no join — the barkpark row json surfaces it as :provision_steps.
  # A jsonb[] array (the same PG-native array convention sites.domains uses) so an
  # append is a plain Elixir list write, no fragment juggling.
  def up do
    alter table(:provision_jobs) do
      add :steps, {:array, :map}, null: false, default: []
    end
  end

  def down do
    alter table(:provision_jobs) do
      remove :steps
    end
  end
end
