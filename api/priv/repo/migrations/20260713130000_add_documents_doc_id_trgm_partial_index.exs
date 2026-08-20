defmodule Barkpark.Repo.Migrations.AddDocumentsDocIdTrgmPartialIndex do
  use Ecto.Migration

  @moduledoc """
  Partial GIN trigram index on `documents.doc_id` to serve the tag registry's
  unknown-tag suggestion probe (authoring-excellence charter D49/D50, wave 7 —
  sibling of D46's `ae-dedup-trgm-index` which established the `%` + `SET LOCAL`
  idiom on `documents.title`).

  ## The gap

  `Barkpark.Content.TagRegistry.nearest_registered/3` (content/tag_registry.ex)
  finds the trigram-nearest REGISTERED tags to an unknown name so a rejected
  publish carries a machine-readable "did you mean" fix. Its coarse filter was
  `similarity(doc_id, name) > @suggestion_floor` — a FUNCTION form the planner
  cannot serve from any index (it is index-OPAQUE), so the probe SEQ-SCANS every
  `type='tag'` row on every unknown-tag publish rejection. The rewrite to the
  `?  % ?` operator (paired with `SET LOCAL pg_trgm.similarity_threshold = 0.1`,
  since `@suggestion_floor` 0.1 is below pg_trgm's 0.3 default) makes the probe
  index-ELIGIBLE — but only if a matching GIN trgm index exists.

  ## The fix — a PARTIAL GIN trgm index

      CREATE INDEX CONCURRENTLY documents_doc_id_trgm_idx
        ON documents USING gin (doc_id gin_trgm_ops)
        WHERE type = 'tag' AND status = 'published'

  ### Why PARTIAL and not a full `doc_id` trgm index

  `registered_tags_query/2` (tag_registry.ex — the ONE query behind
  `nearest_registered`) ALWAYS carries `WHERE type = 'tag' AND status =
  'published'`. Matching those two literals into the index predicate keeps the
  index scoped to exactly the rows the probe can ever touch: on a live corpus a
  partial trgm index over just the published tag vocabulary is ~5.4x smaller
  than a full `doc_id` trgm index (measured ~640 kB vs ~3464 kB on a seeded
  replica), because the registered tag vocabulary is a tiny slice of all
  documents. `pg_trgm` is enabled (extension added 20260526181000), so
  `gin_trgm_ops` is available.

  ### Load-bearing coupling — do NOT drop the query literals

  A partial index is only USED when the planner can prove the query's WHERE is a
  subset of the index predicate. `registered_tags_query` carries `type='tag' AND
  status='published'` today; if a future refactor drops or generalizes either
  literal, Postgres can no longer prove the subset relation and SILENTLY stops
  using this index — the probe falls back to a seq-scan with no error. Keep both
  literals in `registered_tags_query` for this index to stay reachable.

  ## Honesty — the win is scale-GATED

  This is REACHABILITY/preparedness, not a today-speedup (same framing as D46).
  On today's tiny tag vocabulary a seq-scan is cheaper than a GIN start-up; the
  index only pays off once a dataset holds thousands of published tags. The
  protective test forces `enable_seqscan = off` to prove the `%` arm CAN ride
  this index while the old `similarity()` arm cannot — the correctness the
  rewrite buys, independent of the current corpus size.

  ## Concurrency

  `CREATE INDEX CONCURRENTLY` (and the matching concurrent `DROP` in `down`)
  builds without an `ACCESS EXCLUSIVE` lock on the live `documents` table.
  CONCURRENTLY cannot run inside a transaction, so this migration sets
  `@disable_ddl_transaction true` and `@disable_migration_lock true` (the
  migration lock would otherwise re-open a transaction around the statement).
  Purely additive, fully reversible.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS documents_doc_id_trgm_idx
      ON documents USING gin (doc_id gin_trgm_ops)
      WHERE type = 'tag' AND status = 'published'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS documents_doc_id_trgm_idx")
  end
end
