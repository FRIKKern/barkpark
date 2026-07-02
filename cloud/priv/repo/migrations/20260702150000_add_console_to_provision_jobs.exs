defmodule BarkparkCloud.Repo.Migrations.AddConsoleToProvisionJobs do
  use Ecto.Migration

  # dwb-16: LIVE provisioning console. The Go worker tees the create→live chain +
  # content bootstrap narration (already redacted) to a new internal endpoint;
  # each line is APPENDED to this array (append-only, capped server-side at ~300
  # lines, oldest dropped) so the /new progress screen renders a live console —
  # and a freshly-loaded page recovers mid-provision console state after a refresh
  # (the array survives independent of the coarse SSE invalidation tick).
  #
  # Each element: %{"line" => "configure: done", "at" => "2026-07-02T…Z"}.
  # Same cheapest-persistence choice as :steps — one jsonb[] column on the existing
  # row, no new table, no join — surfaced on the barkpark row json as
  # :provision_console.
  def up do
    alter table(:provision_jobs) do
      add :console, {:array, :map}, null: false, default: []
    end
  end

  def down do
    alter table(:provision_jobs) do
      remove :console
    end
  end
end
