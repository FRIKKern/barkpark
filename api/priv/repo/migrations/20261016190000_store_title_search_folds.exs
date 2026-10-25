defmodule Barkpark.Repo.Migrations.StoreTitleSearchFolds do
  use Ecto.Migration

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
      no slot instead of NULLs. Every document written from here on stores
      them.
    * `bp_refresh_search_slots/1` also writes a row whose folds are NULL: a
      bundle import's COPY runs with user triggers disabled.

  Two function replacements: no row is written and no table lock is taken, so
  a deploy never waits on this migration. The rows already there keep NULL
  folds and stay correct (each expression folds their title, as before), only
  slower to search. Filling them is an operator step:
  `mix barkpark.search.fill_title_folds --apply`, or
  `Barkpark.Release.fill_title_folds(apply: true)`
  (`Barkpark.Search.SearchSlots.fill_title_folds/1`).
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

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

    # Stored title folds stay: they equal what the expressions compute, so
    # they change no result, and clearing them would rewrite rows.
    refresh_function("")
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
end
