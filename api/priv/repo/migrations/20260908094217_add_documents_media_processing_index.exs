defmodule Barkpark.Repo.Migrations.AddDocumentsMediaProcessingIndex do
  use Ecto.Migration

  @moduledoc """
  The partial index `Barkpark.Plugins.Media.StuckProcessingSweeper`'s candidate
  SELECT needs (task `asm-bl-processing-status-jsonb-index`).

  ## The gap

  `stuck_candidates/1` runs, once a minute, forever:

      WHERE type = 'mediaAsset'
        AND content->>'bp_processing_status' = 'processing'
        AND updated_at < $cutoff
      ORDER BY updated_at ASC
      LIMIT 500

  Nothing on `documents` serves that. A `git grep bp_processing_status` over
  `api/priv/repo` returned ZERO hits against 204 migration files, so the whole
  predicate was a `Seq Scan on documents` plus a `Sort`.

  This is a SCALE fix, not a live incident. The batch is bounded, the order is
  oldest-first so nothing starves, and the cadence is one tick per minute — the
  same posture `Barkpark.Webhooks.StuckDeliverySweeper` deliberately accepts for
  its own advisory SELECT. It is filed and fixed so the cost does not grow with
  the document corpus.

  ## The index

      ON documents (updated_at)
      WHERE type = 'mediaAsset'
        AND content->>'bp_processing_status' = 'processing'

  One structure serves all three parts of the query: the partial predicate is
  the filter, and because the ONLY key column is `updated_at`, the index is
  already in `ORDER BY updated_at ASC` order — the planner takes the LIMIT as a
  forward index seek and never sorts. The index stays tiny by construction:
  `processing` is a TRANSIENT state (`Processing.process/1` writes terminal
  `ready`/`failed`, and the sweeper itself writes terminal `failed` on give-up),
  so the indexed set is the handful of in-flight or genuinely stranded assets —
  not the media corpus. A non-partial `(type, content->>'…', updated_at)` index
  would cover every document row on the table for no extra reachability.

  ## Load-bearing coupling — the query must spell BOTH literals

  A partial index is only usable when the planner can PROVE the query's WHERE
  implies the index predicate. Ecto's original fragment passed the JSONB key as
  a BIND PARAMETER (`fragment("?->>? = ?", d.content, ^@status_key, …)`), and
  `d.type == ^@asset_type` likewise. Measured on a 200k-row sandbox table
  (Postgres 15), with this exact index present:

      -- parameterised key/type, force_generic_plan
      Parallel Seq Scan on documents
        Filter: ((updated_at < $3) AND (type = $1) AND ((content ->> $2) = 'processing'))

      -- literal key/type, force_generic_plan
      Index Scan using documents_media_processing_idx on documents
        Index Cond: (updated_at < $1)

  Under a CUSTOM plan the parameterised form happens to match too (the planner
  substitutes the actual values before matching), so the defect is latent rather
  than absolute — but it is decided by plan-cache luck on a long-lived cron
  worker's cached prepared statement, which is not a property to depend on.
  `stuck_candidates/1` therefore now inlines the type and the status key/value
  as SQL literals. Both halves ship together: the index alone is reachable only
  by accident, and the literals alone have nothing to ride.

  If a future refactor turns either literal back into a bind parameter, Postgres
  SILENTLY stops matching this index — no error, just the seq-scan back. The
  guard is `test/barkpark/plugins/media/stuck_processing_index_test.exs`.

  ## Concurrency

  `CREATE INDEX CONCURRENTLY` builds without an `ACCESS EXCLUSIVE` lock on the
  live `documents` table. CONCURRENTLY cannot run inside a transaction, hence
  `@disable_ddl_transaction true` and `@disable_migration_lock true` (the
  migration lock would otherwise re-open one). Purely additive and fully
  reversible — same template as 20260713130000 and 20260901180000.

  `MANIFEST.sha256` is regenerated with this commit (migration_manifest_test).
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS documents_media_processing_idx
      ON documents (updated_at)
      WHERE type = 'mediaAsset'
        AND content->>'bp_processing_status' = 'processing'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS documents_media_processing_idx")
  end
end
