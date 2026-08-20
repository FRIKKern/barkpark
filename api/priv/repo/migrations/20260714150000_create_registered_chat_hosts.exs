defmodule Barkpark.Repo.Migrations.CreateRegisteredChatHosts do
  use Ecto.Migration

  def change do
    create table(:registered_chat_hosts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :enrollment_hash, :binary, null: false
      add :enrollment_expires_at, :utc_datetime_usec, null: false
      add :enrolled_at, :utc_datetime_usec
      add :credential_hash, :binary
      add :credential_version, :integer, null: false, default: 0
      add :credential_expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :approved_roots, {:array, :text}, null: false, default: []
      add :protocol_version, :integer, null: false, default: 1
      add :capabilities, :map, null: false, default: %{}
      add :last_seen_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:registered_chat_hosts, [:workspace_id, :name],
             where: "revoked_at IS NULL"
           )

    create unique_index(:registered_chat_hosts, [:enrollment_hash])

    create unique_index(:registered_chat_hosts, [:credential_hash],
             where: "credential_hash IS NOT NULL"
           )

    create index(:registered_chat_hosts, [:workspace_id, :last_seen_at])

    create constraint(:registered_chat_hosts, :registered_chat_hosts_credential_state,
             check:
               "(enrolled_at IS NULL AND credential_hash IS NULL AND credential_version = 0) OR " <>
                 "(enrolled_at IS NOT NULL AND credential_hash IS NOT NULL AND credential_version > 0)"
           )
  end
end
