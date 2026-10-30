defmodule Barkpark.Repo.Migrations.RebuildInvalidDocumentsContentWikilinksIndex do
  use Ecto.Migration

  @moduledoc """
  Rebuild `documents_content_wikilinks_idx` when an interrupted build left it
  INVALID.

  `20261026220000_add_documents_content_wikilinks_index.exs` runs `CREATE
  INDEX CONCURRENTLY IF NOT EXISTS`. Until 0.2.32 the migrate path cancelled
  any statement past the 15 s repo timeout (#24830); on gyl that cancel failed
  the 0.2.31 deploy one migration later, on the revisions index. A concurrent
  build cancelled that way leaves an INVALID index, and the migration is not
  recorded, so the next deploy runs it again. `IF NOT EXISTS`
  then sees the invalid index, skips the build and records the migration. The
  index stays INVALID: Postgres still maintains it on every write and never
  uses it for a read, so `references()` and `ReprojectLinkersWorker` fall back
  to a jsonpath walk.

  This migration drops an INVALID leftover and builds the index again, exactly
  as `20261027020000_add_revisions_doc_history_index.exs` does for its own
  index. A valid index, or none, is left alone: the build below is `IF NOT
  EXISTS`, so a missing index is built and a valid one is a no-op. It runs on
  its own connection with `statement_timeout = 0`.

  Expand only. `down` does nothing: the index belongs to the earlier
  migration, whose `down` drops it.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name "documents_content_wikilinks_idx"

  def up do
    repo().checkout(fn ->
      repo().query!("SET statement_timeout = 0", [], timeout: :infinity)

      drop_invalid_index()

      repo().query!(
        """
        CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name} ON documents
          USING GIN ((jsonb_path_query_array(content, 'strict $.** ? (@.type == "wikilink").keyvalue() ? (@.key == "docId" || @.key == "target").value')))
          WITH (gin_pending_list_limit = 128)
        """,
        [],
        timeout: :infinity
      )

      repo().query!("RESET statement_timeout", [], timeout: :infinity)
    end)
  end

  def down, do: :ok

  defp drop_invalid_index do
    %{rows: rows} =
      repo().query!(
        """
        SELECT 1
          FROM pg_index i
          JOIN pg_class c ON c.oid = i.indexrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relname::text = $1
           AND n.nspname = current_schema()
           AND NOT i.indisvalid
        """,
        [@index_name],
        timeout: :infinity
      )

    if rows != [] do
      repo().query!("DROP INDEX CONCURRENTLY IF EXISTS #{@index_name}", [], timeout: :infinity)
    end
  end
end
