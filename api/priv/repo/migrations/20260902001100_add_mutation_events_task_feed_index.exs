defmodule Barkpark.Repo.Migrations.AddMutationEventsTaskFeedIndex do
  use Ecto.Migration

  @moduledoc """
  The index the task-activity feed behind `GET /v1/tasks/prime` has never had.

  ## The read

  `Barkpark.Tasks.Prime.recent_events/2` emits, once per prime call (the TUI
  boards poll it about once a second):

      SELECT m0."mutation", m0."doc_id", m0."inserted_at"
        FROM "mutation_events" AS m0
       WHERE ((m0."type" = 'task') AND (m0."mutation" LIKE 'task.%'))
         AND (m0."workspace_id" = $1)
       ORDER BY m0."inserted_at" DESC
       LIMIT $2

  `type`/`mutation` are unpinned literals in the Ecto query, so they arrive as
  SQL literals; `workspace_id` comes through `Content.Scope.scope_to_workspace/3`
  as a parameter and `limit` is pinned.

  On guerrilla `mutation_events` is 2,195 MB / 262,718 rows for ONE workspace,
  and its only indexes are `pkey`, `(dataset, id)`, `dataset_id`, `project_id`
  and `workspace_id` — nothing that can order by `inserted_at`. Measured on the
  box (read-only, 2026-09-02): a Parallel Seq Scan with 2 workers, 12,538
  buffers, 70 ms — 87,588 rows discarded per worker to return twenty. On a
  2-core box each prime call therefore recruits two extra backends and touches
  ~100 MB; `pg_stat_user_tables` had `seq_scan` 929,315 / 53.3 billion tuples
  read on this table alone.

  ## Why (workspace_id, type, inserted_at DESC)

  Equality columns first (`workspace_id`, then `type`) so the whole WHERE is an
  Index Cond, then `inserted_at DESC` so the ORDER BY is satisfied by the scan
  and the LIMIT stops it after a handful of tuples — no Sort, no Gather Merge,
  no parallel workers. `inserted_at DESC` is spelled explicitly (rather than
  relying on a backward scan of an ASC index) so the newest-first read is the
  index's FORWARD direction, which is also the direction the planner costs
  cheapest; an ASC-ordered caller is still served by a backward scan.

  `mutation` is deliberately NOT in the key and the index is deliberately NOT
  partial on `WHERE type = 'task'`:

    * `mutation LIKE 'task.%'` cannot become an Index Cond on a
      default-collation btree (a prefix LIKE only rewrites to a range on
      `text_pattern_ops`), so adding `mutation` to the key would buy an
      in-index filter at best and a second sort column's worth of bloat at
      worst. As a plain post-index Filter it costs 23 discarded tuples at
      LIMIT 10 and 322 at LIMIT 100 on the production-shaped fixture — 5 and 19
      buffers total.
    * a partial `WHERE type = 'task'` index would serve prime and nothing else,
      and it hangs the plan on the query keeping that literal inline. The full
      key also serves any other `workspace + type + recency` read on this table
      (the Studio board's per-doc history, `Content.Analytics.recent_activity/2`)
      and costs 13 MB on the production-shaped corpus.

  ## What this index is NOT for

  `Barkpark.Tasks.Events.replay_since/3` (`GET /v1/tasks/events`) is a keyset
  read — `WHERE dataset = $1 AND type = 'task' AND id > $2 ORDER BY id ASC` —
  and is already served by `mutation_events_pkey`: measured 23 buffers / 0.11 ms
  on the same fixture, byte-identical plan before and after this index. Same for
  `Sync.Outbox.fetch/3`, `Plugins.GitHub.Outbox.fetch/3` and
  `Content.EventLog.replay_since/4`, which all ride `id`. This index is for the
  ONE reader that orders by the wall clock.

  ## Concurrency, timeouts, and the invalid-index sweep

  `CREATE INDEX CONCURRENTLY` takes no `ACCESS EXCLUSIVE` lock, so a 2.2 GB
  table stays writable throughout — there is no lock window to name. It cannot
  run inside a transaction, hence `@disable_ddl_transaction` /
  `@disable_migration_lock`.

  Two hazards that follow from that, and how this migration handles them:

    * the `barkpark` role on prod now carries `statement_timeout = 60s`, and a
      concurrent build over 2.2 GB will not finish inside it. Without a
      transaction, consecutive `execute/1` calls may land on DIFFERENT pool
      connections, so a `SET statement_timeout` in one is not in force for the
      next. Everything below therefore runs inside a single `repo().checkout/1`
      so the `SET`, the build and the `RESET` share one connection, and the
      build itself is issued with `timeout: :infinity` so the Elixir-side
      DBConnection timeout does not fire either.
    * a CONCURRENTLY build that DID time out (or was cancelled) leaves an
      INVALID index behind under the same name. `IF NOT EXISTS` would then
      silently keep that useless index and report success forever. So we look
      the name up in `pg_index`/`pg_class` and `DROP INDEX CONCURRENTLY IF
      EXISTS` it first when `indisvalid` is false — re-running the migration
      after a timeout repairs itself instead of cementing the failure.

  Purely additive and fully reversible; `down` drops concurrently under the same
  timeout handling.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "mutation_events_workspace_type_inserted_at_idx"

  def up do
    repo().checkout(fn ->
      unbounded_statement_timeout!()
      drop_invalid_leftover!()

      repo().query!(
        """
        CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index}
          ON mutation_events (workspace_id, type, inserted_at DESC)
        """,
        [],
        timeout: :infinity
      )

      reset_statement_timeout!()
    end)
  end

  def down do
    repo().checkout(fn ->
      unbounded_statement_timeout!()

      repo().query!("DROP INDEX CONCURRENTLY IF EXISTS #{@index}", [], timeout: :infinity)

      reset_statement_timeout!()
    end)
  end

  # The role-level statement_timeout (60s on prod) would abort a concurrent
  # build over a 2.2 GB table. Lifted only for this connection, for the
  # duration of the checkout.
  defp unbounded_statement_timeout! do
    repo().query!("SET statement_timeout = 0", [], timeout: :infinity)
  end

  defp reset_statement_timeout! do
    repo().query!("RESET statement_timeout", [], timeout: :infinity)
  end

  # A timed-out / cancelled CREATE INDEX CONCURRENTLY leaves an index that
  # exists but is unusable (`indisvalid = false`). `IF NOT EXISTS` treats it as
  # done, so a retry would report success while every query kept seq-scanning.
  # Drop it first — concurrently, so the repair needs no lock window either.
  defp drop_invalid_leftover! do
    %{rows: rows} =
      repo().query!(
        """
        SELECT 1
          FROM pg_index i
          JOIN pg_class c ON c.oid = i.indexrelid
         WHERE c.relname = $1 AND NOT i.indisvalid
        """,
        [@index],
        timeout: :infinity
      )

    if rows != [] do
      repo().query!("DROP INDEX CONCURRENTLY IF EXISTS #{@index}", [], timeout: :infinity)
    end
  end
end
