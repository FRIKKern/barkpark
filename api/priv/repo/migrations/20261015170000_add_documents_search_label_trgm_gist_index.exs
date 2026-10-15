defmodule Barkpark.Repo.Migrations.AddDocumentsSearchLabelTrgmGistIndex do
  @moduledoc """
  A GiST trigram index for the whole-title typo arm of document search
  (task-722697f4650b2a21).

  The arm is `coalesce(search_title, nullif(title, ''), '') % <word>` in
  `Barkpark.Search.DocumentsRetriever`. It used to read the GIN trigram index
  of the search title. GIN answers `%` with every title that shares enough
  trigrams with the word, and at the widened recovery threshold (0.15) one
  shared trigram is enough: 12,102 candidate rows for `basis` on the
  gyldendal-no copy, each read from the table to recheck, 190 ms of a 446 ms
  recovery pass. GiST keeps each title's trigrams in its leaves and returns
  the 57 titles that match, in 6 ms, without the table read.

  The trailing `''` changes no match, since an empty title is similar to no
  word, as NULL is. It makes the expression differ from the GIN index's
  `coalesce(search_title, nullif(title, ''))`, so the planner uses this index
  for `%` only. The substring and word-similarity arms stay on GIN, which is
  faster for them.

  An index build, no table rewrite. Built `CONCURRENTLY`, so writes continue;
  an invalid index left by an interrupted build is dropped and rebuilt.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "documents_search_label_trgm_gist_idx"

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

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index} ON documents
    USING GIST ((coalesce(search_title, nullif(title, ''), '')) gist_trgm_ops)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")
  end
end
