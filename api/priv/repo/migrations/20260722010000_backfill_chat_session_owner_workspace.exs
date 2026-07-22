defmodule Barkpark.Repo.Migrations.BackfillChatSessionOwnerWorkspace do
  @moduledoc """
  Backfill `chat_sessions.owner_workspace_id` for NULL-owned rows (herd charter
  D43h seal blocker): every pre-fix session-create path stamped NULL, and
  `BlockedSweeper` is deliberately fail-closed on NULL owners — so no existing
  session could ever fire `chat_blocked`. Create-time stamping is fixed in the
  same change; this claims the legacy rows for the seeded Default Workspace
  (the workspace an admin-created session now stamps by fallback).

  Shape: ONE set-based UPDATE with a non-correlated scalar subquery (evaluated
  once) — never a per-row correlated content migration (slow-migration law).
  On an instance with no Default Workspace the UPDATE is a no-op and the rows
  stay NULL-owned (instance-global), exactly as before.

  One-way: which rows were NULL before the backfill is not recoverable, so
  `down` is a documented no-op.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE chat_sessions
    SET owner_workspace_id = (SELECT id FROM workspaces WHERE slug = 'default' LIMIT 1)
    WHERE owner_workspace_id IS NULL
      AND EXISTS (SELECT 1 FROM workspaces WHERE slug = 'default')
    """)
  end

  def down do
    # Irreversible by design: pre-backfill NULLs are indistinguishable from
    # rows that were legitimately stamped at create. Reverting the stamp would
    # orphan real tenant sessions, so down is a no-op.
    :ok
  end
end
