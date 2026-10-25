defmodule Barkpark.Repo.Migrations.BoundDocumentsGinPendingLists do
  @moduledoc """
  Bounds the pending list of the two GIN indexes that reference filters read,
  `documents_content_path_idx` and `documents_content_refs_idx`, to 128 kB
  (task-cca3c6d48e57097e).

  ## Why

  A GIN index with `fastupdate` (the default) queues new entries in a pending
  list and merges them into the index later: at vacuum, or when the list
  passes `gin_pending_list_limit`, 4 MB by default. Every scan of the index
  reads the whole pending list. A desk `groupBy` with a `referencedBy`
  `overFilter` runs a correlated EXISTS that scans the index once per row of
  the grouped type, so it reads the pending list once per row.

  On the gyldendal-no copy, after 5,000 document writes left 116 to 253
  pending pages in `documents_content_path_idx`, one `groupBy` item's
  query took 2.0 to 2.8 s instead of 28 to 55 ms, on Postgres 14 and 16
  alike, and `GET /v1/structure` took 2.3 to 2.9 s instead of 0.23 s.
  Flushing that one index's pending list brought both back. With a 128 kB
  limit the same writes left 12 to 13 pending pages, the query took 41 to
  91 ms and the endpoint 0.23 to 0.50 s. The 5,000 writes took 9.0 to 11.5 s
  with the limit and 9.1 to 11.2 s without it.

  ## What it does

  Sets the storage parameter on each index that exists
  (`documents_content_refs_idx` is skipped on a disk too small to build it),
  then merges the pending list each one holds now. A catalog change, no
  rebuild. `lock_timeout` keeps the brief index lock from waiting behind a
  long query.
  """

  use Ecto.Migration

  @indexes ["documents_content_path_idx", "documents_content_refs_idx"]

  def up do
    execute("SET LOCAL lock_timeout = '10s'")

    for index <- existing() do
      execute("ALTER INDEX #{index} SET (gin_pending_list_limit = 128)")
      execute("SELECT gin_clean_pending_list('#{index}'::regclass)")
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '10s'")

    for index <- existing() do
      execute("ALTER INDEX #{index} RESET (gin_pending_list_limit)")
    end
  end

  defp existing do
    %{rows: rows} =
      repo().query!(
        """
        SELECT c.relname FROM pg_class c
        JOIN pg_index i ON i.indexrelid = c.oid
        JOIN pg_am a ON a.oid = c.relam
        WHERE c.relname = ANY($1) AND a.amname = 'gin' AND i.indisvalid
        """,
        [@indexes]
      )

    rows |> List.flatten() |> Enum.sort()
  end
end
