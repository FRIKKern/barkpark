defmodule Barkpark.Repo.Migrations.AddTokenRevocationExpiry do
  use Ecto.Migration

  # barkpark-fcbg: token revocation + expiry, plus the deleted-workspace orphan fix.
  #
  # 1. revoked_at / expires_at columns (both NULL = the existing "live forever,
  #    never revoked" semantics — additive, no backfill needed).
  # 2. Flip api_tokens.workspace_id FK from :nilify_all to :delete_all. The old
  #    :nilify_all (migration 110100) left a deleted workspace's token alive with
  #    workspace_id = NULL — it kept authenticating and, on flat routes,
  #    reattached to the seeded Default workspace via AssignDefaultScope carrying
  #    its still-global perms. Cascade-delete is the cleanest closure: home
  #    workspace gone → token gone. (The token's workspace_membership already
  #    cascades on workspace delete via migration 110000, so this aligns the
  #    token row with the membership it lost.)
  def up do
    alter table(:api_tokens) do
      add :revoked_at, :utc_datetime, null: true
      add :expires_at, :utc_datetime, null: true
    end

    # Default Ecto FK name from migration 110100's `references(:workspaces, ...)`.
    drop constraint(:api_tokens, "api_tokens_workspace_id_fkey")

    alter table(:api_tokens) do
      modify :workspace_id,
             references(:workspaces, type: :binary_id, on_delete: :delete_all)
    end
  end

  def down do
    drop constraint(:api_tokens, "api_tokens_workspace_id_fkey")

    alter table(:api_tokens) do
      modify :workspace_id,
             references(:workspaces, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:api_tokens) do
      remove :expires_at
      remove :revoked_at
    end
  end
end
