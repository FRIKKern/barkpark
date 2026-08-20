# Lag split at JOB level over the FULL successful deploy.yml population (n=314) — 2026-08-08

Re-derivation recipe for deploy-reliability wave 22, assignment `lag-split-full-population`.
Verifies/refutes the survey digest's "GitHub's queue is p50 10 s / p90 488 s at job level"
(sample-derived from 40 of 314 runs).

## What it answers

1. Does the merge -> first-job-start ("leg A") bimodality hold on the full population? **YES.**
2. Does it cluster in time (a GitHub incident) or is it diffuse? **DIFFUSE — and it is NOT GitHub.**
3. Is `run_started_at` usable as the split point? **NO — 509/509 runs have `run_started_at == created_at`.**

## Scripts (scratchpad, reproduced here verbatim in intent)

```bash
# 1. Population: every SUCCESSFUL deploy.yml run in the 14-day window, plus its jobs.
#    Prints runs_listed vs total_count_reported and job_fetch_failures so a partial
#    page cannot silently shrink the population.
REPO=FRIKKern/barkpark
gh api "repos/$REPO/actions/workflows/deploy.yml/runs?per_page=1&status=success&created=%3E%3D2026-07-25" --jq '.total_count'
# -> 314

# paginate the list
: > runs.ndjson; p=1
while :; do
  r=$(gh api "repos/$REPO/actions/workflows/deploy.yml/runs?per_page=100&status=success&created=%3E%3D2026-07-25&page=$p")
  n=$(jq '.workflow_runs|length' <<<"$r")
  jq -c '.workflow_runs[]|{id,created_at,run_started_at,updated_at,head_sha,run_attempt,conclusion}' <<<"$r" >> runs.ndjson
  [ "$n" -lt 100 ] && break; p=$((p+1))
done
wc -l runs.ndjson   # -> 314, equal to total_count

# jobs for every run, failures recorded not swallowed
: > jobfail.txt
jq -r '.id' runs.ndjson | xargs -P 8 -I{} sh -c \
  'gh api "repos/'"$REPO"'/actions/runs/{}/jobs?per_page=100" > jobs/{}.json || echo {} >> jobfail.txt'
wc -l jobfail.txt   # -> 0

# 2. All runs regardless of conclusion, for the concurrency-group attribution
: > allruns.ndjson; p=1
while :; do
  r=$(gh api "repos/$REPO/actions/workflows/deploy.yml/runs?per_page=100&created=%3E%3D2026-07-24&page=$p")
  n=$(jq '.workflow_runs|length' <<<"$r")
  jq -c '.workflow_runs[]|{id,created_at,run_started_at,updated_at,head_sha,conclusion,status}' <<<"$r" >> allruns.ndjson
  [ "$n" -lt 100 ] && break; p=$((p+1))
done
jq -r .conclusion allruns.ndjson | sort | uniq -c   # -> 179 cancelled, 1 failure, 329 success
```

`analyze.py` computes legA = `min(job.started_at) - run.created_at`,
legB = `run.updated_at - min(job.started_at)`, and quantiles by linear interpolation.

`blame.py` is the decisive step: for each successful run, it asks whether ANY
earlier deploy.yml run (any conclusion) was still open at our `created_at`
(`pred.created_at < ours < pred.updated_at`). That is exactly the
`concurrency: group: deploy-production, cancel-in-progress: false` occupancy test.

## Decisive numbers (2026-08-08, window `>=2026-07-25`)

```
runs_listed=314 runs_with_jobs=314 runs_missing_jobs=0 job_api_failures=0
runs where run_started_at == created_at: 314/314   (509/509 across all conclusions)

legA merge->first-job-start    n=314  p50=  9.0  p90=370.4  p95=490.5  p99=538.0  max=19486.0
legB first-job-start->run-end  n=314  p50=306.5 p90=523.8  p95=534.0  p99=550.6  max=  582.0

successful runs: 314   created while an EARLIER deploy run was still open: 117   clear track: 197
  GROUP OCCUPIED (our serialization)   n=117 p50=204.0 p90=504.2 p95=523.2 max=  568.0
  GROUP FREE (pure GitHub queue)       n=197 p50=  4.0 p90= 10.0 p95= 11.0 max=19486.0

slow legA (>=60s): 111   of which the group was occupied at merge: 107 (96.4%)
  gap between predecessor run end and our first job start: p50=3.0s p90=9.0s max=98.0s
  gap <= 20s: 103/107
slow legA with a FREE group (genuinely GitHub's): 4 of 314, the largest being
  run 31121348964 / ef77af274 legA=19486s (the known account-wide Actions dispatcher event)
```

Per-JOB start latency vs `run.created_at` — the figures the digest quoted:

```
changes        n=314 p50=  9.0 p90=370.4 p95=490.5 max=19486.0
control-plane  n=228 p50= 33.0 p90=380.7 p95=500.2 max=  561.0
instance       n=186 p50= 28.0 p90=488.0 p95=535.8 max=19607.0   <- the digest's "p90 488 s"
```

Diffuseness: blocked share by UTC day is 0/30.8/0/36.4/50/35.5/32.4/48.1/34.4/28.6/16.7/56.2/44/45.8/50 %
over 2026-07-25..08-08 (Pearson r vs successful-runs-per-day = 0.337). Present on 13 of 15 days.

Aggregate: 40.8 h of merge->run-end wall clock over 314 runs; leg A = 14.1 h (34.6%),
or 8.7 h of 35.4 h (24.6%) excluding the single 19,486 s outlier.

## The trap this row exists to record

`deploy.yml` sets `concurrency: group: deploy-production` with `cancel-in-progress: false`.
A run created while a predecessor is still running does not start ANY job until the
predecessor finishes. Therefore leg A is **not** "GitHub capacity" — 96.4% of its slow
mass is our own serialization, and a recorder that labels leg A "GitHub" blames the wrong
system, which is the exact failure `dr-w21-bl-merge-to-serving-lag-has-no-recorder`'s
own criterion says the split exists to prevent. The split must be THREE legs
(merge -> group free -> first job -> serving) or leg A must be named for our queue.

Second trap: `run_started_at` is NOT runner pickup — it equals `created_at` on 509/509
runs in this window. A builder reaching for the field whose name means "run start" gets
leg A == 0 s on every row and dumps the whole 5h24m outlier into the "us" leg.
