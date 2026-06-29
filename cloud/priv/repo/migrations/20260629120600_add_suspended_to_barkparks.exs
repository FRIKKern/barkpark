defmodule BarkparkCloud.Repo.Migrations.AddSuspendedToBarkparks do
  use Ecto.Migration

  # subscription-billing — the teeth. A suspension axis on barkparks, kept
  # SEPARATE from the health_status / agent_status axes: suspension is a billing
  # verdict, not a health fact (Coolify-anchor: Team::subscriptionEnded() flips
  # is_usable=false / is_reachable=false on every server when a subscription
  # lapses). On a billing lapse the control plane bulk-suspends every MANAGED
  # Barkpark a team owns; on recovery it lifts the flag. `suspended_reason` is
  # "billing_lapsed" | "billing_past_due".
  def change do
    alter table(:barkparks) do
      add :suspended, :boolean, null: false, default: false
      add :suspended_reason, :string
      add :suspended_at, :utc_datetime_usec
    end

    create index(:barkparks, [:team_id, :suspended])
  end
end
