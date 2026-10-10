defmodule Barkpark.Repo.Migrations.AddDocumentsTaskReadyPriorityIndex do
  use Ecto.Migration

  @moduledoc """
  The index that lets `GET /v1/tasks/ready?limit=1` stop at the first row
  (task-80da62a024b935f9).

  `Tasks.Queue.ready_query/1` orders by priority, inserted_at, id. Without an
  index matching that order Postgres read and top-N-sorted every claimable task
  in the workspace whatever the limit: measured on 10k claimable tasks,
  limit=1 49 ms ≈ limit=40 46 ms. A plain `(workspace_id, (priority)::int, …)
  WHERE type = 'task'` index was NOT used (the planner estimates the candidate
  set at one row and keeps the dependency index). This one is PARTIAL on the
  claimable statuses, and is used: limit=1 0.12 ms, limit=40 0.37 ms.

  THE EXPRESSION IS GUARDED (lead ruling on the row): a priority that is not an
  integer indexes as NULL and sorts last, so building or maintaining the index
  can never make a task write fail. Before this, such a value 500'd the READ.

  The expression and the predicate are character for character
  `Tasks.Queue.ready_priority_sql/0` and `ready_lifecycle_in_sql/0`;
  `ready_priority_index_test.exs` pins them against the built index, because a
  drift silently turns the index off.

  Built CONCURRENTLY on the `AddMediaFilesCursorIndex` pattern: no lock on
  `documents`, no statement_timeout on the build connection, and an invalid
  leftover of this name is dropped first so a retry is not a silent no-op.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name "documents_task_ready_priority_idx"

  def up do
    repo().checkout(fn ->
      repo().query!("SET statement_timeout = 0", [], timeout: :infinity)
      drop_invalid_index()

      repo().query!(
        """
        CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name}
          ON documents (
            workspace_id,
            (CASE WHEN content->>'priority' ~ '^-{0,1}[0-9]+$' THEN (content->>'priority')::int END),
            inserted_at,
            id
          )
          WHERE type = 'task' AND content->>'lifecycle_status' IN ('open', 'blocked')
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
