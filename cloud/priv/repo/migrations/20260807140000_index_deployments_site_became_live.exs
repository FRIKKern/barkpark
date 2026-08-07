defmodule BarkparkCloud.Repo.Migrations.IndexDeploymentsSiteBecameLive do
  @moduledoc """
  deploy-reliability W11 (charter D166): ADOPT THE CENSUS INDEX AS DECLARED SCHEMA.

  `CREATE INDEX tmp_dep_site_live ON deployments (site_id, became_live_at)
  WHERE became_live_at IS NOT NULL` is LIVE on cloud-db-1 and exists in NO
  migration: 53 pages / 424 kB, `pg_class.oid` 35410 — the highest oid of any
  object on the table, so it was created last and by hand. `git grep
  tmp_dep_site_live` finds nothing on origin/main (nor across the 327
  worktrees), and prod's applied migration head equals the repo's newest
  migration, so this index is the ONLY schema drift on `deployments`.

  IT IS WORTH KEEPING — measured properly.

  DO NOT re-measure it with `enable_indexscan = off` + `enable_indexonlyscan =
  off`. That method is INVALID: it does not simulate removal, because Postgres
  simply falls back to a Bitmap Index Scan on the SAME index, which under-states
  the cost of losing it by 14.5x. The numbers below came from an actual
  `DROP INDEX` inside a transaction that was then rolled back:

      7d census     48.4 ms with /  24,089 ms without  = 498x execution (815x buffers)
      24h census    35.4 ms with /   8,349 ms without  = 236x
      site-scoped   21.7 ms with /   4,615 ms without  = 213x

  For contrast, wave 10's `dr-w10-bl-inserted-at-index-watch-item` DECLINED a
  standalone `(inserted_at)` index at a 14% execution gain against 3x buffers —
  same method, opposite verdict. That is what makes this a decision rather than
  a preference.

  NOT COSMETIC, even though nothing reads it yet. `idx_scan` moved 255,440 ->
  255,441 across 150 s of live traffic and no query predicate on
  `became_live_at` exists anywhere in `cloud/lib` today. Dropping the index
  therefore breaks nothing that currently exists — it breaks the delivery census
  this wave is shipping, whose 48 ms cost becomes 24 s without it. Which is
  exactly why the index must be ADOPTED under a declared name rather than left
  running as a `tmp_` object nobody owns.

  CONCURRENTLY is unnecessary here: at ~30k rows the build was measured on the
  live table at 40.8 ms for 424 kB, so the ACCESS EXCLUSIVE lock is shorter than
  a normal statement. Revisit above ~1M rows, where a plain `CREATE INDEX` would
  hold the table long enough to matter.
  """

  use Ecto.Migration

  def up do
    # The hand-made object and the declared one cover identical rows, so the
    # tmp_ index is dropped rather than kept alongside: two identical btrees
    # would double the write cost of every deployment insert for no read gain.
    execute "DROP INDEX IF EXISTS tmp_dep_site_live"

    create index(:deployments, [:site_id, :became_live_at],
             where: "became_live_at IS NOT NULL",
             name: :deployments_site_became_live_index
           )
  end

  def down do
    # DELIBERATELY does not recreate tmp_dep_site_live. A rollback should leave
    # the schema matching the migrations — restoring an undeclared object would
    # re-introduce the exact drift this migration exists to end.
    drop_if_exists index(:deployments, [:site_id, :became_live_at],
                     name: :deployments_site_became_live_index
                   )
  end
end
