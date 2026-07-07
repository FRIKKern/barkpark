defmodule BarkparkCloud.Repo.Migrations.AddAutoupdateToBarkparks do
  use Ecto.Migration

  # Fleet autoupdate (isu-w4): the per-instance policy the AutoupdateRolloutWorker
  # reads to decide whether a `behind` instance may be self-updated automatically.
  #
  # Default is OPT-OUT: `autoupdate_enabled` defaults to TRUE so a managed
  # instance rides new blessed releases unless its team explicitly opts out — the
  # "never think about updates" promise. `autoupdate_paused` is the temporary
  # escape hatch (a team pauses a rollout without losing its enabled setting);
  # `pinned_release` freezes an instance on its current version (any non-NULL
  # value makes it ineligible, whatever the release string). `autoupdate_triggered_at`
  # is the in-flight marker: set when the rollout worker fires a self-update, so
  # the staged rollout can health-gate the wave before advancing, and cleared
  # once the instance settles current (or the run is reaped).
  def change do
    alter table(:barkparks) do
      add :autoupdate_enabled, :boolean, null: false, default: true
      add :autoupdate_paused, :boolean, null: false, default: false
      add :pinned_release, :string
      add :autoupdate_triggered_at, :utc_datetime_usec
    end

    # The rollout worker's hot query filters on these; a partial index over the
    # eligible-and-not-in-flight rows keeps the per-tick scan cheap as the fleet
    # grows (mirrors the update_checkable set's shape).
    create index(:barkparks, [:autoupdate_enabled, :autoupdate_paused],
             name: :barkparks_autoupdate_policy_idx
           )
  end
end
