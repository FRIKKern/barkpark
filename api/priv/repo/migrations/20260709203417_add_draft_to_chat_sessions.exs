defmodule Barkpark.Repo.Migrations.AddDraftToChatSessions do
  use Ecto.Migration

  def change do
    alter table(:chat_sessions) do
      # Sticky per-session composer draft (charter D36c). Nullable text — the
      # unsent words the user left in the composer when they switched away, so a
      # reopen restores them verbatim. Captured on switch-away, not per-keystroke;
      # cleared on send. `:text` (not `:string`) — a draft can be a long paragraph.
      add :draft, :text
    end
  end
end
