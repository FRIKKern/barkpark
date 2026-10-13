defmodule Barkpark.Repo.Migrations.AddTenancyToPreviewTokenJti do
  use Ecto.Migration

  @moduledoc """
  task-49a6a686bb88d9e5 — additive. `preview_token_jti` (migration
  20260417230200) carried no workspace/tenant column at all, so the only
  honest revoke route (task-8f7cba7f65cb343c) could mint was NONE: a bare-jti
  DELETE would have been a selector with no tenant re-derivation possible.

  `owner_workspace_id`/`owner_project_id`, NOT `workspace_id`/`project_id` —
  deliberately, same reason `chat_sessions.owner_workspace_id` is named that
  way (`WorkspaceBundle.Catalog`'s own moduledoc): `Catalog.live_e1/1` reads
  `information_schema.columns WHERE column_name = 'workspace_id'`, so a
  column with that EXACT name would mechanically reclassify this table from
  E3 (bare-dataset, unattributable, declared-loss on a bundle export) into
  E1 (exported + torn down via `WHERE workspace_id = $ws`) — a real behaviour
  change to the tenant-bundle backup/restore system this task never asked
  for, with no backfill to make it correct (every pre-existing row would
  silently stop travelling in ANY bundle). These rows are short-lived replay/
  revocation bookkeeping with their own TTL sweep (`PreviewToken.sweep/1`,
  `@grace_seconds` 1h past `expires_at`) — orthogonal to workspace backup —
  so staying OUTSIDE the bundle partition entirely is correct, not a gap.

  Populated at `record_jti/1` time from whatever the signed claims carry
  (nil for a flat, unscoped mint — unchanged behaviour for every row written
  before this migration or by a mint that names no workspace). Nullable, no
  backfill: an existing row simply stays unaddressable through the new
  scoped revoke, which is a narrowing, never a widening, of what could reach
  it before.
  """

  def change do
    alter table(:preview_token_jti) do
      add :owner_workspace_id, :binary_id
      add :owner_project_id, :binary_id
    end

    create index(:preview_token_jti, [:owner_workspace_id])
  end
end
