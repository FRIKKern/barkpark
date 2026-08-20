defmodule Barkpark.Repo.Migrations.BackfillUserOwnerMemberships do
  @moduledoc """
  Grant the HUMAN behind an owning api_token a `"user"`-typed owner membership
  on every workspace that has one and does not already carry it (gyldendal
  field report M4 / charter D15).

  Every workspace ever created over `POST /api/workspaces` got exactly ONE
  membership row, `principal_type = 'api_token'` — the `%User{}` head of
  `Tenancy.create_workspace_with_owner/2` was unreachable from every caller.
  So the person who created a workspace is not a member of it: `member?/2`
  false, `workspace_admin?/2` false, `list_workspaces_for/1` empty. On prod,
  the customer's own workspace (`gyldendal`) is in that state — 0 user rows,
  3 token rows — and there is NO membership verb anywhere in the product, so
  the damage cannot be repaired by using Barkpark. Only by this.

  CONDITIONAL, never unconditional: the row is written only where the owning
  token names a real user (`api_tokens.owner_user_id` → an existing
  `users.id`). A CI/bootstrap token legitimately has no human; those
  workspaces are left alone and no NULL or placeholder membership is ever
  inserted.

  Shape: ONE set-based `INSERT … SELECT … ON CONFLICT DO NOTHING` (never a
  per-row content migration — slow-migration law). `ON CONFLICT` on the
  `(workspace_id, principal_type, principal_id)` unique index makes it
  idempotent on its own.

  Reports what it changed AND what it could not resolve, both counted with the
  same predicate the INSERT uses, so an operator reading the deploy log knows
  whether a workspace was skipped because it was already granted or because
  its token has no human.

  `Barkpark.Tenancy.backfill_user_owner_memberships/0` is the operator-facing,
  re-runnable arm of the same predicate, with per-workspace detail. It exists
  because this migration can only fix the workspaces that are token-owned
  TODAY — a token that gains an `owner_user_id` after this deploy needs the
  function, not another migration.

  `NOW() AT TIME ZONE 'utc'`, not bare `NOW()`: `timestamps(type:
  :utc_datetime_usec)` produced `timestamp WITHOUT time zone` columns, so a
  `timestamptz` cast silently uses the session TimeZone and would stamp local
  wall-clock time as if it were UTC on any box not running UTC.

  One-way: which user rows this wrote is not distinguishable afterwards from a
  membership granted deliberately, so `down` is a documented no-op — reverting
  would revoke real access.
  """

  use Ecto.Migration

  @insert """
  INSERT INTO workspace_memberships
    (id, workspace_id, principal_type, principal_id, role, inserted_at, updated_at)
  SELECT gen_random_uuid(), m.workspace_id, 'user', t.owner_user_id, 'owner',
         NOW() AT TIME ZONE 'utc', NOW() AT TIME ZONE 'utc'
  FROM workspace_memberships m
  JOIN api_tokens t ON t.id = m.principal_id
  JOIN users u ON u.id = t.owner_user_id
  WHERE m.principal_type = 'api_token'
    AND m.role = 'owner'
  GROUP BY m.workspace_id, t.owner_user_id
  ON CONFLICT DO NOTHING
  """

  @unresolved """
  SELECT count(DISTINCT m.workspace_id)
  FROM workspace_memberships m
  JOIN api_tokens t ON t.id = m.principal_id
  WHERE m.principal_type = 'api_token'
    AND m.role = 'owner'
    AND (t.owner_user_id IS NULL
         OR NOT EXISTS (SELECT 1 FROM users u WHERE u.id = t.owner_user_id))
  """

  def up do
    granted = repo().query!(@insert, []).num_rows
    %{rows: [[unresolved]]} = repo().query!(@unresolved, [])

    IO.puts(
      "[backfill_user_owner_memberships] granted #{granted} user-typed owner membership(s); " <>
        "#{unresolved} api_token-owned workspace(s) left unresolved (owning token has no " <>
        "resolvable owner_user — expected for CI/bootstrap tokens)."
    )
  end

  def down do
    # Irreversible by design: a row this wrote is indistinguishable from one
    # granted deliberately, and revoking would lock a real human back out of
    # the workspace they created.
    :ok
  end
end
