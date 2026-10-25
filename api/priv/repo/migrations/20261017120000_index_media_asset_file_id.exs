defmodule Barkpark.Repo.Migrations.IndexMediaAssetFileId do
  use Ecto.Migration

  @moduledoc """
  An index for the asset doc of a media file (task-5374a17d7bec08ab).

  Every media list joins each `media_files` row to its `mediaAsset` document on
  `content->>'mediaFileId'`. With no index on that, the planner (which reads the
  media side as one row) took a nested loop that read every asset doc of the
  dataset for every file: 300 images x 360 asset docs, 107,700 rows thrown away, 70 ms
  per statement locally, and the studio's image picker waited ~400 ms on guerrilla
  for a page of 24 (`type=image`; without the filter, 80 ms).

  A partial expression index on the text of the key, for `mediaAsset` rows only:
  the joins compare text with `m.id::text` and name the key as a literal, so the
  index answers them, and the asset lookups by id (`Assets`) too. Text, not a
  uuid cast, so a malformed id in any document cannot fail the build.
  Built CONCURRENTLY: no write is blocked on `documents` while it builds.

  ## The planner's row counts

  It read the media side as one row because it multiplies the selectivity of
  `workspace_id`, `project_id` and `dataset_id` as if they were independent, when
  one names the others. Extended statistics on those columns (and on the asset
  doc's `workspace_id, project_id, type, dataset_id`) give it the real count;
  ANALYZE builds them (it takes no lock that blocks reads or writes). Locally, a
  page of 24 images (300 images, 60 PDFs, 22,000 other files): 145 ms before, 89
  with the index and text comparison, 37 with the statistics.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS documents_media_asset_file_id_index
    ON documents ((content->>'mediaFileId'))
    WHERE type = 'mediaAsset'
    """)

    execute("""
    CREATE STATISTICS IF NOT EXISTS media_files_scope_stats (dependencies, ndistinct)
    ON workspace_id, project_id, dataset_id FROM media_files
    """)

    execute("""
    CREATE STATISTICS IF NOT EXISTS documents_scope_stats (dependencies, ndistinct)
    ON workspace_id, project_id, type, dataset_id FROM documents
    """)

    execute("ANALYZE media_files")
    execute("ANALYZE documents")
  end

  def down do
    execute("DROP STATISTICS IF EXISTS documents_scope_stats")
    execute("DROP STATISTICS IF EXISTS media_files_scope_stats")
    execute("DROP INDEX CONCURRENTLY IF EXISTS documents_media_asset_file_id_index")
  end
end
