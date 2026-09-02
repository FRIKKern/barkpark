defmodule Barkpark.Repo.Migrations.AddDocumentsTaskParentIdIndex do
  use Ecto.Migration

  @moduledoc """
  The expression index the CHILDREN lookup needs — the other half of the
  `drafts.`-normalisation gap that 20260901180000 closed for the ready queue's
  dependency probe (task-e2f5ecca0be9a6d1, criterion 1).

  ## The gap

  Every task read path that answers "who are `<id>`'s children?" spells the
  match prefix-agnostically, stripping a leading `drafts.` from BOTH sides:

      regexp_replace(content->>'parent_id', '^drafts\\.', '') =
        regexp_replace($1, '^drafts\\.', '')

  Six call sites share that one predicate — `Tasks.Query.maybe_filter_parent/2`
  and `maybe_filter_parent_id/2` (the `?parent=` / `?phase_id=` list filters),
  `Tasks.Rail.rail_children/2`, `Tasks.Queue.maybe_filter_phase/2`,
  `TasksController.child_tasks/2` (the ONLY producer of `bp task get`'s
  `child_count`, so EVERY `bp task get` runs it), `Params.batch_child_counts/2`
  (the `= ANY($1)` form behind `bp task ls --view=brief`), and the GitHub
  plugin's `Relations.child_count_exceeded?/3` on the write path.

  The left-hand side is a FUNCTION of a jsonb field. No plain-column index can
  serve it, and 20260901180000's index is on `regexp_replace(doc_id, ...)` —
  the doc_id side, not the parent_id side. So every one of those calls was a
  `Seq Scan on documents`. Measured on guerrilla 2026-09-01: `documents`
  seq_scan 3,969,442 / seq_tup_read 21.5 BILLION on a ~10.7k-row table. One
  such scan is ~7 ms on a quiet box — the damage is volume x concurrency: six
  concurrent backends at 10-14% CPU on nproc=2 starved the auth plugs' token
  lookups into `DBConnection` timeouts, which is the 500 storm.

  ## The index

      (regexp_replace(content->>'parent_id', '^drafts\\.', ''), workspace_id)
        WHERE type = 'task'

  Leading column is the EXACT expression Ecto emits — textual identity is what
  makes the planner match an expression index, so this string must not be
  "tidied". `workspace_id` second finishes the tenancy narrowing inside the
  index; it is a trailing column, so the sites that scope by `dataset` or by
  `IS NOT DISTINCT FROM` instead still get the leading-column probe. The
  partial `WHERE type = 'task'` mirrors the sibling index and every call site
  (all seven carry `type = 'task'`), keeping the index to the task corpus.

  No query site is rewritten: the predicate was already correct, it simply had
  nothing to ride. Additive only, so the blue/green overlap is safe — the old
  release seq-scans exactly as before while the new one probes.

  ## Concurrency, and the 60 s statement_timeout hazard

  Prod's `barkpark` role now carries `statement_timeout = 60s` (set by hand as
  a stopgap for this same incident). `CREATE INDEX CONCURRENTLY` makes two
  full table passes and waits out every overlapping transaction; on a loaded
  2-core box that can exceed 60 s, and a timed-out CONCURRENTLY build leaves an
  INVALID index behind that `IF NOT EXISTS` would then silently keep forever —
  a permanently dead index that costs writes and serves no read.

  Both halves are handled:

    * The whole build runs inside `repo().checkout/1` so the `SET
      statement_timeout = 0` and the `CREATE INDEX` land on the SAME
      connection. With `@disable_ddl_transaction true` the migrator has no
      transaction to hold one for us and runs on a pool of 2, so consecutive
      `execute/1` calls are NOT guaranteed the same backend — the checkout is
      what makes the `SET` apply to the build.
    * Before building, any pre-existing INVALID index of this name is dropped
      concurrently, so a previous timeout self-heals on the next run instead
      of poisoning it.

  `RESET statement_timeout` restores the role default on that connection.
  `down` drops concurrently. Both directions are re-runnable.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name "documents_task_parent_id_idx"

  def up do
    repo().checkout(fn ->
      repo().query!("SET statement_timeout = 0", [], timeout: :infinity)

      drop_invalid_index()

      repo().query!(
        """
        CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name}
          ON documents ((regexp_replace(content->>'parent_id', '^drafts\\.', '')),
                        workspace_id)
          WHERE type = 'task'
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
  # on every write, and — the trap — matched by `IF NOT EXISTS`, so a retry is a
  # silent no-op that leaves the defect in place forever. Sweep it first.
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
