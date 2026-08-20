# dr-w31 VERIFY — collapse forensics: re-derivation recipes (2026-08-09)

Verifier: `collapse-forensics`. Read-only except this file. Ground: `origin/main`
(fetched 2026-08-09); control-plane Postgres `cloud-db-1` on `178.105.92.191`;
Guerrilla box `157.180.90.121`. All DB timestamps are naive UTC.

Transport for every multi-statement proof (SQL in a FILE on stdin):

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  "docker exec -i cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -A -F\"|\"'" < q.sql
```

## R1 — the two step instants (hourly by status, 08-05..08-08)

```sql
select to_char(date_trunc('hour',inserted_at),'MM-DD HH24') h,
  count(*) filter (where status='failed') failed,
  count(*) filter (where status='live') live,
  count(*) filter (where status='deferred') deferred, count(*) total
from deployments
where inserted_at >= '2026-08-05 00:00' and inserted_at < '2026-08-08 00:00'
group by 1 order by 1;
```

Step 1 at `08-05 21`: deferred goes 0 → 4 → 22 → 98. Step 2 at `08-06 22`:
failed goes 33 (19h) → 3 → 0, deferred 28 → 63 → 137 → 154.

## R2 — STEP 1 is a RELABEL: the 409 already_running class changes status, not volume

```sql
select to_char(date_trunc('hour',inserted_at),'MM-DD HH24') h, status, count(*)
from deployments where failure_reason like '%already_running%'
  and inserted_at>='2026-08-05 12:00' and inserted_at<'2026-08-06 06:00'
group by 1,2 order by 1,2;
```

`08-05 20 failed 62` · `21 failed 28 / deferred 4` · `22 failed 1 / deferred 22` ·
`23 deferred 98`. Last-ever `already_running` written `failed`:
`2026-08-05 22:57:53.830161` (2,751 rows all-time). First `deferred` row ever:
`2026-08-05 21:27:11.41321`.

Cause: `2154e695f1` **#9615** "a busy box becomes a counted deferral that re-fires",
merged `2026-08-05T21:13:50Z` — 13m21s before the first deferred row, and the exact
left edge of D516's window. Confirms charter D229.

## R3 — STEP 2's cause, and the box actually took the build

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cd /opt/barkpark && git reflog show --date=iso-strict HEAD'
```

`ef77af274 HEAD@{2026-08-06T22:19:52+00:00}: reset: moving to FETCH_HEAD`
(previous pull `33bb65496 HEAD@{2026-08-06T14:24:22+00:00}` — an 8h gap, so #9827
merged 16:52:47Z and did not reach the box for 5h27m).

Isolation — the ENTIRE `api/` delta the box took in that pull is #9827:

```sh
git diff --stat 33bb65496a ef77af2748 -- api/ deploy/
# api/lib/barkpark/sites/deploy_runner.ex | 272 +++-  (+ its controller and 3 test files)
```

10-minute buckets straddle it exactly: `08-06 19:40` failed 2 · `20:10` failed 3 ·
`22:20` failed 3 (last `BUILD_FAILED` row ever: `2026-08-06 22:20:47.991562`) ·
`22:30` failed **0** deferred 26 · `22:40` failed 0 deferred 28. Deferral cause flips
`BUSY` (last `08-06 19h`) → `AT_CAPACITY` (first `08-06 22h`).

## R4 — the 20:00–22:19 hole is a DEMAND LULL, not an outage (rules out "the box was down")

```sql
select inserted_at::text, site_id::text, status, left(coalesce(failure_reason,''),40)
from deployments where inserted_at>='2026-08-06 19:45' and inserted_at<'2026-08-06 22:25' order by 1;
```

Rows exist at `20:11:37`, `20:41:01`, `21:41:00` — five of them, four `live`. The
plane kept minting and the box kept switching; the content firehose thinned.

## R5 — REFUTATION of candidate d73c5b5262 (#10015)

Merged `2026-08-07T06:52:47Z`; box took it inside `dad66869e HEAD@{2026-08-07T06:53:20+00:00}`.
Both are **8h33m after** the collapse completed (`08-06 22:30`). Cannot be the cause.
D10's unique active-deployment index is not a separate candidate either — it shipped
*inside* `2154e695f1` (#9615), i.e. it IS step 1.

## R6 — CURE vs RELABEL on a MATCHED hour-of-day window, at the CHAIN unit

```sql
with w as (select 'BEFORE 08-06 06:00-19:50' lbl,* from deployments
             where inserted_at>='2026-08-06 06:00' and inserted_at<'2026-08-06 19:50' and content_rev is not null
           union all select 'AFTER  08-07 06:00-19:50',* from deployments
             where inserted_at>='2026-08-07 06:00' and inserted_at<'2026-08-07 19:50' and content_rev is not null),
c as (select lbl,site_id,content_rev, bool_or(status='live') live, bool_or(status='failed') fail,
             count(*) rows_ from w group by 1,2,3)
select lbl, count(*) chains, count(*) filter (where live) live_chains,
  round(100.0*count(*) filter (where live)/count(*),2) live_pct,
  count(*) filter (where not live and fail) failed_chains,
  count(*) filter (where not live and not fail) stuck_chains,
  sum(rows_) attempt_rows, round(sum(rows_)::numeric/count(*),2) attempts_per_chain
from c group by 1 order by 1;
```

| | chains | live | live% | failed | stuck | rows | att/chain |
|---|---|---|---|---|---|---|---|
| BEFORE 08-06 06:00–19:50 | 464 | 237 | **51.08** | 221 | 6 | 1099 | 2.37 |
| AFTER 08-07 06:00–19:50 | 360 | 256 | **71.11** | 4 | 100 | 856 | **2.38** |

Row unit, same windows: BEFORE `live 345 / failed 540 / deferred 279`;
AFTER `live 264 / failed 4 / deferred 590`.

**The decisive pair.** `attempts_per_chain` is IDENTICAL (2.37 vs 2.38), so the
+20.03-point chain-level gain is not retry amplification; and live ROWS *fell* 23%
(345→264) while live CHAINS *rose* 8% (237→256) from 22% FEWER offers. Absolute
per-hour live rows are flat across the whole boundary: 24.6/hr (08-06 06–19) vs
23.2/hr (08-07 00–23).

Corrects charter D230's "approximately zero additional sites reached the web": at the
row unit that holds; at the (site_id, content_rev) chain unit it does not.

## R7 — where the 100 "stuck" chains go (are deferrals terminal?)

```sql
with r as (select site_id, content_rev, bool_or(status='live') got_live, bool_or(status='deferred') got_def,
           bool_or(status='failed') got_fail from deployments
           where inserted_at>='2026-08-07 00:00' and inserted_at<'2026-08-08 00:00' and content_rev is not null group by 1,2),
stuck as (select * from r where not got_live and got_def and not got_fail)
select (select count(*) from stuck),
 (select count(*) from stuck s where exists (select 1 from deployments d where d.site_id=s.site_id
    and d.content_rev=s.content_rev and d.status='live' and d.inserted_at>='2026-08-08')),
 (select count(*) from stuck s where exists (select 1 from deployments d where d.site_id=s.site_id
    and d.status='live' and d.inserted_at>'2026-08-07 00:00'));
-- => 195 | 1 | 195
```

Full-day 08-07: 195 chains deferred and never live. **1 of 195** saw that same
`content_rev` reach live later; **195 of 195** saw the site reach live on a later rev.
So deferral is not data loss, but it IS supersession: the deferred revision itself
never publishes. Chain-level never-published-rev: **48.9% → 28.9%**.

## R8 — DOC_ID_EMPTY tracks contention, it does not track a code fix

```sql
select to_char(date_trunc('hour',inserted_at),'MM-DD HH24') h,
 count(*) filter (where status='failed' and failure_reason like '%bp-doc-id%') doc_id_fail,
 count(*) filter (where status='deferred') defer, count(*) total
from deployments where inserted_at>='2026-08-06 00:00' and inserted_at<'2026-08-08 00:00' group by 1 order by 1;
```

`doc_id_fail` runs 16–25/hr through 08-06 09:00–19:00, then `08-06 22h → 2`,
`23h → 1`, and **0 for 20 of the next 21 hours**. No commit in the 22:19:52 pull
touches the HEALTH gate or the SSR marker — only `deploy_runner.ex`'s capacity door.
DOC_ID_EMPTY was largely the concurrency defect wearing a third name (consistent with
charter D179's "one cause wearing four names"), and its residue is 7 rows since 08-08.

## R9 — what is left failing at all (since 2026-08-08)

```sql
select left(coalesce(failure_reason,'(null)'),60) r, count(*), max(inserted_at)::text last
from deployments where status='failed' and inserted_at>='2026-08-08' group by 1 order by 2 desc;
```

`instance guerrilla is unreachable 8` · `HEALTH gate bp-doc-id empty 7` ·
`deploy process died abnormally 3` · `HEALTH failed bp-doc-id 1` ·
`build poll (HTTP 429) rate_limited 1` · `died abnormally: npm warn 1` — **21 rows in
two days.** No `500`, no `503`, no `409`, no `BUILD failed`.
