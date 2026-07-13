defmodule Barkpark.Repo.Migrations.AddOwnerWorkspaceIdToChatSessions do
  use Ecto.Migration

  # Connectors epic, wave 1 P0 (charter D14/D15) — the chat_sessions TENANT SEAM.
  # `owner_workspace_id` records the workspace that owns a chat session so a
  # channel connector (Slack/Discord/Telegram/…) resumes ONLY its own tenant's
  # memory. ADDITIVE + greenfield — mirrors 20260629150300_add_owner_id_to_documents:
  # the column is nullable with NO FK and NO default, so every pre-migration row
  # stays NULL. A NULL row never matches an equality (`owner_workspace_id == ^ws`),
  # so a workspace-scoped caller can never see a legacy/global session; only the
  # `:global` admin superuser path (no filter) reads them. No FK to `workspaces`
  # on purpose: the isolation core fails closed on a NULL owner rather than
  # cascading, and a session may predate/outlive a given workspace row.
  #
  # The partial composite index serves the scoped sidebar query
  # (`owner_workspace_id == ^ws` ORDER BY last_active_at, active shelf only) —
  # the tenant-scoped mirror of the existing `[:status, :last_active_at]` index.
  def change do
    alter table(:chat_sessions) do
      add :owner_workspace_id, :binary_id, null: true
    end

    create index(:chat_sessions, [:owner_workspace_id, :last_active_at],
             where: "archived_at IS NULL",
             name: :chat_sessions_workspace_active_last_active_at_index
           )
  end
end
