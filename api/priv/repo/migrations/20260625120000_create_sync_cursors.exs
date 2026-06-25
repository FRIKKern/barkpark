defmodule Barkpark.Repo.Migrations.CreateSyncCursors do
  use Ecto.Migration

  @moduledoc """
  Per-source high-water mark for the one-way PULL sync subsystem
  (`Barkpark.Sync.Cursor`).

  One row per `{source, dataset}` carrying the largest applied `event_id` — the
  `Last-Event-ID` resume point and the Phase-1 echo-dedup gate. `event_id` is
  `bigint` to match `mutation_events.id` (bigserial). Dormant on a fresh
  install: nothing writes here until a sync source is configured + enabled.
  """

  def change do
    create table(:sync_cursors, primary_key: false) do
      add :source, :string, null: false, primary_key: true
      add :dataset, :string, null: false, primary_key: true
      add :event_id, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end
  end
end
