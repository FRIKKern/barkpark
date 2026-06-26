defmodule Barkpark.Repo.Migrations.CreateSyncPushCursors do
  use Ecto.Migration

  # PUSH high-water mark — a SEPARATE monotonic cursor in LOCAL
  # mutation_events.id space (NEVER the pull cursor: the two live in
  # incomparable id-spaces — pull = remote Last-Event-ID; push = local id).
  def change do
    create table(:sync_push_cursors, primary_key: false) do
      add :source, :string, primary_key: true
      add :dataset, :string, primary_key: true
      add :event_id, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end
  end
end
