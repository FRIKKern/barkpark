defmodule Barkpark.Repo.Migrations.StoreTitleSearchFolds do
  use Ecto.Migration

  require Logger

  @moduledoc """
  Every document stores its folded search names, not only a document with a
  search slot (task-146f3a4fd5c2f348).

  Migration 20261014150000 stored `search_title_fold`, `search_names_fold` and
  `search_names_tsv` only for a row with a title or author slot, and left them
  NULL on every other row. The retriever reads them through
  `bp_search_label_fold/2`, `bp_search_names/2` and `bp_search_names_vector/2`,
  which fold the `title` column when the stored value is NULL. Those SQL
  functions are inlined into the query, so the planner costs the fold of a
  NULL row as a few `replace` calls. On a dataset it thinks is small it reads
  every row of the scope index and folds each row's title: a search with no
  `type` on e2e-freeform (5,038 rows, 5,000 of them `bulk`) took 118 ms on
  guerrilla, against 17 ms with the types named. Locally, on the same shape,
  the median went from 143 ms to 14 ms with the folds stored.

  ## Same values, so the same indexes

  A row without a slot now stores exactly what the three expressions compute
  from its title:

    * `search_title_fold` and `search_names_fold`:
      `bp_fold(coalesce(nullif(title, ''), ''))`;
    * `search_names_tsv`:
      `setweight(to_tsvector('simple', <that fold>), 'A')`.

  Each expression returns the stored value when there is one, so it returns the
  same value as before for every row. The index entries are the same, the
  matches and the ranking are the same, and nothing is reindexed. Only the work
  per row changes: a stored value is read and not computed.

  ## What changes

    * `bp_search_folds/3`, which the document trigger, the schema refresh
      (`bp_search_refresh_batch`) and `bp_refresh_search_slots/1` call, returns the title folds for a row with
      no slot instead of NULLs.
    * `bp_refresh_search_slots/1` also writes a row whose folds are NULL: a
      bundle import's COPY runs with user triggers disabled.
    * The rows already there are filled in id order, @batch rows per statement,
      with a VACUUM after every @vacuum_every written rows, as 20261014150000
      did. Writing the fold columns fires no trigger (the slot trigger fires on
      content, title, type, dataset, dataset_id and workspace_id only).
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @batch 1_000
  @vacuum_every 5_000

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_folds(
      search_title text, title text, search_author text
    ) RETURNS TABLE(title_fold text, names_fold text, names_tsv tsvector)
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT
        public.bp_fold(coalesce(search_title, nullif(title, ''), '')),
        public.bp_fold(coalesce(search_title, nullif(title, ''), '') || ' ' ||
                coalesce(search_author, '')),
        public.bp_search_names_vector_of(title, search_title, search_author)
      WHERE search_title IS NOT NULL OR search_author IS NOT NULL
      UNION ALL
      SELECT
        public.bp_fold(coalesce(nullif(title, ''), '')),
        public.bp_fold(coalesce(nullif(title, ''), '')),
        setweight(to_tsvector('simple', public.bp_fold(coalesce(nullif(title, ''), ''))), 'A')
      WHERE search_title IS NULL AND search_author IS NULL
    $$
    """)

    refresh_function(" OR d.search_names_fold IS NULL")
    fill_folds()
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_folds(
      search_title text, title text, search_author text
    ) RETURNS TABLE(title_fold text, names_fold text, names_tsv tsvector)
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT
        public.bp_fold(coalesce(search_title, nullif(title, ''), '')),
        public.bp_fold(coalesce(search_title, nullif(title, ''), '') || ' ' ||
                coalesce(search_author, '')),
        public.bp_search_names_vector_of(title, search_title, search_author)
      WHERE search_title IS NOT NULL OR search_author IS NOT NULL
      UNION ALL
      SELECT NULL, NULL, NULL
      WHERE search_title IS NULL AND search_author IS NULL
    $$
    """)

    refresh_function("")

    # The stored title folds equal what the expressions compute, so leaving
    # them is harmless; clearing them restores the old shape exactly.
    execute("""
    UPDATE documents
    SET search_title_fold = NULL, search_names_fold = NULL, search_names_tsv = NULL
    WHERE search_title IS NULL AND search_author IS NULL
      AND (search_title_fold IS NOT NULL OR search_names_fold IS NOT NULL
           OR search_names_tsv IS NOT NULL)
    """)
  end

  defp refresh_function(null_folds) do
    execute("""
    CREATE OR REPLACE FUNCTION bp_refresh_search_slots(p_workspace_id uuid) RETURNS bigint
    LANGUAGE plpgsql AS $$
    DECLARE
      n bigint;
    BEGIN
      UPDATE documents d
      SET search_title = x.slots[1], search_author = x.slots[2],
          search_title_fold = f.title_fold, search_names_fold = f.names_fold,
          search_names_tsv = f.names_tsv
      FROM (
        SELECT d2.id, d2.title,
               bp_search_slots(d2.type, d2.dataset, d2.dataset_id, d2.workspace_id,
                               d2.title, d2.content) AS slots
        FROM documents d2
        WHERE p_workspace_id IS NULL OR d2.workspace_id = p_workspace_id
      ) x
      CROSS JOIN LATERAL bp_search_folds(x.slots[1], x.title, x.slots[2]) f
      WHERE d.id = x.id
        AND (d.search_title IS DISTINCT FROM x.slots[1]
             OR d.search_author IS DISTINCT FROM x.slots[2]#{null_folds});
      GET DIAGNOSTICS n = ROW_COUNT;
      RETURN n;
    END
    $$
    """)
  end

  defp fill_folds do
    flush()
    {written, _since_vacuum} = fill_folds(nil, {0, 0})
    if written > 0, do: vacuum_documents()
    Logger.info("title search folds stored on #{written} documents")
  end

  defp fill_folds(after_id, {written, since_vacuum}) do
    %{rows: [[last_id, n]]} =
      repo().query!(
        """
        WITH batch AS (
          SELECT id FROM documents
          WHERE $1::uuid IS NULL OR id > $1::uuid
          ORDER BY id
          LIMIT $2
        ), upd AS (
          UPDATE documents d
          SET search_title_fold = f.title_fold, search_names_fold = f.names_fold,
              search_names_tsv = f.names_tsv
          FROM documents d2
          CROSS JOIN LATERAL bp_search_folds(d2.search_title, d2.title, d2.search_author) f
          WHERE d2.id IN (SELECT id FROM batch)
            AND d.id = d2.id
            AND (d2.search_title_fold IS NULL OR d2.search_names_fold IS NULL
                 OR d2.search_names_tsv IS NULL)
          RETURNING 1
        )
        SELECT (SELECT max(id::text) FROM batch), (SELECT count(*) FROM upd)
        """,
        [after_id && Ecto.UUID.dump!(after_id), @batch],
        timeout: :infinity
      )

    since_vacuum =
      if since_vacuum + n >= @vacuum_every do
        vacuum_documents()
        0
      else
        since_vacuum + n
      end

    if last_id,
      do: fill_folds(last_id, {written + n, since_vacuum}),
      else: {written + n, since_vacuum}
  end

  defp vacuum_documents,
    do: repo().query!("VACUUM documents", [], timeout: :infinity)
end
