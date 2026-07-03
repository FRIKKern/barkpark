defmodule Barkpark.Repo.Migrations.AddLastLatencyMsToWebhookDeliveries do
  use Ecto.Migration

  # Wall-clock milliseconds of the most recent HTTP POST attempt for this
  # delivery — the latency the operator console surfaces per delivery row.
  # Nullable: pre-existing rows (and pending/never-attempted deliveries) have
  # no measured latency.
  def change do
    alter table(:webhook_deliveries) do
      add :last_latency_ms, :integer
    end
  end
end
