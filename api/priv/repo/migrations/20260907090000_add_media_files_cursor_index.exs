defmodule Barkpark.Repo.Migrations.AddMediaFilesCursorIndex do
  use Ecto.Migration

  @moduledoc """
  The composite index the media delivery keyset cursor has never had
  (task-a6a44e0587f14f65).

  ## The gap

  `Barkpark.Media.Delivery.Search.paginate_ids/2` pages by a keyset cursor whose
  comparand is the row tuple `(inserted_at, id)`, scoped by `dataset_id`.
  `media_files` carries seven indexes — `id` (pkey), `dataset_id`, `dataset`,
  `mime_type`, `(path, dataset_id)` unique, `project_id`, `workspace_id` — and
  NONE of them mentions `inserted_at`, leading or trailing. So every cursor page
  on the default sort is a sequential scan of the whole dataset.

  ## The index

      (dataset_id, inserted_at DESC, id DESC)

  Column order mirrors the query exactly: the equality predicate first, then the
  ordering tuple in the order the cursor compares it. The `DESC` on the trailing
  two is what lets the planner satisfy `ORDER BY inserted_at DESC, id DESC`
  (`created-desc`, the default arm) by a forward walk; the `created-asc` arm
  rides the SAME index backwards, so one index serves both directions.

  ## Why exactly these orderings, and no others

  `cursorable_plan?/1` (merged d9604ed13) admits ONLY `{:created, :desc}` and
  `{:created, :asc}` to the keyset path. `updated-desc` orders by `d.updated_at`
  on the LEFT-JOINed asset doc and `relevance` orders by a computed score;
  neither is expressible in the `(inserted_at, id)` token, so both mint
  `nextCursor: null` and page by OFFSET. Indexing `d.updated_at` or a relevance
  expression FOR CURSOR PURPOSES would therefore buy nothing and cost writes.
  One index, for the one tuple the cursor is allowed to page.

  ## Measured, 200k rows, dedicated scratch DB (barkpark_w6_media_cursor_bench)

  READ — `EXPLAIN (ANALYZE, BUFFERS)`, single tenant (worst realistic case: the
  `dataset_id` index is non-selective), cursor mid-corpus at row 100000,
  `LIMIT 70`, warmed:

      before  Parallel Seq Scan   33334 rows removed x3   4975 buffers  12.579 ms
      after   Index Only Scan     no filter line           4 buffers     0.090 ms

  The whole cursor predicate moves into `Index Cond`. The `created-asc` arm
  plans as `Index Only Scan Backward` on the same index, also with the whole
  predicate in `Index Cond` (5 buffers, 0.111 ms) — one index, both directions.

  WRITE — the cost, measured rather than assumed. Two IDENTICAL 200k-row tables
  in one database, differing only in this index (7 indexes vs 8), 5000
  single-row inserts per trial, arms alternated round by round with NO DDL
  inside any measurement window. 20 trials per arm. Both arms are bimodal on a
  box shared by ~30 agents, so the split is reported, not a median:

      without  fast mode (10/20)  90.8-151.8 ms    loaded mode (10/20)  185.9-337.0 ms
      with     fast mode (10/20)  79.1-166.7 ms    loaded mode (10/20)  178.9-511.1 ms

  Fast-mode means: 115.5 ms vs 121.4 ms per 5000 rows — 43,300 -> 41,200
  rows/s, about 5% slower. That is the same order as adding an 8th btree to a
  table that already maintains 7, and it sits below this box's own noise floor
  (the indexed arm's single fastest trial beats every unindexed trial). Index
  size 11 MB against a 72 MB table.

  ## The other half, and why the number is conditional

  The ROW-comparator query shape (`(a,b) < (x,y)` rather than the
  OR-decomposition) merged separately in db834ea3c and is free. Neither half
  buys much alone; together the whole cursor predicate becomes an `Index Cond`
  — a true seek — instead of a bound in `Filter`. Any speedup figure quoted for
  this index presupposes that comparator.

  ## Concurrency, and the 60 s statement_timeout hazard

  Same treatment as 20260902001000: prod's `barkpark` role carries
  `statement_timeout = 60s`, and a CONCURRENTLY build killed by it leaves an
  INVALID index that `IF NOT EXISTS` would silently keep forever — dead for
  reads, still maintained on every write. The build runs inside
  `repo().checkout/1` so `SET statement_timeout = 0` lands on the same
  connection as the `CREATE INDEX`, and any pre-existing invalid index of this
  name is swept first. Both directions are re-runnable.

  Additive only: no query site changes, so the blue/green overlap is safe — the
  old release scans exactly as it did while the new one seeks.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name "media_files_ds_inserted_at_id_index"

  def up do
    repo().checkout(fn ->
      repo().query!("SET statement_timeout = 0", [], timeout: :infinity)

      drop_invalid_index()

      repo().query!(
        """
        CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name}
          ON media_files (dataset_id, inserted_at DESC, id DESC)
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

      repo().query!("RESET statement_timeout", [], timeout: :infinity)
    end)
  end

  # A CONCURRENTLY build killed by `statement_timeout` (or any error) leaves the
  # index present but `indisvalid = false`: unusable for reads, still maintained
  # on every write, and matched by `IF NOT EXISTS`, so a retry is a silent no-op.
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
