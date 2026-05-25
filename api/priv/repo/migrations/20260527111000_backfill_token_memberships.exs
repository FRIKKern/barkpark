defmodule Barkpark.Repo.Migrations.BackfillTokenMemberships do
  use Ecto.Migration

  # Tenancy auth backfill (w1-s3). For every EXISTING api_token, create a
  # workspace_memberships row binding the token (principal_id = token id,
  # principal_type = "api_token") to its already-backfilled workspace_id.
  #
  # Role is derived from the token's permissions array: any token whose
  # permissions include "admin" gets role "admin", every other token "member".
  #
  # Runs AFTER 20260527110200_backfill_default_tenancy (which sets
  # api_tokens.workspace_id), so workspace_id is non-NULL by the time we run.
  #
  # Idempotent: each insert is guarded by NOT EXISTS on the unique
  # (workspace_id, principal_type, principal_id) tuple, so re-running is a
  # no-op. Tokens with a NULL workspace_id (none, post-backfill) are skipped.
  def up do
    repo().query!(
      """
      INSERT INTO workspace_memberships
        (id, workspace_id, principal_type, principal_id, role, inserted_at, updated_at)
      SELECT
        gen_random_uuid(),
        t.workspace_id,
        'api_token',
        t.id,
        CASE WHEN 'admin' = ANY(t.permissions) THEN 'admin' ELSE 'member' END,
        now(),
        now()
      FROM api_tokens t
      WHERE t.workspace_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM workspace_memberships m
          WHERE m.workspace_id = t.workspace_id
            AND m.principal_type = 'api_token'
            AND m.principal_id = t.id
        )
      """,
      []
    )
  end

  # Safe down: remove only the api_token memberships this backfill could have
  # created (one per token, matched on principal id). The workspaces/tokens
  # themselves are owned by earlier migrations and are left untouched.
  def down do
    repo().query!(
      """
      DELETE FROM workspace_memberships m
      USING api_tokens t
      WHERE m.principal_type = 'api_token'
        AND m.principal_id = t.id
        AND m.workspace_id = t.workspace_id
      """,
      []
    )
  end
end
