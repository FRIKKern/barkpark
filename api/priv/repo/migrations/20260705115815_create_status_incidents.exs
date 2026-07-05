defmodule Barkpark.Repo.Migrations.CreateStatusIncidents do
  use Ecto.Migration

  # Public incident history for the status page. `component` scopes the affected
  # subsystem; `impact` is the severity; `status` walks the standard incident
  # lifecycle (investigating → identified → monitoring → resolved). `resolved_at`
  # is set on close; open incidents drive the overall status to degraded.
  def change do
    create table(:status_incidents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :component, :string
      add :impact, :string, null: false, default: "minor"
      add :status, :string, null: false, default: "investigating"
      add :body, :text
      add :started_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:status_incidents, [:started_at])
    create index(:status_incidents, [:resolved_at])
  end
end
