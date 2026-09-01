defmodule Barkpark.Repo.Migrations.AddReadyQueueTaskIndexes do
  use Ecto.Migration

  @moduledoc """
  The btree `Tasks.Queue.ready_query/1` needs once its `content.dependencies`
  gate is CORRELATED instead of materialized (task-9a2e75098a62cf45).

  ## Why this index is not optional

  `ready_query/1` used to fold that gate into TWO `MATERIALIZED` CTEs — every
  `done` task in the workspace, and every open/blocked task with its
  dependencies unnested and anti-joined to that set. `MATERIALIZED` is a planner
  FENCE: both were computed in FULL, over the whole corpus, before the outer
  `LIMIT` could discard anything, and the outer anti-join against the second one
  degenerated into a nested loop that rescanned it once per candidate (measured
  on a 12,000-task corpus: 1,320,188 rows removed by that join filter alone).

  The correlated rewrite deletes both CTEs, but it only pays if the
  per-dependency lookup is an INDEX probe. Without this index the planner
  materializes `documents` and rescans it per candidate — 13.7 s on the same
  corpus the CTE form ran in 0.32 s. The rewrite and this migration are ONE
  change; neither is safe alone, which is why they ship in one commit.

  ## Why these five columns, in this order

      (regexp_replace(doc_id, '^drafts\\.', ''), workspace_id,
       content->>'lifecycle_status', dataset, project_id)  WHERE type = 'task'

  They are the gate's probe, in selectivity order: the `drafts.`-stripped
  doc_id (the exact expression the gate and `Tasks.Rail`'s prefix-agnostic
  matching both use) resolves a dependency to at most a twin pair, and the four
  trailing columns finish the same-scope + `done` test inside the index instead
  of on the heap.

  A LEANER one-column version of this index is measurably WORSE, and so is
  ADDING a `(workspace_id, lifecycle_status)` companion: with either of those
  present the planner re-costs the inner probe onto the workspace-leading index
  and scans ~7,000 rows per dependency (3.2 s). Measured across four index
  configurations × two plan modes; this is the only one that is fast under BOTH
  a custom and a generic plan. Do not "simplify" it without re-running that
  matrix.

  ## What is deliberately NOT here

  An index on `((content->>'priority')::int)` would let the ORDER BY stop at the
  LIMIT and finally make `?limit=1` cheaper than `?limit=40`. It is omitted on
  purpose: an index expression is evaluated on WRITE, so a task document whose
  `priority` is not an integer — which `Tasks.Validation` rejects but the generic
  content door does not — would stop being writable at all. Trading a read cost
  for a NEW write-time failure mode is not this change's to make; filed instead.

  ## Concurrency

  `CREATE INDEX CONCURRENTLY` (and a concurrent `DROP` in `down`) builds without
  an `ACCESS EXCLUSIVE` lock on the live `documents` table. CONCURRENTLY cannot
  run inside a transaction, hence `@disable_ddl_transaction` and
  `@disable_migration_lock`. Purely additive and fully reversible — same
  template as 20260712121000.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS documents_task_ready_dep_idx
      ON documents ((regexp_replace(doc_id, '^drafts\\.', '')),
                    workspace_id,
                    (content->>'lifecycle_status'),
                    dataset,
                    project_id)
      WHERE type = 'task'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS documents_task_ready_dep_idx")
  end
end
