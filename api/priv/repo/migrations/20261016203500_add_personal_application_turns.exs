defmodule Barkpark.Repo.Migrations.AddPersonalApplicationTurns do
  use Ecto.Migration

  def up do
    alter table(:chat_sessions), do: add(:application_state, :map)
    alter table(:chat_execution_leases), do: add(:application_turn, :map)

    create constraint(:chat_sessions, :chat_sessions_application_owner,
             check:
               "application_state IS NULL OR (owner_user_id IS NOT NULL AND jsonb_typeof(application_state) = 'object')"
           )

    drop constraint(:chat_execution_leases, :chat_execution_leases_provider)

    create constraint(:chat_execution_leases, :chat_execution_leases_provider,
             check: "provider IN ('claude', 'codex', 'application')"
           )

    create constraint(:chat_execution_leases, :chat_execution_leases_application_shape,
             check:
               "(provider = 'application' AND application_turn IS NOT NULL AND jsonb_typeof(application_turn) = 'object') OR (provider <> 'application' AND application_turn IS NULL)"
           )
  end

  def down do
    # Existing application data must be deliberately removed before rollback.
    # Do not silently reinterpret an application lease as a provider runtime.
    drop constraint(:chat_execution_leases, :chat_execution_leases_application_shape)
    drop constraint(:chat_execution_leases, :chat_execution_leases_provider)

    create constraint(:chat_execution_leases, :chat_execution_leases_provider,
             check: "provider IN ('claude', 'codex')"
           )

    drop constraint(:chat_sessions, :chat_sessions_application_owner)
    alter table(:chat_execution_leases), do: remove(:application_turn)
    alter table(:chat_sessions), do: remove(:application_state)
  end
end
