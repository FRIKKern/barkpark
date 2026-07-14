defmodule Barkpark.Repo.Migrations.CreateChatExecutionLeases do
  use Ecto.Migration

  def change do
    create table(:chat_execution_leases, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :host_id,
          references(:registered_chat_hosts, type: :uuid, on_delete: :delete_all),
          null: false

      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false
      add :session_id, references(:chat_sessions, type: :uuid, on_delete: :delete_all), null: false
      add :provider, :text, null: false
      add :epoch, :bigint, null: false, default: 1
      add :command_key, :text, null: false
      add :last_cursor, :bigint, null: false, default: 0
      add :status, :text, null: false, default: "leased"
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:chat_execution_leases, [:host_id, :command_key])
    create index(:chat_execution_leases, [:workspace_id, :session_id])

    create constraint(:chat_execution_leases, :chat_execution_leases_provider,
             check: "provider IN ('claude', 'codex')"
           )

    create constraint(:chat_execution_leases, :chat_execution_leases_status,
             check: "status IN ('leased', 'running', 'disconnected', 'completed', 'cancelled')"
           )

    create constraint(:chat_execution_leases, :chat_execution_leases_monotonic,
             check: "epoch > 0 AND last_cursor >= 0"
           )
  end
end
