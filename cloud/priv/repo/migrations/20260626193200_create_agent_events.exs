defmodule BarkparkCloud.Repo.Migrations.CreateAgentEvents do
  use Ecto.Migration

  # The append-only agent event stream for a Barkpark — what the on-box agent
  # reported (health beat, status flip, disk-space report) plus the control
  # plane's own verify runs. The live vocabulary is `AgentEvent.types/0`, never
  # this comment: `backup` and `TLS renewal` were named here at this table's
  # creation and were struck in cch-w51-bl, having never had a producer.
  # Belongs to a
  # Barkpark. APPEND-ONLY: only inserted_at, no updated_at (an event is a fact
  # at a point in time, written once). `payload` is jsonb so each event `type`
  # carries its own shape with no per-kind migration. Indexed by
  # (barkpark_id, inserted_at desc) to serve `recent_events/2` cheaply.
  def change do
    create table(:agent_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :barkpark_id, references(:barkparks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :type, :string, null: false
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:agent_events, [:barkpark_id, :inserted_at])
  end
end
