defmodule BarkparkCloud.Repo.Migrations.CreateDeployRateAlertStates do
  @moduledoc """
  dr-bl-rate-notice — the EDGE STATE the fleet-rate notice is guarded on.

  One row per team. It exists because an edge cannot be derived from the data:
  the reading is a ROLLING 24h window, so "is this window worse than the one
  before it" answers YES on every tick of a fleet that has been red all day, and
  a notice keyed on that is a per-tick producer wearing a rate's clothes
  (charter D14). The consecutive counter and the `alerted_at` latch are the same
  shape `Registry`'s heartbeat already uses for `unreachable_count`.
  """
  use Ecto.Migration

  def change do
    create table(:deploy_rate_alert_states, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false

      add :verdict, :string, null: false
      add :consecutive_red, :integer, null: false, default: 0
      add :alerted_at, :utc_datetime_usec
      add :observed_at, :utc_datetime_usec
      add :last_pct, :float
      add :last_sample, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:deploy_rate_alert_states, [:team_id])
  end
end
