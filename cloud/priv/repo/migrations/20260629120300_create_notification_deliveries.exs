defmodule BarkparkCloud.Repo.Migrations.CreateNotificationDeliveries do
  use Ecto.Migration

  # The durable send record for every notification the dispatcher emits — modeled
  # on api/'s `webhook_deliveries` (status / attempts / last_error). Coolify leans
  # on Laravel's `failed_jobs` table for this; a CMS-grade control plane wants a
  # first-class, team-scoped delivery log instead. v1 sends synchronously and
  # writes one row per recipient; the (attempts, last_error) shape is the future
  # retry seam for when cloud/ gains Oban.
  def change do
    create table(:notification_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false

      # The member email it went to.
      add :recipient, :string, null: false
      # provision_failed | invite | password_reset | ...
      add :event, :string, null: false
      # email-only for v1; the column leaves the door open for chat channels.
      add :channel, :string, null: false, default: "email"
      # alert (per-team transport, toggle-gated) | transactional (always platform)
      add :kind, :string, null: false, default: "alert"
      # pending | sent | failed
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:notification_deliveries, [:team_id])
    create index(:notification_deliveries, [:team_id, :inserted_at])
  end
end
