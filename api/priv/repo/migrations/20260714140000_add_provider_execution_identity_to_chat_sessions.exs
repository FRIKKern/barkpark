defmodule Barkpark.Repo.Migrations.AddProviderExecutionIdentityToChatSessions do
  use Ecto.Migration

  @provider_constraint :chat_sessions_provider_check
  @execution_target_constraint :chat_sessions_execution_target_check
  @execution_host_constraint :chat_sessions_execution_host_check
  @provider_session_constraint :chat_sessions_provider_session_id_check

  def up do
    alter table(:chat_sessions) do
      add :provider, :string, null: false, default: "claude"
      add :execution_target, :string, null: false, default: "managed"
      add :execution_host_id, :binary_id
      add :provider_session_id, :string
    end

    # The public Barkpark UUID historically doubled as Claude's native resume
    # key. Preserve that identity deterministically for every existing row while
    # allowing new providers to persist their opaque native id after startup.
    execute("UPDATE chat_sessions SET provider_session_id = id::text")

    create constraint(:chat_sessions, @provider_constraint,
             check: "provider IN ('claude', 'codex')"
           )

    create constraint(:chat_sessions, @execution_target_constraint,
             check: "execution_target IN ('managed', 'registered_host')"
           )

    create constraint(:chat_sessions, @execution_host_constraint,
             check:
               "(execution_target = 'managed' AND execution_host_id IS NULL) OR " <>
                 "(execution_target = 'registered_host' AND execution_host_id IS NOT NULL)"
           )

    create constraint(:chat_sessions, @provider_session_constraint,
             check: "provider_session_id IS NULL OR length(btrim(provider_session_id)) > 0"
           )
  end

  def down do
    drop constraint(:chat_sessions, @provider_session_constraint)
    drop constraint(:chat_sessions, @execution_host_constraint)
    drop constraint(:chat_sessions, @execution_target_constraint)
    drop constraint(:chat_sessions, @provider_constraint)

    alter table(:chat_sessions) do
      remove :provider_session_id
      remove :execution_host_id
      remove :execution_target
      remove :provider
    end
  end
end
