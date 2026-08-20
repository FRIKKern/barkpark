# BOX_UNREACHABLE is an INCIDENT class, not a defect — w32 re-derivation recipe

Observed 2026-08-09 18:10–18:12 UTC against cloud-db-1. Sanity total: **32,965 rows**,
2026-07-14 11:28:18 → 2026-08-09 18:10:21; failed 18,652 / live 10,977 / deferred 3,335.
No arm returned a vacuous zero.

## The pinned classifier

`tooling/grip/ledger/deploy-reliability-w32-classes-2026-08-09.sql` — a faithful SQL
transliteration of `classify/1`, `classify/2` and `classify_deferred/2`
(origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex, lines 553-565 / 574-629 / 796-830),
arm for arm, in the same `cond` order. It carries its own **self-check** arm; all four
counters must be 0, and they were:

```
 settled_rows_with_null_class | nonsettled_rows_with_class | deferred_leaked_a_failure_class | failed_leaked_a_deferred_class
------------------------------+----------------------------+---------------------------------+--------------------------------
                            0 |                          0 |                               0 |                              0
```

Rerun:

```
cd /Volumes/SATECHI/github/barkpark && \
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB"' \
  < tooling/grip/ledger/deploy-reliability-w32-classes-2026-08-09.sql
```

## VERDICT: INCIDENT. It self-healed in 2m48s and the fleet was serving on both sides of it.

The 17:00Z burst is **9 rows, 6 sites, 17:41:01.521 → 17:43:49.383, span 00:02:47.86**,
all `stage='PLAN'`, all ONE string:
`instance guerrilla is unreachable — the deploy could not be delivered; check instance health`.

Deploys went **live at 17:36 and again at 17:47** — 5 minutes before and 4 minutes after the
burst — so the box was not down, it was unreachable for under three minutes. Everything since
the last unreachable row: **29 attempts, 8 live, 0 failed, 21 deferred**.

It is not a one-off either: gap-grouped at 30 minutes, BOX_UNREACHABLE has fired in
**58 episodes across 24 days** (143 rows, 6 sites, one string). Median episode = 1 row; the
largest was 14 rows / 1h51m on 2026-07-28. Every one self-healed. That is the signature of a
recurrent connectivity blip, not a code path that stays broken.

## The headline IS burst-sensitive — 4x — and it decays out on its own

Same 24h width, three end-points:

| window | volume | failed | live | deferred | fr_all | fr_settled |
|---|---|---|---|---|---|---|
| 24h ending NOW (contains burst) | 801 | 12 | 267 | 521 | 1.50% | 4.30% |
| 24h ending 17:41 (pre-burst) | 761 | 3 | 259 | 499 | **0.39%** | **1.15%** |
| 24h ending NOW, burst removed | 792 | 3 | 267 | 521 | 0.38% | 1.11% |

Nine rows move `fr_all` 0.39 → 1.50. **A wind-down that quotes an unqualified 24h rate is
quoting a coin flip against a 3-minute blip.** Any published rate pins its window inline AND
names whether an episode is inside it.

## Two inherited claims corrected

1. **"BOX_UNREACHABLE is the only live failing class" is an overstatement.** Over 6h it is
   BOX_UNREACHABLE (9) + CONTENT_API_500 (1). Over 24h, four classes have a pulse:
   BOX_UNREACHABLE 9, CONTENT_API_500 1, PROCESS_DIED 1, BOX_RATE_LIMITED_429 1 = 12 failures.
2. **`grep -n BOX_UNREACHABLE origin/main -- internal/` returns rc=1 — no Go reader.** Verified
   non-vacuous by a control on the same machinery: `DOC_ID_EMPTY` hits
   `internal/cli/cloud_deploy_census_cmd_test.go:3`. Repo-wide the token appears in exactly six
   files, all Elixir/charter/ledger. The class an operator would need to see during an incident
   has no operator surface.

## What this means for the wave

An incident class wants an **alarm**, not a cure — and the alarm it wants is episode-shaped
(N rows / M sites inside a T-minute window), because a per-row alarm on a 1-row median episode
is the alarm-that-cries-wolf the exit gauge cannot afford. Related prior art the wave should
not duplicate: `cch-w58-s3-unreachable-stops-meaning-two-things` and `task-a0b92c5761233af4`
already contest the "check instance health" copy this exact string emits.

Deferrals now dominate volume: `BOX_AT_CAPACITY_DEFERRED` is **519 of 798** 24h rows (65%) and
**2,637 of 2,637** all-time — every other class's last-seen is days old.
