defmodule Barkpark.Repo.Migrations.AddSourceIdToMediaFiles do
  use Ecto.Migration

  @moduledoc """
  `media_files.source_id` — the id an asset had in the system it was imported
  from, such as a Sanity asset id (`image-<sha1>-<w>x<h>-<ext>`,
  `file-<sha1>-<ext>`) (task-0bc9247eca1bd741).

  Sanity-shaped image and file URLs (`/w/:ws/p/:proj/images/...`,
  `/files/...`) look the asset up by this column first, then by `sha1`. The
  sha1 fallback alone is not enough: an import that downloads an image from
  Sanity's CDN gets re-encoded bytes, so the stored sha1 differs from the one
  in the Sanity id.

  One id names at most one file per dataset, so the index is unique on
  `(dataset_id, source_id)` and partial (`WHERE source_id IS NOT NULL`). It is
  built `CONCURRENTLY`, on the same pattern as `AddSha1ToMediaFiles`.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name "media_files_dataset_id_source_id_index"

  def up do
    repo().checkout(fn ->
      repo().query!("SET statement_timeout = 0", [], timeout: :infinity)

      repo().query!("ALTER TABLE media_files ADD COLUMN IF NOT EXISTS source_id text", [],
        timeout: :infinity
      )

      drop_invalid_index()

      repo().query!(
        """
        CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name}
          ON media_files (dataset_id, source_id) WHERE source_id IS NOT NULL
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

      repo().query!("ALTER TABLE media_files DROP COLUMN IF EXISTS source_id", [],
        timeout: :infinity
      )

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
