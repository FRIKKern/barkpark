defmodule Barkpark.Repo.Migrations.AddDocumentsGroqPushdownIndexes do
  use Ecto.Migration

  require Logger

  @moduledoc """
  A GIN index over the `_ref` values in `documents.content`, so the GROQ
  endpoint answers `references()` from an index instead of a scan of the
  whole type (task-762bd2e834fa5abe).

      CREATE INDEX CONCURRENTLY documents_content_refs_idx ON documents
        USING GIN ((jsonb_path_query_array(content, 'strict $.** ? (exists(@._ref))._ref')))

  ## The expression

  The `_ref` value of every object at any depth of `content`, as a JSON array.
  `Barkpark.Groq.DocumentSource` matches `references($id)` with
  `<that expression> ?| ARRAY[$id]`. Postgres uses an expression index only
  when the query repeats the expression exactly, so the fragment in
  `DocumentSource.references_any/1` and the text above must stay identical.
  `jsonb_path_query_array` without a `_tz` suffix is IMMUTABLE, which an index
  expression requires.

  The index is on the document row, so a draft row and a published row are
  indexed separately, in the same transaction as the write that changes them.
  The edges table (`Barkpark.Content.Edges`) is not used: it holds only
  references in fields the schema declares as references, so it misses the
  nested `_ref` values of imported content that `references()` must find.

  ## Disk headroom

  Before building, the migration estimates the index from a 5% page sample of
  `documents` (the bytes of the sampled `_ref` arrays plus 64 bytes per
  entry, times 20; over 20,000 synthetic products the index measured 72
  bytes per `_ref` value and this formula gave 74) and reads the free space of the filesystem that holds the
  database: `df` on `SHOW data_directory`, else `/var/lib/postgresql`, else
  `/`. That works only when Postgres runs on the machine that runs the
  migration, which is the case on an instance (`DATABASE_URL` points at
  localhost). It needs four times the estimate free, and at least 1 GiB: the
  index, the WAL its build writes, and room to spare. Below that it logs a
  warning and builds nothing. The migration is still recorded as run, GROQ
  stays correct without the index (`references()` then scans the type), and
  the index can be built later by running the statement above by hand. When
  the free space cannot be read (a remote database, no `df`), it logs that
  and builds.

  ## Expand only

  The index is additive. CONCURRENTLY builds without an `ACCESS EXCLUSIVE`
  lock on the live `documents` table and cannot run inside a transaction,
  hence the two flags. `down` drops it concurrently. A failed concurrent build
  leaves an INVALID index that `IF NOT EXISTS` will not replace; drop it with
  `DROP INDEX CONCURRENTLY documents_content_refs_idx` and run the statement
  again.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @refs_expr "jsonb_path_query_array(content, 'strict $.** ? (exists(@._ref))._ref')"
  @min_free_bytes 1_073_741_824

  def up do
    estimate = estimate_index_bytes()
    need = max(@min_free_bytes, 4 * estimate)

    case free_bytes() do
      {:ok, free} when free < need ->
        Logger.warning(
          "documents_content_refs_idx NOT built: the database disk has #{mib(free)} MiB free, " <>
            "and the index (estimated #{mib(estimate)} MiB) needs #{mib(need)} MiB. GROQ " <>
            "references() scans the type until it is built by hand: CREATE INDEX CONCURRENTLY " <>
            "documents_content_refs_idx ON documents USING GIN ((#{@refs_expr}))"
        )

      result ->
        case result do
          {:ok, free} ->
            Logger.info(
              "building documents_content_refs_idx: estimated #{mib(estimate)} MiB, " <>
                "#{mib(free)} MiB free"
            )

          {:unknown, reason} ->
            Logger.warning(
              "building documents_content_refs_idx without a disk check (#{reason}); " <>
                "estimated #{mib(estimate)} MiB"
            )
        end

        execute("""
        CREATE INDEX CONCURRENTLY IF NOT EXISTS documents_content_refs_idx ON documents
          USING GIN ((#{@refs_expr}))
        """)
    end
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS documents_content_refs_idx")
  end

  # SYSTEM (5) reads about one page in twenty, so the sampled sums times 20
  # estimate the table's. An empty or tiny table samples nothing and
  # estimates 0, which the 1 GiB floor covers.
  defp estimate_index_bytes do
    %{rows: [[entries, bytes]]} =
      repo().query!(
        """
        SELECT coalesce(sum(jsonb_array_length(a)), 0)::bigint,
               coalesce(sum(octet_length(a::text)), 0)::bigint
        FROM (SELECT #{@refs_expr} AS a
              FROM documents TABLESAMPLE SYSTEM (5) REPEATABLE (42)) s
        """,
        [],
        timeout: :infinity
      )

    20 * (bytes + 64 * entries)
  end

  defp free_bytes do
    with true <- local_database?() || {:unknown, "the database is not on this machine"},
         dir when is_binary(dir) <- data_dir() || {:unknown, "no data directory found"},
         {out, 0} <- System.cmd("df", ["-Pk", dir], stderr_to_stdout: true),
         [_header, line | _] <- String.split(out, "\n", trim: true),
         [_fs, _blocks, _used, avail | _] <- String.split(line),
         {kib, ""} <- Integer.parse(avail) do
      {:ok, kib * 1024}
    else
      {:unknown, _} = unknown -> unknown
      _ -> {:unknown, "df could not be read"}
    end
  rescue
    e -> {:unknown, Exception.message(e)}
  end

  defp local_database? do
    config = repo().config()

    config[:socket_dir] != nil or config[:socket] != nil or
      to_string(config[:hostname] || "localhost") in ["localhost", "127.0.0.1", "::1"]
  end

  # `SHOW data_directory` needs superuser or pg_read_all_settings.
  defp data_dir do
    shown =
      case repo().query("SHOW data_directory") do
        {:ok, %{rows: [[dir]]}} -> dir
        _ -> nil
      end

    Enum.find([shown, "/var/lib/postgresql", "/"], &(is_binary(&1) and File.dir?(&1)))
  end

  defp mib(bytes), do: div(bytes, 1_048_576)
end
