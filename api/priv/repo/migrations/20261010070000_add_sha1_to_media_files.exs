defmodule Barkpark.Repo.Migrations.AddSha1ToMediaFiles do
  use Ecto.Migration

  @moduledoc """
  `media_files.sha1` — the hex SHA-1 of the stored bytes (task-b6e57c37f6928344).

  `POST /v1/media/:ds/upload` hashes every upload and answers a repeat of the
  same bytes in the same dataset and workspace with the existing asset instead
  of a second file; `GET /v1/media/:ds?sha1=<hex>` looks a hash up. Rows born
  before this column carry `NULL` until `mix barkpark.media.backfill_sha1`
  hashes them.

  The column is nullable with no default, so `ADD COLUMN` is a catalog-only
  change. The lookup index is partial (`WHERE sha1 IS NOT NULL`) and built
  `CONCURRENTLY` on the same pattern as `AddMediaFilesCursorIndex`: no
  statement_timeout on the build connection, and an invalid leftover of this
  name is dropped first so a retry is not a silent no-op.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name "media_files_dataset_id_sha1_index"

  def up do
    repo().checkout(fn ->
      repo().query!("SET statement_timeout = 0", [], timeout: :infinity)

      repo().query!("ALTER TABLE media_files ADD COLUMN IF NOT EXISTS sha1 text", [],
        timeout: :infinity
      )

      drop_invalid_index()

      repo().query!(
        """
        CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name}
          ON media_files (dataset_id, sha1) WHERE sha1 IS NOT NULL
        """,
        [],
        timeout: :infinity
      )

      repo().query!("RESET statement_timeout", [], timeout: :infinity)
    end)
  end

  def down do
    repo().checkout(fn ->
      repo().query!("SET statement_timeout = 0", [], timeout: :infinity)
      repo().query!("DROP INDEX CONCURRENTLY IF EXISTS #{@index_name}", [], timeout: :infinity)
      repo().query!("ALTER TABLE media_files DROP COLUMN IF EXISTS sha1", [], timeout: :infinity)
      repo().query!("RESET statement_timeout", [], timeout: :infinity)
    end)
  end

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
