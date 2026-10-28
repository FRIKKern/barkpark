defmodule Barkpark.Repo.Migrations.AddRevisionsDocHistoryIndex do
  use Ecto.Migration

  @moduledoc """
  task-50a2e2a101ca5ec2: the index a page of one document's history rides
  (`Revisions.list_revisions/4`: `doc_id = … AND type = … ORDER BY
  inserted_at DESC, id DESC LIMIT n`).

  Without it Postgres walked the table-wide `revisions_inserted_at_index`
  backwards and filtered out every newer revision of every other document
  until it had a page, so `GET /v1/data/history/…?limit=10` cost the whole
  table's recent writes (guerrilla e2e-local: p50 76 ms, p95 136 ms). With it a
  page reads its own rows. The older `(doc_id, type, dataset)` index stays for
  the reads that filter on dataset.

  Built CONCURRENTLY on its own connection with `statement_timeout = 0`, and an
  INVALID leftover of a killed build is dropped first, exactly as
  `20260902120100_add_revisions_rev_index.exs` explains: `revisions` is on the
  write path of every document mutation.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name "revisions_doc_id_type_inserted_at_id_index"

  def up do
    repo().checkout(fn ->
      repo().query!("SET statement_timeout = 0", [], timeout: :infinity)

      drop_invalid_index()

      repo().query!(
        "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name} " <>
          "ON revisions (doc_id, type, inserted_at DESC, id DESC)",
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
