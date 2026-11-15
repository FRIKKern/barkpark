defmodule Barkpark.Repo.Migrations.AddBotFolderToChatSessions do
  @moduledoc """
  task-ed93b8c0ab2b44b8: a registered-host chat session can name a bot folder,
  so several bots share one computer, each in its own folder under the host's
  approved root (`Barkpark.StudioChat.BotFolder`).

  Additive only. One nullable column with no default, so Postgres adds it
  without rewriting the table, and every existing row reads NULL: no folder,
  its turns run where they ran. No backfill, and no existing row is touched.

  The CHECK holds the same single-segment rule as the changeset, so a value
  written around `Session.create_changeset/2` still cannot carry a path to a
  person's computer. It is added NOT VALID: Postgres then skips the scan of
  existing rows (they are all NULL, which passes) and takes its lock only for
  the catalog change, while every insert and update from now on is checked.
  """
  use Ecto.Migration

  def change do
    alter table(:chat_sessions) do
      add :bot_folder, :string
    end

    create constraint(:chat_sessions, :chat_sessions_bot_folder_check,
             check: "bot_folder ~ '^[a-z0-9][a-z0-9-]{0,39}$'",
             validate: false
           )
  end
end
