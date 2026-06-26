defmodule Barkpark.Repo.Migrations.CreateSyncPushConflicts do
  use Ecto.Migration

  # Durable per-event conflict quarantine for PUSH. A push that the remote
  # rejects (stale-base CAS, fenced claim, resource conflict) PRESERVES the
  # local loser here (full envelope, INSERT-only) so it is never silently
  # overwritten. write-then-advance: recorded durably, THEN the cursor advances
  # past it (mirrors the pull dead_letter carve-out). Full UX is P3.
  def change do
    create table(:sync_push_conflicts, primary_key: false) do
      add :source, :string, primary_key: true
      add :dataset, :string, primary_key: true
      add :event_id, :bigint, primary_key: true
      add :doc_id, :string
      add :type, :string
      add :kind, :string
      add :local_document, :map
      add :expected_remote_rev, :string
      add :actual_remote_rev, :string
      add :status, :string, default: "open"
      add :last_error, :string

      timestamps(type: :utc_datetime_usec)
    end
  end
end
