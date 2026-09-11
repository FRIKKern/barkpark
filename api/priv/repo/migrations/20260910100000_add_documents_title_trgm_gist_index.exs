defmodule Barkpark.Repo.Migrations.AddDocumentsTitleTrgmGistIndex do
  @moduledoc """
  A KNN-ORDERED access path for the publish dedup wall's candidate scan.

  ## Why GIN was not enough

  `documents_title_trgm_idx` (GIN, migration 20260526181000) can answer
  `title % $1` — "is this title trigram-near that one" — but a GIN index has no
  order. `Content.DedupWall`'s candidate query wanted the top-500 BY SIMILARITY,
  so Postgres had to fetch EVERY row surviving the `%` net, call `similarity()`
  on each, and top-N heapsort. The `LIMIT 500` bounded the RESULT, never the
  SORT INPUT, and that input grows linearly with the corpus.

  Measured on a seeded corpus of real Barkpark task titles (task
  `pds-bl-dedup-wall-scan-budget-blows-at-corpus-scale`), probe = a common-word
  task title, `EXPLAIN (ANALYZE, BUFFERS)`:

      corpus   sort input rows   execution
      20,000            3,410      203 ms
      40,000            6,749      466 ms
      80,000           13,566      729-972 ms  (2,514 ms cold)

  At that slope the `@query_timeout_ms` 5 s budget is a countdown, not a
  ceiling — and on guerrilla the same scan runs on a contended ARM box behind a
  saturated pool, where it already refused ~50-60% of type:task publishes.

  ## What this index buys

  `gist_trgm_ops` supports the KNN distance operator `<->` (`1 - similarity`),
  so `ORDER BY title <-> $1 LIMIT 500` becomes an INDEX SCAN that stops after
  500 rows. Same ordering, same 500 rows — but the scan, not just its output,
  is capped:

      corpus   scan rows   execution
      20,000        500       25 ms
      40,000        500       43 ms
      80,000        500       74-85 ms

  ## Load-bearing coupling — do NOT restore a `%` predicate on the scan

  The bound comes from the planner choosing this index's ORDERED path. That
  requires the query's `ORDER BY` to be exactly `title <-> $1` with a LIMIT. If
  a future refactor puts `similarity()` back in the ORDER BY, or adds a second
  sort key, the ordered path is unreachable and the scan silently goes back to
  seq-scan + sort with no error. `Content.DedupWall` applies the
  `@candidate_trgm_floor` to the 500 ROWS IT GOT BACK, in Elixir, for exactly
  this reason.

  ## Cost

  Additive and reversible. On the seeded 40k corpus the GiST index was 14 MB
  against a 12 MB heap and a 12 MB GIN index; it is maintained on every
  document insert/update of `title`. The GIN index stays — other `%` callers
  and the protective test still use it.

  ## Concurrency

  `CREATE INDEX CONCURRENTLY` (and a concurrent `DROP` in `down`) builds without
  an `ACCESS EXCLUSIVE` lock on the live `documents` table. CONCURRENTLY cannot
  run inside a transaction, so `@disable_ddl_transaction` and
  `@disable_migration_lock` are both set.

  ## Deploy ordering matters

  Until this index exists, the new `<->` ORDER BY has no ordered path and
  degrades to a full sort — WORSE than the shape it replaces.
  `scripts/deploy-rebuild.sh` migrates BEFORE it swaps the release, which is the
  correct order; a hand-rolled deploy that swaps first would regress the wall
  for the length of the window.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS documents_title_trgm_gist_idx
      ON documents USING gist (title gist_trgm_ops)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS documents_title_trgm_gist_idx")
  end
end
