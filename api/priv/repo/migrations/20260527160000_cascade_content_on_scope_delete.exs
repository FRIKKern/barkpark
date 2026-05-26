defmodule Barkpark.Repo.Migrations.CascadeContentOnScopeDelete do
  use Ecto.Migration

  @moduledoc """
  CONTENT CASCADE (4lsn). Flip the scope FKs on the four content-bearing tables
  from `on_delete: :nilify_all` (SET NULL) to `on_delete: :delete_all` (CASCADE).

  ## The leak this closes

  Today `projects.workspace_id` and `datasets.project_id` already cascade
  (`:delete_all`, set in 20260527110000 / 20260527130000). So deleting a
  WORKSPACE removes its projects + datasets. But the CONTENT tables —
  documents / revisions / media_files / schema_definitions — carry their three
  scope FKs (workspace_id / project_id / dataset_id) as `:nilify_all`
  (20260527110100:26-29 for ws+project, 20260527131000:43 for dataset). So a
  workspace delete cascaded the projects + datasets but left every owned
  content row alive with ALL THREE scope columns NULL while its `dataset` STRING
  survived — which resurfaces the row under the Default workspace/project
  (the orphan-resurfaces-under-Default leak).

  USER DECISION (4lsn): cascade-delete content. A workspace delete should delete
  its owned documents / revisions / media / schemas; no orphans. We also flip
  project_id and dataset_id to cascade so deleting a project (or a dataset)
  removes its content too — one consistent "cascade-delete content" rule across
  all three scope levels.

  ## Multi-path cascade is safe

  A single document references workspace + project + dataset, all of which
  themselves cascade from a workspace delete (workspace -> projects ->
  datasets). Postgres dedupes a multi-path cascade — the row is deleted once,
  whichever path reaches it first. No constraint-name collision: each FK keeps
  its existing Ecto-default name (`<table>_<column>_fkey`, confirmed in the
  catalog), so DROP + re-ADD under the same name is a clean in-place swap.

  ## up/0 — nilify_all -> delete_all on all 12 (4 tables x 3 scope FKs)
  ## down/0 — the precise inverse: delete_all -> nilify_all (reversible)

  Implemented as explicit raw `ALTER TABLE` DDL (DROP CONSTRAINT + ADD
  CONSTRAINT) rather than Ecto's buffered `modify`, so `apply_up/1` /
  `apply_down/1` can drive the exact same body against a test's own sandbox
  connection (mirrors the 20260527143000 rescope pattern — buffered DDL needs
  the migrator runner and can't run from a plain test).
  """

  # {table, column, referenced_table}. dataset_id rides every content table
  # from 20260527131000; workspace_id / project_id from 20260527110100.
  @fks [
    {"documents", "workspace_id", "workspaces"},
    {"documents", "project_id", "projects"},
    {"documents", "dataset_id", "datasets"},
    {"revisions", "workspace_id", "workspaces"},
    {"revisions", "project_id", "projects"},
    {"revisions", "dataset_id", "datasets"},
    {"media_files", "workspace_id", "workspaces"},
    {"media_files", "project_id", "projects"},
    {"media_files", "dataset_id", "datasets"},
    {"schema_definitions", "workspace_id", "workspaces"},
    {"schema_definitions", "project_id", "projects"},
    {"schema_definitions", "dataset_id", "datasets"}
  ]

  def up, do: do_swap(repo(), "CASCADE")
  def down, do: do_swap(repo(), "SET NULL")

  def apply_up(repo \\ Barkpark.Repo), do: do_swap(repo, "CASCADE")
  def apply_down(repo \\ Barkpark.Repo), do: do_swap(repo, "SET NULL")

  # Drop each scope FK and re-add it with `on_delete` = `action`. The constraint
  # keeps its Ecto-default name (`<table>_<column>_fkey`) in both directions, so
  # up and down are exact inverses (CASCADE <-> SET NULL). All scope columns are
  # binary_id (uuid) — the referenced PKs are uuid too, so no type change.
  defp do_swap(repo, action) do
    for {table, column, ref} <- @fks do
      constraint = "#{table}_#{column}_fkey"

      repo.query!(
        "ALTER TABLE #{table} DROP CONSTRAINT #{constraint}",
        []
      )

      repo.query!(
        """
        ALTER TABLE #{table}
        ADD CONSTRAINT #{constraint}
        FOREIGN KEY (#{column}) REFERENCES #{ref}(id)
        ON DELETE #{action}
        """,
        []
      )
    end

    :ok
  end
end
