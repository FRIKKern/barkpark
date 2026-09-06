defmodule Barkpark.Repo.Migrations.AddDocumentsTaskDocIdPrefixIndex do
  use Ecto.Migration

  @moduledoc """
  A partial btree with `text_pattern_ops` on the `drafts.`-stripped `doc_id` of
  task rows, so `GET /v1/tasks?id_prefix=…` is an index scan instead of a seq
  scan (task cchi-bl-task-get-needs-a-server-side-prefix-lookup).

      CREATE INDEX CONCURRENTLY documents_task_doc_id_prefix_idx
        ON documents ((regexp_replace(doc_id, '^drafts\\.', '')) text_pattern_ops)
        WHERE type = 'task'

  ## Why `text_pattern_ops` is the whole migration

  A btree in the database's DEFAULT collation cannot serve `LIKE 'x%'` at all
  unless that collation is C: outside C, `<`/`>` order and prefix order are not
  the same order, so Postgres refuses to rewrite the LIKE into a range scan and
  falls back to a seq scan over every task row. `text_pattern_ops` builds the
  index in plain byte order, which IS prefix order, and the planner then rewrites
  `col LIKE 'x%'` into `col >= 'x' AND col < 'x' || <next byte>`. This is exactly
  why the existing `documents_task_ready_dep_idx` — same table, same expression,
  DEFAULT opclass — cannot be reused here: it serves that gate's EQUALITY probe
  and is blind to a prefix.

  ## Why the expression and not the bare column

  `Barkpark.Tasks.Query.id_prefix_lookup/2` matches
  `regexp_replace(doc_id, '^drafts\\.', '')`, the same drafts-agnostic
  expression `maybe_filter_parent_id/2`, `collapse_twins/1` and the ready-queue
  index already use — so a typed id finds an unpaired `drafts.` shadow too. An
  index on the bare column would not be usable for that predicate at all.

  ## Why PARTIAL

  Every query that can reach this index carries `type = 'task'` (the route pins
  it), and tasks are a slice of `documents`. Matching the literal into the index
  predicate keeps the index to the rows the lookup can ever touch. LOAD-BEARING
  COUPLING: if a future caller drops that literal, Postgres can no longer prove
  the subset relation and SILENTLY stops using this index — no error, just the
  seq scan back.

  ## Concurrency

  `CREATE INDEX CONCURRENTLY` (and a concurrent `DROP` in `down`) builds without
  an `ACCESS EXCLUSIVE` lock on the live `documents` table; CONCURRENTLY cannot
  run inside a transaction, hence the two flags. Purely additive, fully
  reversible — same template as 20260901180000.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS documents_task_doc_id_prefix_idx
      ON documents ((regexp_replace(doc_id, '^drafts\\.', '')) text_pattern_ops)
      WHERE type = 'task'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS documents_task_doc_id_prefix_idx")
  end
end
