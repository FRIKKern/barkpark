# Re-derivation recipe — D142 (run-keying) vs the revision-keyed time-to-web census

Wave: deploy-reliability wave 11. Verifier slice `d142-vs-zero-stranded`.
Pinned window used everywhere below: `[2026-08-06 06:00:00, 2026-08-07 06:00:00)` UTC on `deployments.inserted_at`.
Host: `cloud-db-1` on `178.105.92.191` (control plane), db `barkpark_cloud_prod`, user `barkpark_cloud`.
DB clock when taken: `2026-08-07 06:34:47 UTC`; table spans `2026-07-14 11:28:18` .. `2026-08-07 06:34:10`, 30,452 rows.

## 0. The landed law under dispute

```
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | sed -n '2821,2840p'
```
D142 begins at line 2821; the operative clause is line 2836:
`segment by RUN, never by rev group (one rev went live 11 times in 61 minutes)`.

Absence checks on the same file (all return 0):
```
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md > /tmp/ch.md
grep -ic "time to web" /tmp/ch.md ; grep -c stranded /tmp/ch.md ; grep -c censor /tmp/ch.md
```

## 1. Both keyings, one window, side by side

Script: `keying.sql` (sections 0/A/A2/B/B2/C/D/E). Reproduce with:
```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod" < keying.sql
```

Run-keyed journey (D142 definition — maximal run over `site_id ORDER BY inserted_at ASC`,
terminated by the next `live`/`failed` row; group id =
`count(*) FILTER (WHERE terminal) OVER (PARTITION BY site_id ORDER BY inserted_at ASC, id
 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)`):

    live_journeys 647 · attempts/release 2.35 · singletons 393
    ttl p50 0.0 s · p95 399.1 s · max 1594.0 s · failed_journeys 562 (dropped)

Revision-keyed census (`(site_id, content_rev)`, t0 = `min(inserted_at)`,
to-web = `min(became_live_at)` for the SAME site at-or-after t0, successor may
lie outside the window):

    revisions 748 · delivered_as_themselves 412 · superseded 336 · stranded 0
    ttw p50 264.7 s · p95 10422.9 s · max 22637.6 s

Ratio of p95: 10422.9 / 399.1 = 26.1x, on ONE identical window. The 26x is not a
window artifact.

## 2. The mechanism (section K), reproducible verbatim

Site `d8e9c2c7-df13-4edc-aa0f-4dafa48bd64f`, `2026-08-06 06:00`..`12:20`, decomposed
into D142 runs: 82 journeys, 80 of them singleton `failed` runs with `journey_s = 0.0`,
one 2-attempt run at 67.3 s, two live runs at 0.0 s. The same interval read
revision-keyed is a single 22,638 s (6h17m) wait. Run-keying resets its clock on
every failure — the very event that causes the wait.

## 3. Width sweep (section F) — the new requirement

All windows END at `2026-08-07 06:00:00`:

    1h   31 revs · generous p50   132.5 s · p95     364.0 s · strict-censored 0
    3h   87        p50   153.2      p95     695.9              0
    6h  219        p50   187.1      p95    1077.8              0
    12h 320        p50   215.2      p95    1985.3              0
    24h 748        p50   264.7      p95   10422.9              0
    48h 1401       p50   513.2      p95   39297.3              0
    72h 1495       p50   600.0      p95   66081.2              0
    168h 3118      p50  8963.7      p95  482577.6              0

p50 moves 67.6x with width; p95 moves 1,326x. Right-censoring under the strict rule
(successor must land inside the window) is 0.0% at every width tonight, so the width
sensitivity is real backlog, not an estimator artifact.

## 4. D142's three defects, re-tested under `(site_id, content_rev)` keying

- (a) rev ordering / "shipped stale": NOT APPLICABLE — a latency census never compares
  `term_rev` to `head_rev`; it takes `min(became_live_at) >= t0`.
- (b) fleet-global rev: STILL TRUE. 194 distinct revs in 24h, avg 3.86 sites/rev,
  max 7, 164 of 194 span >1 site. `(site,rev)` keying yields 748 units but the
  effective independent sample is ~194.
- (c) NULL rev: STILL TRUE. 66 rows (49 failed, 3 live, 5 sites) carry NULL
  `content_rev` and are unmetered by any rev-keyed statistic.
- D142's parenthetical: max 14 live rows for one `(site,rev)`; 103 of 412 site-revs
  went live more than once. `min()` handles it for latency, but "delivered as itself"
  is not a count of deliveries.

## 5. Scripts

`keying.sql` and `keying2.sql` as run are reproduced in the wave Paper's proof block;
both are pure SELECTs, no writes.
