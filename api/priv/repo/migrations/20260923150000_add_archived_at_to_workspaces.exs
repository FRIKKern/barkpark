defmodule Barkpark.Repo.Migrations.AddArchivedAtToWorkspaces do
  use Ecto.Migration

  # REVERSIBLE WORKSPACE ARCHIVE (task-55474a106554e65a).
  #
  # `archived_at` NULL = live (every existing row, and every new one). A
  # non-NULL value is the whole archive: nothing else about the workspace or
  # anything scoped to it is touched by `Tenancy.archive_workspace/1`, and
  # `Tenancy.restore_workspace/1` puts the column back to NULL. The tenant
  # resolvers (`Plugs.ResolveWorkspace`, `Plugs.DeriveWorkspaceFromToken`)
  # read it and refuse scoped traffic with `workspace_archived`.
  #
  # Additive, nullable, no default, no backfill: every live row reads NULL.
  #
  # NO INDEX: the column is read off a row the resolver already fetched by slug
  # or id — never in a WHERE clause over the table.
  #
  # `MANIFEST.sha256` is regenerated with this commit (migration_manifest_test).
  def up do
    alter table(:workspaces) do
      add :archived_at, :utc_datetime_usec, null: true
    end
  end

  def down do
    alter table(:workspaces) do
      remove :archived_at
    end
  end
end
