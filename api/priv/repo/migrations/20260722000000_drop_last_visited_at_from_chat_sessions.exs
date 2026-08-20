defmodule Barkpark.Repo.Migrations.DropLastVisitedAtFromChatSessions do
  use Ecto.Migration

  @moduledoc """
  Studio Claude chat — retire the wave-12 read-tracking column (epic herd-layer,
  wave 4, slice herd-bl-lastvisited-drop). This is the CONTRACT half of the
  blue/green expand→contract pair; herd-bl-readtracking-retire (#5562) was the
  EXPAND half.

  `chat_sessions.last_visited_at` (added 20260710120000) held the admin's
  "last looked at this session" timestamp — the away-axis of the needs-you strip.
  The herd doctrine retired that read/seen bookkeeping: #5562 removed the schema
  field and every code reference, and it is MERGED to main and DEPLOYED to
  guerrilla (deploy.yml instance job success). With no live code on either slot
  naming the column, this catalog-only DROP COLUMN is safe.

  Slow-migration law: the column is nullable, has no default, no index, and no
  constraint — so DROP COLUMN is a metadata-only catalog edit. Instant, no table
  rewrite, no per-row content migration.

  DOWN IS LOSSY (documented, intentional). The reversal below re-adds the column
  as nullable `:utc_datetime_usec`, but the data that lived in it is GONE and
  UNRECOVERABLE — a rolled-back database gets an all-NULL column, which reads as
  the honest "we never saw you visit" state the original migration defined for
  pre-existing rows. There is no backfill and none is possible; the read-tracking
  signal was retired by design.
  """

  def change do
    alter table(:chat_sessions) do
      remove :last_visited_at, :utc_datetime_usec
    end
  end
end
