defmodule Barkpark.Repo.Migrations.AddLastVisitedAtToChatSessions do
  use Ecto.Migration

  @moduledoc """
  Studio Claude chat — the needs-you strip's "away" axis (epic studio-claude-chat,
  wave 12, slice scc-w12-needs-you).

  `last_visited_at` is when the admin LAST LOOKED at a session (stamped on open,
  on switch-away, and when a settle is watched on screen) — deliberately its own
  column, never derived from `last_active_at` (which the AGENT bumps on every
  append/status flip). The pair is the whole finished-while-away signal:
  `last_active_at > last_visited_at` on a settled (`active`/`exited`) session
  means something happened after you last looked.

  Nullable, NO backfill: a pre-migration row reads "we never saw you visit" and
  the strip stays honestly QUIET about it (nil never fakes an unseen-finish).
  New rows stamp it at creation (a session is created on the first send, while
  the user is looking at it).
  """

  def change do
    alter table(:chat_sessions) do
      add :last_visited_at, :utc_datetime_usec
    end
  end
end
