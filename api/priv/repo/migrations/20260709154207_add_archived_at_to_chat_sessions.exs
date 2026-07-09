defmodule Barkpark.Repo.Migrations.AddArchivedAtToChatSessions do
  use Ecto.Migration

  @moduledoc """
  Studio Claude chat — session ARCHIVE shelf (epic studio-claude-chat, wave 2).

  Archive is a lifecycle-orthogonal concern, so it is its OWN nullable column,
  never a `status` value: `status` (active|working|exited) is the liveness axis
  (`update_status/2`/`mark_exited/1` would clobber an archive flag every time a
  process transitioned). A NULL `archived_at` means "on the shelf's active side";
  a timestamp means "archived at that moment".

  The sidebar's default query lists ONLY non-archived sessions, recency-desc — a
  PARTIAL index on `last_active_at WHERE archived_at IS NULL` keeps that hot path
  lean as the archived shelf grows without bound.
  """

  def change do
    alter table(:chat_sessions) do
      add :archived_at, :utc_datetime_usec
    end

    create index(:chat_sessions, [:last_active_at],
             where: "archived_at IS NULL",
             name: :chat_sessions_active_last_active_at_index
           )
  end
end
