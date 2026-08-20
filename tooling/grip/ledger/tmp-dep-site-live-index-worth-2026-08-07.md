# tmp_dep_site_live — what the undeclared index is worth (dr-w11 verifier [tmp-index-worth])

Date: 2026-08-07 06:35–06:50Z · host `178.105.92.191` · container `cloud-db-1`
· db `barkpark_cloud_prod` · repo ref `origin/main` (schema_migrations max = `20260806110000`, identical to repo HEAD migration).

## What it is

    CREATE INDEX tmp_dep_site_live ON public.deployments USING btree (site_id, became_live_at)
      WHERE (became_live_at IS NOT NULL);

`pg_class.oid = 35410` — the HIGHEST oid of any object on `deployments`
(next-highest `deployments_active_site_env_index` = 35286, created by the
2026-08-05 rekey migration). Created last, i.e. tonight, by hand. 53 pages /
424 kB / 10,171 entries against 30,452 table rows.

## Re-derivation recipes

Absence from the repo (rc=1, and the name is NOT Ecto-derivable — Ecto would
auto-name `create index(:deployments, [:site_id, :became_live_at])` as
`deployments_site_id_became_live_at_index`; a hand `name:` override would appear
literally):

    git grep -c tmp_dep_site_live origin/main; echo rc=$?          # -> rc=1

Live index inventory:

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod \
       -c \"select indexname,indexdef from pg_indexes where tablename='deployments' order by 1\""

Cost measurement (`/tmp/idxcost.sql`, `/tmp/idxcost2.sql`, `/tmp/idxcost4.sql`,
`/tmp/idx5.sql` in this session's scratch) — the canonical body is the
LATERAL/MATERIALIZED revision-keyed census over the PINNED window
`inserted_at >= '2026-07-31 00:00:00+00' AND inserted_at < '2026-08-07 00:00:00+00'`:

    WITH revs AS MATERIALIZED (
      SELECT site_id, content_rev, min(inserted_at) AS t0 FROM deployments
       WHERE inserted_at >= '2026-07-31 00:00:00+00' AND inserted_at < '2026-08-07 00:00:00+00'
         AND content_rev IS NOT NULL GROUP BY site_id, content_rev
    ), web AS MATERIALIZED (
      SELECT r.t0, l.became_live_at FROM revs r LEFT JOIN LATERAL (
        SELECT d.became_live_at FROM deployments d
         WHERE d.site_id = r.site_id AND d.became_live_at IS NOT NULL AND d.became_live_at >= r.t0
         ORDER BY d.became_live_at LIMIT 1) l ON TRUE)
    SELECT count(*) revisions, count(*) FILTER (WHERE became_live_at IS NULL) stranded,
           percentile_disc(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (became_live_at-t0))) p50,
           percentile_disc(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (became_live_at-t0))) p95,
           max(EXTRACT(EPOCH FROM (became_live_at-t0))) mx
      FROM web;

Removal is measured by a ROLLED-BACK transaction, never a real drop:

    BEGIN; SET LOCAL lock_timeout='5s'; DROP INDEX tmp_dep_site_live;
    EXPLAIN (ANALYZE, BUFFERS) <census>; ROLLBACK;

## Measured

| run | plan node for the LATERAL | exec time | shared buffers |
|---|---|---|---|
| fleet census, index present | `Index Only Scan using tmp_dep_site_live` (3,291 loops, Heap Fetches 816) | **48.4 ms** (wall 62 ms) | hit 11,649 read 398 |
| fleet census, `enable_indexscan=off`+`enable_indexonlyscan=off` | still `Bitmap Index Scan on tmp_dep_site_live` | 1,662 ms | hit 642,636 |
| fleet census, index DROPPED (rolled back) | `Bitmap Index Scan on deployments_site_id_environment_branch_index` + heap recheck, Heap Blocks **9,731,902** | **24,089 ms** | hit 9,771,530 |
| site-scoped census (search-capstone, 630 revs), index present | `Index Only Scan using tmp_dep_site_live` (630 loops) | **21.7 ms** (wall 36.5 ms) | hit 3,170 read 75 |
| site-scoped census, index DROPPED (rolled back) | bitmap + heap recheck | **4,615 ms** | hit 1,581,935 |
| naive correlated-subquery form (no LATERAL), index present | 4 × `SubPlan`, each 3,291 loops | 459.9 ms (wall 533 ms) | — |

At the epic's OWN preferred pin (24h, `2026-08-06 00:00Z`–`2026-08-07 00:00Z`,
879 revision groups) the verdict is the same, not weaker:

| 24h census | exec time | shared buffers |
|---|---|---|
| index present (`Index Only Scan using tmp_dep_site_live`, 879 loops) | **35.4 ms** | hit 2,397 read 534 |
| index DROPPED (rolled back) | **8,349 ms** | hit 2,645,316 read 3,863 |

**236×.** So the index is not a 7-day-window artifact.

Warm repeats of the canonical census (wall): 67.7 / 54.1 / 63.2 ms.
Census values (identical across all runs): `revisions=3291 stranded=0
p50=58877.407225 p95=507932.097786 max=562682.126504`.

Index BUILD cost, measured in a rolled-back txn: `CREATE INDEX` **40.8 ms**,
resulting size 424 kB. `DROP INDEX` 2.7–703 ms.

## Three findings the numbers force

1. **The assignment's suggested method does not work.** `enable_indexscan=off`
   plus `enable_indexonlyscan=off` does NOT simulate the migrations-only schema —
   Postgres falls back to a **Bitmap** Index Scan, which those GUCs do not gate,
   and still reads `tmp_dep_site_live`. It reports 1,662 ms, understating the
   true cost of removal by **14.5×**. Only an actual (rolled-back) `DROP INDEX`
   measures it.
2. **Nothing in production uses this index.** `idx_scan` was 255,440 at
   06:42:25Z and 255,441 at 06:44:55Z — **one scan in 150 s** of live traffic
   (0 new deployment rows in the interval). Corroborated statically: no query
   predicate on `became_live_at` exists anywhere in `cloud/lib` on `origin/main`
   (`git grep -n became_live_at origin/main -- cloud/lib` → 10 hits, all
   write-side or a single-row field read at `router.ex:10750`). The 255k scans
   are the survey's own census runs. The earlier apparent 33,544-scans-in-90 s
   burst was **lagged stats accounting for my own EXPLAIN runs**, not traffic.
3. **The partial predicate is safe against the obvious authoring trap.** A
   census written WITHOUT an explicit `became_live_at IS NOT NULL` (only
   `became_live_at >= r.t0`) still gets `Index Only Scan using tmp_dep_site_live`
   — Postgres proves the strict operator implies NOT NULL. 78.3 ms.

Corollary drift note, stated honestly: a name-literal sweep of all 108 public
indexes flags 88 as "unrecorded", because Ecto derives index names from columns
and the literal never appears in a migration. That sweep is therefore worthless
as a general drift detector and must not be quoted as "tmp_dep_site_live is the
only drift". The proof for THIS index is the non-derivable name, not the sweep.

## The epic already had this rule, and wave 11's own survey broke it

`dr-w10-bl-inserted-at-index-watch-item` (filed 2026-08-07 05:12:47Z, 2 criteria,
0 met) carries the precedent verbatim: *"Any index that is created is created
CONCURRENTLY and its presence or removal is verified by reading pg_indexes
afterwards"*, and its own description ends *"Verified afterwards: deployments is
back to exactly 9 indexes, zero tmp_*."* `deployments` now carries **ten**
indexes. `tmp_dep_site_live`'s oid (35410) is higher than every other object on
the table, so it was created AFTER that 05:13Z verification — i.e. by wave 11's
time-to-web surveyor, hours after the epic wrote down the discipline it broke.
Wave 10 cleaned up after itself; wave 11's survey did not.

That same row is also the epic's landed bar for index worth: it DECLINED a
standalone `(inserted_at)` index on 14% execution gain against 3× buffers.
This index is 236–498× execution and 815× buffers by the identical method.
Opposite verdict, same bar — which is what makes it a decision rather than a
preference.

## Verdict: ADOPT, renamed. Do not drop.

The index is the difference between a 48 ms census and a 24 s one — **498×
slower, 815× more buffers (9.77 M block hits, i.e. ~76 GB of buffer traffic per
call)** — and the site-scoped path, which `bp cloud site status` would call on
every page view, goes 21.7 ms → 4,615 ms (**213×**). A 24 s fleet census is not
shippable behind a CLI verb; a 4.6 s per-site one is not shippable behind a
status line. The index costs 424 kB and 41 ms to build, and adds exactly one
btree entry per SUCCESSFUL deploy (the partial predicate means an INSERT, which
always has `became_live_at IS NULL`, writes nothing; the entry appears at the
UPDATE that sets it). That is the cheapest instrument this epic has ever bought.

But it must not stay named `tmp_`. Adopt it under a declared name in a
lead-ordered migration, and drop the hand-made one in the same migration so the
two never coexist.

## Draft migration (NOT written to cloud/priv/repo/migrations/ — lead-ordered)

Proposed path: `cloud/priv/repo/migrations/20260807070000_index_deployments_site_became_live.exs`
(next free slot after the applied head `20260806110000`).

```elixir
defmodule BarkparkCloud.Repo.Migrations.IndexDeploymentsSiteBecameLive do
  use Ecto.Migration

  # The revision-keyed time-to-web census (deploy-reliability W11) asks, once per
  # (site, content_rev) group: "what is the FIRST became_live_at on this site at
  # or after this revision's t0?" — a LATERAL … ORDER BY became_live_at LIMIT 1.
  #
  # Without an index on (site_id, became_live_at) the planner has no ordered path
  # to became_live_at and falls back to a bitmap scan on
  # deployments_site_id_environment_branch_index plus a full heap recheck per
  # group. Measured on cloud-db-1 (30,452 rows / 10,177 live) over a pinned 7d
  # window, 3,291 revision groups, by DROPping the index inside a rolled-back
  # transaction: 48.4 ms -> 24,089 ms execution, 11,649 -> 9,771,530 shared
  # buffer hits. The site-scoped census that `bp cloud site status` calls goes
  # 21.7 ms -> 4,615 ms. 498x and 213x respectively.
  #
  # PARTIAL on `became_live_at IS NOT NULL` because only 10,177 of 30,452 rows
  # ever went live: 424 kB instead of ~1.2 MB, and — because a deployment row is
  # INSERTed with became_live_at NULL — the insert path writes NO index entry at
  # all. One entry is added by the UPDATE that marks the deploy live. Postgres
  # proves `became_live_at >= $1` implies the predicate, so a census that omits
  # the explicit IS NOT NULL still gets an index-only scan (verified).
  #
  # NOTE FOR THE OPERATOR: prod already carries this index by hand under the name
  # `tmp_dep_site_live`, created 2026-08-07 during a deploy-reliability survey and
  # never declared. This migration drops that one and recreates it under a
  # declared name so the schema and the repo agree. Build cost measured at 40.8 ms
  # on the live table; CONCURRENTLY is not needed at this size but should be
  # revisited above ~1M rows.
  def up do
    execute "DROP INDEX IF EXISTS tmp_dep_site_live"

    create index(:deployments, [:site_id, :became_live_at],
             where: "became_live_at IS NOT NULL",
             name: :deployments_site_became_live_index
           )
  end

  def down do
    drop index(:deployments, [:site_id, :became_live_at],
           name: :deployments_site_became_live_index
         )
  end
end
```

`down/0` deliberately does NOT recreate `tmp_dep_site_live`: a rollback should
leave the schema matching the migrations, not restore undeclared state.

## Open items for Decide

- `Heap Fetches: 816` of 3,291 index-only probes means the visibility map is
  stale on the live rows. A `VACUUM deployments` would take the census below
  48 ms; whether the migration should `execute "VACUUM ..."` (it cannot — VACUUM
  can't run inside a migration's transaction) or the census simply accepts it is
  a Decide call. Recommend: accept, and note it.
- The census's own affordability claim should be pinned by a test, not by this
  ledger row. There is no assertion anywhere that the LATERAL form is used; a
  builder who writes the naive correlated-subquery form gets 460 ms and no gate
  notices (measured: 4 SubPlans, 9.5× the LATERAL form, index present).
