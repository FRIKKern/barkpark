defmodule Barkpark.Repo.Migrations.AddRevisionsRevIndex do
  use Ecto.Migration

  @moduledoc """
  [rev-hash-has-no-read] The lookup index behind `Revisions.get_revision_by_rev/3`.

  `20260902120000` added the nullable `revisions.rev` column (catalog-only, safe
  in a transaction). This migration adds the index the new read rides, and it is
  a SEPARATE file because the two need opposite migrator settings.

  ## Why CONCURRENTLY

  A plain `CREATE INDEX ON revisions (rev)` takes a SHARE lock: every INSERT
  into `revisions` blocks for the whole build, and `revisions` is on the write
  path of EVERY document mutation (`Broadcast.save_revision/5`). On prod that
  stalls writes API-wide. Worse, the `barkpark` role carries
  `statement_timeout = 60s` (set by hand during the 2026-09-01 seq-scan
  incident), so a build that outruns 60 s is killed — and inside a migrator
  transaction that failure rolls back the whole migration.

  ## The 60 s hazard, handled the same way as 20260902001000

    * The build runs inside `repo().checkout/1` so `SET statement_timeout = 0`
      and the `CREATE INDEX` land on the SAME connection. With
      `@disable_ddl_transaction true` the migrator holds no transaction for us
      and runs on a pool of 2, so consecutive `execute/1` calls are not
      guaranteed the same backend — the checkout is what makes the `SET` apply.
    * A CONCURRENTLY build killed mid-flight leaves the index present but
      `indisvalid = false`: unusable for reads, still maintained on every write,
      and matched by `IF NOT EXISTS` — so a naive retry is a silent no-op that
      keeps a dead index forever. Any pre-existing INVALID index of this name is
      dropped concurrently BEFORE the build, so a timeout self-heals on re-run.

  Both directions are re-runnable, and a fresh boot builds the index on an empty
  table in milliseconds.

  ## Not unique

  `revisions.rev` mirrors `documents.rev` at snapshot time, and the same
  document rev can legitimately be snapshotted by more than one action (e.g. a
  provenance tap alongside the write). The index is for lookup speed only;
  `get_revision_by_rev/3` takes the newest match.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name "revisions_rev_index"

  def up do
    repo().checkout(fn ->
      repo().query!("SET statement_timeout = 0", [], timeout: :infinity)

      drop_invalid_index()

      repo().query!(
        "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name} ON revisions (rev)",
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
