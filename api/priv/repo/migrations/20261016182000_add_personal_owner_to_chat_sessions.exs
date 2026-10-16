defmodule Barkpark.Repo.Migrations.AddPersonalOwnerToChatSessions do
  use Ecto.Migration

  def change do
    alter table(:chat_sessions) do
      add :owner_user_id, references(:users, type: :uuid, on_delete: :delete_all)
    end

    create constraint(:chat_sessions, :chat_sessions_personal_workspace_check,
             check: "owner_user_id IS NULL OR owner_workspace_id IS NOT NULL"
           )

    create index(:chat_sessions, [:owner_workspace_id, :owner_user_id, :last_active_at],
             where: "owner_user_id IS NOT NULL",
             name: :chat_sessions_personal_owner_index
           )
  end
end
