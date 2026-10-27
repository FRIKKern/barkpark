defmodule Barkpark.Search.SearchSlots do
  @moduledoc """
  The weighted title and author slots of the search vector
  (task-3c6d02392d430c98, migration 20261014150000).

  `documents.search_title` and `documents.search_author` hold the text the
  search vector weights 'A' and 'B' when the `title` column is not the search
  title: the field a schema marks `"search": "title"`, the `list_preview.title`
  field of a type without a title field, or a declared `name` / `displayName` /
  `label` / `heading` / `headline` field; and the fields marked
  `"search": "author"`, else the declared `Author` / `Authors` fields. The SQL
  function `bp_search_slots/6` holds the rule; a BEFORE trigger applies it on
  every document write and a schema trigger re-applies it to a type's
  documents when the schema's fields or list preview change.

  `refresh/1` re-applies it to rows written with triggers disabled: a
  workspace bundle import (`Barkpark.Tenancy.WorkspaceBundle`) disables user
  triggers for its COPY, so it calls the same SQL function,
  `bp_refresh_search_slots/1`, for the imported workspace once the import has
  committed. Only rows whose slots differ are written.
  """

  alias Barkpark.Repo

  @doc """
  Recompute the search slots of every document of one workspace
  (`workspace_id: id`) or of every workspace, writing only the rows whose
  slots differ. Returns the number of rows written.
  """
  @spec refresh(keyword()) :: non_neg_integer()
  def refresh(opts \\ []) do
    workspace_id =
      case Keyword.get(opts, :workspace_id) do
        id when is_binary(id) -> Ecto.UUID.dump!(id)
        _ -> nil
      end

    %{rows: [[n]]} =
      Repo.query!("SELECT bp_refresh_search_slots($1::uuid)", [workspace_id], timeout: :infinity)

    n
  end

  @doc """
  Store the title folds of rows that have none (task-146f3a4fd5c2f348): the
  rows written before migration 20261016190000. Their searches stay right
  without it (each search expression folds a NULL row's title), only slower.

  An operator step, never a deploy step: it writes each such row once. Batches
  of `:batch` rows (default 1,000) in id order, each its own transaction, so a
  concurrent write to one of those rows waits for one batch at most; a VACUUM
  after every `:vacuum_every` written rows (default 5,000) keeps the table
  from growing by more than that. Writing the fold columns fires no trigger.

  A dry run (the default) counts the rows and writes nothing; `apply: true`
  writes. Idempotent: a second run finds nothing to write.

      mix barkpark.search.fill_title_folds            # count only
      mix barkpark.search.fill_title_folds --apply
      bin/barkpark eval 'Barkpark.Release.fill_title_folds(apply: true)'
  """
  @spec fill_title_folds(keyword()) :: %{
          to_fill: non_neg_integer(),
          written: non_neg_integer(),
          ms: non_neg_integer()
        }
  def fill_title_folds(opts \\ []) do
    t0 = System.monotonic_time(:millisecond)
    log = Keyword.get(opts, :log, fn _ -> :ok end)

    %{rows: [[to_fill]]} =
      Repo.query!(
        "SELECT count(*) FROM documents WHERE search_title_fold IS NULL " <>
          "OR search_names_fold IS NULL OR search_names_tsv IS NULL",
        [],
        timeout: :infinity
      )

    written =
      if Keyword.get(opts, :apply, false) and to_fill > 0 do
        batch = Keyword.get(opts, :batch, 1_000)
        # `vacuum: false` for a caller inside a transaction (a test), where VACUUM cannot run.
        vacuum_every =
          if Keyword.get(opts, :vacuum, true), do: Keyword.get(opts, :vacuum_every, 5_000)

        {written, _} = fill_batches(nil, {0, 0}, batch, vacuum_every, log)

        if written > 0 and vacuum_every,
          do: Repo.query!("VACUUM documents", [], timeout: :infinity)

        written
      else
        0
      end

    %{to_fill: to_fill, written: written, ms: System.monotonic_time(:millisecond) - t0}
  end

  defp fill_batches(after_id, {written, since_vacuum}, batch, vacuum_every, log) do
    t0 = System.monotonic_time(:millisecond)

    %{rows: [[last_id, n]]} =
      Repo.query!(
        """
        WITH batch AS (
          SELECT id FROM documents
          WHERE $1::uuid IS NULL OR id > $1::uuid
          ORDER BY id
          LIMIT $2
        ), upd AS (
          UPDATE documents d
          SET search_title_fold = f.title_fold, search_names_fold = f.names_fold,
              search_names_tsv = f.names_tsv
          FROM documents d2
          CROSS JOIN LATERAL bp_search_folds(d2.search_title, d2.title, d2.search_author) f
          WHERE d2.id IN (SELECT id FROM batch)
            AND d.id = d2.id
            AND (d2.search_title_fold IS NULL OR d2.search_names_fold IS NULL
                 OR d2.search_names_tsv IS NULL)
          RETURNING 1
        )
        SELECT (SELECT max(id::text) FROM batch), (SELECT count(*) FROM upd)
        """,
        [after_id && Ecto.UUID.dump!(after_id), batch],
        timeout: :infinity
      )

    if n > 0, do: log.("batch: #{n} rows in #{System.monotonic_time(:millisecond) - t0} ms")

    since_vacuum =
      if vacuum_every && since_vacuum + n >= vacuum_every do
        Repo.query!("VACUUM documents", [], timeout: :infinity)
        0
      else
        since_vacuum + n
      end

    if last_id,
      do: fill_batches(last_id, {written + n, since_vacuum}, batch, vacuum_every, log),
      else: {written + n, since_vacuum}
  end
end
