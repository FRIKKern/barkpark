defmodule Barkpark.Repo.Migrations.CreateSyncDeadLetters do
  use Ecto.Migration

  @moduledoc """
  Durable per-event quarantine for the one-way PULL sync subsystem
  (`Barkpark.Sync.DeadLetter`).

  One row per `{source, dataset, event_id}` capturing the full mutation
  envelope of a poison event (one that repeatedly fails to apply) BEFORE the
  cursor is allowed past it — so dead-lettering is an inspectable quarantine,
  never a silent skip. `event_id` is `bigint` to match `mutation_events.id`
  (bigserial). Dormant on a fresh install: nothing writes here until a sync
  source is configured + enabled AND an event fails to apply.
  """

  def change do
    create table(:sync_dead_letters, primary_key: false) do
      add :source, :string, null: false, primary_key: true
      add :dataset, :string, null: false, primary_key: true
      add :event_id, :bigint, null: false, primary_key: true
      add :attempts, :integer, null: false, default: 0
      add :status, :string, null: false, default: "pending"
      add :envelope, :map, null: false
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sync_dead_letters, [:source, :dataset, :status])
  end
end
