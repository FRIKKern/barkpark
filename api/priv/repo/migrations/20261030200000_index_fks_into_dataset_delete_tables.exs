defmodule Barkpark.Repo.Migrations.IndexFksIntoDatasetDeleteTables do
  use Ecto.Migration

  @moduledoc """
  Index every foreign key column that points at a table a dataset delete
  removes rows from.

  Postgres checks a foreign key once per deleted parent row. With no index
  that leads with the referencing column, each check is a sequential scan of
  the referencing table. Two statements of the delete paid that per row:

    * `DELETE FROM datasets` cascades into `revisions`, and every cascaded
      revision ran `UPDATE documents SET current_revision_id = NULL` and the
      same for `released_revision_id` as two full scans of `documents`.
    * The `mutation_events` sweep cascades into `webhook_deliveries`, one full
      scan per deleted event.

  On guerrilla a 57-document e2e dataset delete answered 503
  `dataset_delete_timeout` three times in a row: one statement passed the
  30 s `statement_timeout`. Locally, with 500 000 other documents, 57
  documents with 10 edits each took 354 s in `DELETE FROM datasets` alone.

  `dataset_delete_test.exs` keeps the class closed: any new foreign key into
  one of these tables fails it until it has an index.

  Built CONCURRENTLY on its own connection with `statement_timeout = 0`, as
  `20261027020000_add_revisions_doc_history_index.exs` explains: `documents`
  and `webhook_deliveries` are on the write path. A killed build leaves an
  INVALID index and an unrecorded migration, so each index is dropped before
  it is built: on a rerun every index of this name is a leftover of this
  migration, valid or not.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @indexes [
    {"documents", "current_revision_id"},
    {"documents", "released_revision_id"},
    {"webhook_deliveries", "event_id"},
    {"chat_runtime_usage_receipts", "task_id"},
    {"epic_assignment_runtime_attempts", "task_id"},
    {"cycle_correction_admissions", "paper_document_id"},
    {"cycle_correction_admissions", "paper_revision_id"},
    {"cycle_release_paper_candidates", "document_id"},
    {"cycle_release_paper_candidates", "base_current_revision_id"},
    {"cycle_release_paper_candidates", "base_released_revision_id"}
  ]

  def up do
    repo().checkout(fn ->
      repo().query!("SET statement_timeout = 0", [], timeout: :infinity)

      for {table, column} <- @indexes do
        name = "#{table}_#{column}_index"
        repo().query!("DROP INDEX CONCURRENTLY IF EXISTS #{name}", [], timeout: :infinity)

        repo().query!("CREATE INDEX CONCURRENTLY #{name} ON #{table} (#{column})", [],
          timeout: :infinity
        )
      end

      repo().query!("RESET statement_timeout", [], timeout: :infinity)
    end)
  end

  def down do
    repo().checkout(fn ->
      repo().query!("SET statement_timeout = 0", [], timeout: :infinity)

      for {table, column} <- @indexes do
        repo().query!(
          "DROP INDEX CONCURRENTLY IF EXISTS #{table}_#{column}_index",
          [],
          timeout: :infinity
        )
      end

      repo().query!("RESET statement_timeout", [], timeout: :infinity)
    end)
  end
end
