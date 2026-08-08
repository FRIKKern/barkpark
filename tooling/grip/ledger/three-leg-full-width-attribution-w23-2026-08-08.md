# Re-derivation recipe — three-leg leg-A/leg-B attribution at FULL width (wave 23)

Taken 2026-08-08 on a quiet host. Population: the last 500 `deploy.yml` runs
(2026-07-24T19:15:17Z .. 2026-08-08T09:53:45Z), of which 321 carry job timestamps
(320 `success` + 1 `failure`); the other 179 are `cancelled` with **zero** jobs.

## 1. Fetch (runs + jobs, full width, not a 120-sample)

```sh
cd /tmp
for p in 1 2 3 4 5; do
  gh api "repos/FRIKKern/barkpark/actions/workflows/deploy.yml/runs?per_page=100&page=$p" \
    --jq '.workflow_runs[]|{id,created_at,run_started_at,conclusion}|@json'
done > runs.jsonl
jq -r '.id' runs.jsonl | xargs -P8 -I{} sh -c \
  'gh api repos/FRIKKern/barkpark/actions/runs/$1/jobs --paginate \
     --jq "{run:$1,n:([.jobs[].started_at]|length),s:([.jobs[].started_at]|min),c:([.jobs[].completed_at]|max)}|@json"' _ {} \
  > jobs.jsonl
wc -l runs.jsonl jobs.jsonl
```

## 2. Definitions that decide the number

- leg A = `min(job.started_at) - run.created_at`. NEVER `run_started_at`
  (`run_started_at == created_at` on **500 of 500** runs — D384 holds at full width).
- leg B = `max(job.completed_at) - min(job.started_at)`.
- "queued behind OUR OWN group" is an **interval-overlap** test over the whole wait
  `[created_at, first_job_start)` against every other run's `[start, end)` — NOT a
  point test at `created_at`. The point test undercounts (92.0% vs 95.6%) because a
  predecessor that is itself still pending at our `created_at` starts later and then
  blocks us.
- Cap boundary for the pre/post split: `2026-08-06T22:29:27Z`.

## 3. Headline numbers this recipe reproduces

| quantity | value |
|---|---|
| slow rows (leg A > 60 s) | 113 of 321 |
| ... overlapped by our own group, BY ROW | 108 → **95.6%** |
| ... same, excluding the 5.4 h platform outlier | 108/112 → **96.4%** (D383 exactly) |
| ... BY SECONDS of slow leg-A wait | 28,942 / 49,968 → **57.9%** |
| the single outlier's share of slow leg-A seconds | 19,486 / 49,968 → **39.0%** |

Pre/post cap (`2026-08-06T22:29:27Z`):

| window | n | legA p50 / p90 / max | legB p50 / p90 | legA occupied p50 / p90 (n) | legA free p50 / p90 (n) |
|---|---|---|---|---|---|
| ALL | 321 | 9.0 / 362.0 / 19486 | 298.0 / 524.0 | 210.5 / 503.9 (118) | 4.0 / 10.0 (203) |
| PRE-CAP | 265 | 9.0 / 409.2 / 19486 | 330.0 / 527.6 | 234.0 / 515.1 (92) | 4.0 / 10.0 (173) |
| POST-CAP | 56 | 41.5 / 309.5 / 406 | 161.0 / 393.5 | 156.0 / 354.5 (26) | 4.0 / 11.3 (30) |

## 4. The 19,486 s outlier — re-derivation

```sh
gh api repos/FRIKKern/barkpark/actions/runs/31121348964 \
  --jq '{run_attempt,created_at,run_started_at,updated_at,head_sha,display_title}'
gh api repos/FRIKKern/barkpark/actions/runs/31121348964/jobs \
  --jq '.jobs[]|{name,started_at,completed_at}'
# repo-wide: every workflow stalled in the same window
gh api "repos/FRIKKern/barkpark/actions/runs?created=2026-08-06&per_page=100" --paginate \
  --jq '.workflow_runs[]|[.id,.created_at,.name]|@tsv' \
  | awk -F'\t' '$2>="2026-08-06T16:52" && $2<="2026-08-06T22:20"'
```

Verdict: **not** a re-run (`run_attempt: 1`), **not** our concurrency group (it is the
ONLY `deploy.yml` run between 14:46:07Z and 2026-08-07T00:33Z), and **not**
self-starvation (49 repo-wide runs in 5.4 h). It is a repo-wide GitHub runner-allocation
stall: 30+ runs across 9 other workflows created 16:52–19:49Z also got no runner until
21:35–22:17Z, and 14 jobs on 12 different runs all terminate at the identical instant
`2026-08-06T19:49:06Z` (a bulk termination, the signature of unallocated jobs being
reaped). Every runner label in the window is `ubuntu-latest` (929/929 jobs).

Narrative worth keeping: that run's head_sha `ef77af2` is the commit that introduced
`@build_slot_capacity 1` — the deploy that shipped the door waited 5 h 24 m for a
runner and nothing anywhere recorded it.
