# dr-w24 — delivery-timeline numbers, re-derivation recipe (2026-08-08)

Window: 300 most recent `deploy.yml` runs, `2026-07-31T20:49:47Z … 2026-08-08T11:51:21Z`.
Every number below is reproducible from these commands. Repo: `FRIKKern/barkpark`.
Run from the repo root — `gh api repos/:owner/:repo/...` needs git context (it 404s from `/tmp`).

## 0. Collect

```sh
gh run list --workflow=deploy.yml --limit 300 \
  --json databaseId,createdAt,startedAt,updatedAt,conclusion,headSha,status,event > /tmp/runs.json
mkdir -p /tmp/dj
python3 -c "import json;print('\n'.join(str(x['databaseId']) for x in json.load(open('/tmp/runs.json'))))" > /tmp/ids.txt
cat /tmp/ids.txt | xargs -P 8 -I{} sh -c \
  'test -s /tmp/dj/{}.json || gh api "repos/:owner/:repo/actions/runs/{}/jobs?per_page=100" > /tmp/dj/{}.json'
```

## 1. D384 at N=300 (run_started_at is unusable)

```sh
python3 -c "import json;r=json.load(open('/tmp/runs.json'));print(len(r),'runs;',sum(1 for x in r if x['startedAt']==x['createdAt']),'startedAt==createdAt;',sum(1 for x in r if x['conclusion']=='cancelled'),'cancelled')"
# -> 300 runs; 300 with startedAt==createdAt; 110 cancelled
```
And `min(job.started_at) == created_at` on **0 of 190** runs that have jobs. Job-level timestamps
are mandatory; D384 holds at 300/300.

## 2. Zero-job cancelled runs (the carried population's blind spot)

`110 of 110` cancelled runs carry ZERO jobs; every `success`/`failure` run carries 3 or 4.
There were **no targetless successes** in this window (no `changes`-only run), so
"not delivered by its own run" == cancelled == **110/300 = 36.7%**.

## 3. Leg A, occupancy, pickup

Definitions used: leg A = `min(job.started_at) - run.created_at`. Build window of a run =
`[min(job.started_at), max(job.completed_at)]`. Occupancy = against OTHER deploy.yml runs' build
windows. Slow row = leg A >= 60 s (D383's threshold).

* leg A over 190 rows with jobs: p50 **10.0 s**, p90 **357.1 s**, p95 **471.4 s**, max **19 486 s**.
* leg B (build) p50 **158.0 s**, p90 **483.5 s**.
* POINT test at `created_at`, slow rows: **72/81 = 88.9%**. Over ALL rows with jobs: **40.0%**.
  Over all 300 runs incl. cancelled: **58.0%**. The inherited 92.0% and the survey's 46.2% are the
  same statistic on two different denominators.
* INTERVAL-OVERLAP, slow rows: **76/81 = 93.8% of ROWS**; by SECONDS **17 867/39 174 = 45.6%**
  with the 19 486 s outlier IN, **17 867/19 688 = 90.8%** with it OUT. The seconds figure is
  outlier-dominated and must never be printed as a single number.
* PICKUP (rows with zero overlap): p50 **4.0 s** under every variant tried; p90 **10.2–11.0 s**
  depending on outlier handling; p99 of the clean set **172.8 s**.

## 4. Carried rate is a function of merge-burst density, not a trend

```sh
python3 - <<'PY'
import json;from collections import defaultdict
d=defaultdict(lambda:[0,0])
for r in json.load(open('/tmp/runs.json')):
    k=r['createdAt'][:10];d[k][0]+=1
    if r['conclusion']=='cancelled': d[k][1]+=1
for k in sorted(d): print(k,d[k],'%.1f%%'%(100*d[k][1]/d[k][0]))
PY
```
Quiet days 23.8–30.4%; burst days 2026-08-04 50.0%, 08-07 48.9%, 08-08 52.0%. The "recent 80 =
51.2%" slice is this epic's own wave load. **36.7% over 8 days is the defensible figure and it
reproduces D385's 36.5%.**

## 5. The platform-stall bucket has a STRUCTURAL definition (co-incidence, not magnitude)

Outlier run `31121348964`, created `2026-08-06T16:52:49Z`, first job `22:17:35Z`.

```sh
for p in 1 2 3 4 5; do gh api "repos/:owner/:repo/actions/runs?created=2026-08-06&per_page=100&page=$p" \
  --jq '.workflow_runs[]|[.id,.name,.created_at,.run_started_at,.conclusion]|@tsv'; done > /tmp/day.tsv
# then fetch jobs for the non-deploy runs created inside the wait window and compute their own leg A
```
Result: **47** other-workflow runs with job timestamps created inside the wait window;
p50 leg A **8 887 s**, p90 **18 640 s**, max **19 145 s**; **44/47 (93.6%) waited > 600 s**, across
**14 distinct workflows** that cannot share `deploy-production`. Therefore stall is definable as
"the residual wait that is co-incident with >= 2 distinct OTHER workflows also unpicked", with no
magnitude constant anywhere.

## 6. GitHub retention is not (yet) the constraint

`gh api repos/:owner/:repo/actions/runs/25188277785/jobs` (created `2026-04-30`, ~100 days old)
still returns `total_count 4` with `started_at 2026-04-30T20:41:48Z`. Job METADATA survives past
90 days in this repo today. The retention argument against client-side derivation is a
settings-toggle risk, not a measured death.
