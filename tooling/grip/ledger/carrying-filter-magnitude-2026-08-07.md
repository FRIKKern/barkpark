# Carrying-filter magnitude — re-derivation recipe (2026-08-07, deploy-reliability wave 11)

Pinned window: `[2026-07-31 06:35:00, 2026-08-07 06:35:00)` UTC, literal in every query.
Host: `cloud-db-1` on `178.105.92.191`. All timestamps are `timestamp without time zone` (UTC).

## One-shot re-run

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod" < /tmp/carrying.sql
```

`/tmp/carrying.sql` (Q1-Q9), `/tmp/carrying2.sql` (R1-R8), `/tmp/carrying3.sql` (S1-S5) are the three
rounds; S3 (30 d counterfactual) costs ~4 min — run it in the background.

## Headline answers

| question | answer | query |
|---|---|---|
| supersessions credited to a prebuilt/preview/artifact-pinned successor, 7 d | **0** (2144/2144 are `box-build`/`production`/unpinned) | Q7 |
| same at 30 d | **1 prebuilt** of 7865 | S3 |
| preview rows exist at all? | **2**, both `failed`, both `content_rev IS NULL`, 2026-07-31 02:34Z — 4 h *below* the window floor | R1 |
| prebuilt rows exist at all? | **6**, 4 of them `live`, 2026-07-29/30 — below the window floor | R1, Q3 |
| `artifact_url`-pinned rows | 26 all-time, **23 live**, 16 in-window — *all* on `jarl-website` | R2, R3 |
| `content_rev IS NULL`, 24 h | **66** (failed 49 / deferred 14 / live 3), not 78 | Q5, R5 |
| still-waiting ("stranded") | **3 → 2 → 0** across 06:35→06:40Z, same pinned window | Q6, R7, S5 |

## The trap this recipe exists to stop

`jarl-website` has **55 rows all-time and 0 non-null `content_rev`** — every one of its 23 live
deliveries is invisible to a revision-keyed census. It is also the *only* site that delivers via
`artifact_url`. So "zero over-credit" is not evidence the filter is unneeded; the one site that
would trigger it cannot enter the census at all. Re-derive with:

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"SELECT s.name, count(*) rows_alltime, count(d.content_rev) non_null_rev, count(*) FILTER (WHERE d.became_live_at IS NOT NULL AND d.content_rev IS NULL) live_but_unkeyable FROM sites s JOIN deployments d ON d.site_id=s.id GROUP BY 1 ORDER BY 2 DESC;\""
```

## Latency decomposition (S4) — where the 76x actually lives

```
 n_self | p50_self_s | n_incl_super | p50_incl_super_s | p95_incl_super_s
    977 |        127 |         3121 |             8200 |           481607
```

Delivered-as-self p50 is **127 s**, within noise of the 116.8 s mean successful attempt. The whole
gap to 8 200 s is produced by the *supersession-credit rule*, not by slow builds.

## Code side

`git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | grep -n "environment\|source"`
— the only `environment` predicate is `filter_environment/2` reached from `list_page/2`'s
`page_query/2` (lines 722-737). `census/3` (line ~507) has none, and `d.source` is never a query
predicate anywhere in the file (`source_unfetchable?/1` at 474 matches `failure_reason` strings).
