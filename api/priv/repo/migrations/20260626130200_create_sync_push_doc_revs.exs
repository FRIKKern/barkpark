defmodule Barkpark.Repo.Migrations.CreateSyncPushDocRevs do
  use Ecto.Migration

  # Remote-rev ledger: the remote's last-known rev for each doc, used as the
  # CAS base (`ifRevisionID`) on push. The local row's `previous_rev` is the
  # LOCAL prior rev and is useless to the remote — hence this separate ledger.
  def change do
    create table(:sync_push_doc_revs, primary_key: false) do
      add :source, :string, primary_key: true
      add :dataset, :string, primary_key: true
      add :doc_id, :string, primary_key: true
      add :remote_rev, :string

      timestamps(type: :utc_datetime_usec)
    end
  end
end
