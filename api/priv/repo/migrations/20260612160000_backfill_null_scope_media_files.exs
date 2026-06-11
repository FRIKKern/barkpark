defmodule Barkpark.Repo.Migrations.BackfillNullScopeMediaFiles do
  @moduledoc """
  P5 of Scoped-by-URL: stamp the seeded Default workspace/project onto
  `media_files` rows with NULL tenancy scope.

  The pre-P0 Studio editor upload passed no scope_opts, so its blob rows
  landed with NULL workspace_id/project_id — invisible to every scoped
  read (scoped queries filter with NO NULL-fallback) and unreachable from
  the scoped media surface. Those uploads all happened on the flat
  (Default-pinned) Studio, so Default IS their owning scope.

  Idempotent + tolerant: a database without a seeded Default workspace
  (fresh install) is a no-op; rows keep a NULL dataset_id (the
  string-seam read fallback covers them) unless the Default project owns
  a dataset row matching their dataset string.
  """
  use Ecto.Migration

  def up do
    execute """
    UPDATE media_files mf
    SET workspace_id = w.id,
        project_id = p.id
    FROM workspaces w, projects p
    WHERE w.slug = 'default'
      AND p.workspace_id = w.id AND p.slug = 'default'
      AND mf.workspace_id IS NULL
    """

    execute """
    UPDATE media_files mf
    SET dataset_id = d.id
    FROM workspaces w, projects p, datasets d
    WHERE w.slug = 'default'
      AND p.workspace_id = w.id AND p.slug = 'default'
      AND d.project_id = p.id AND d.slug = mf.dataset
      AND mf.workspace_id = w.id AND mf.project_id = p.id
      AND mf.dataset_id IS NULL
    """
  end

  def down do
    # Irreversible by design: backfilled rows are indistinguishable from
    # rows that were always Default-scoped — and the stamp is harmless to
    # keep (it matches where the flat surface always served these blobs).
    :ok
  end
end
