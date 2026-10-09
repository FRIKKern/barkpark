defmodule Barkpark.Repo.Migrations.AddTenancyToPreviewTokenJti do
  use Ecto.Migration

  @moduledoc """
  task-49a6a686bb88d9e5 — additive. `preview_token_jti` (migration
  20260417230200) carried no workspace/tenant column at all, so the only
  honest revoke route (task-8f7cba7f65cb343c) could mint was NONE: a bare-jti
  DELETE would have been a selector with no tenant re-derivation possible.

  `workspace_id`/`project_id` are populated at `record_jti/1` time from
  whatever the signed claims carry (nil for a flat, unscoped mint — unchanged
  behaviour for every row written before this migration or by a mint that
  names no workspace). Nullable, no backfill: an existing row simply stays
  unaddressable through the new scoped revoke, which is a narrowing, never a
  widening, of what could reach it before.
  """

  def change do
    alter table(:preview_token_jti) do
      add :workspace_id, :binary_id
      add :project_id, :binary_id
    end

    create index(:preview_token_jti, [:workspace_id])
  end
end
