defmodule Barkpark.Repo.Migrations.CreateWebhookDeliveries do
  use Ecto.Migration

  def change do
    create table(:webhook_deliveries) do
      add :endpoint_id, references(:webhooks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :event_id, references(:mutation_events, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_status_code, :integer
      add :last_error_text, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webhook_deliveries, [:endpoint_id, :event_id])
    create index(:webhook_deliveries, [:status])
  end
end
