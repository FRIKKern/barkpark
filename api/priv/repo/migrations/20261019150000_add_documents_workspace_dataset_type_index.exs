defmodule Barkpark.Repo.Migrations.AddDocumentsWorkspaceDatasetTypeIndex do
  @moduledoc """
  A btree index on `documents (workspace_id, dataset, type)` for the desk's
  type census (task-cca3c6d48e57097e).

  `Barkpark.Content.Analytics.type_census/2` counts a workspace's documents
  per type for the desk's "…Rest" tier. Every Studio render runs it, the
  dead render and the connected mount of each document open alike. No index
  led with the workspace, so Postgres read the whole documents table each
  time: about 20 ms for 47,334 rows on the gyldendal-no copy, on Postgres 14
  and 16 alike. With this index and `count(*)` the census is an index-only
  scan of about 5.5 ms on both.

  An index build, no table rewrite. Built `CONCURRENTLY`, so writes continue;
  an invalid index left by an interrupted build is dropped and rebuilt.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "documents_workspace_dataset_type_index"

  def up do
    %{rows: invalid} =
      repo().query!(
        """
        SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
        WHERE c.relname = $1 AND NOT i.indisvalid
        """,
        [@index]
      )

    if invalid != [] do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")
    end

    execute(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index} ON documents (workspace_id, dataset, type)"
    )
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")
  end
end
