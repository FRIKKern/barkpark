# Re-derivation recipe: census call cost + client timeout (wave 34, dr)

Measured 2026-08-10 ~00:37–00:41 local (2026-08-09T22:37Z window pin) against
guerrilla via `bp cloud deployments`, binary built from `origin/main`
`45e26115527c875f50769eb7df922b0f97842be8` (ANCESTOR of origin/main).

No value is stored here on purpose — run the commands, read today's number.

## 1. Where the timeout lives (client)

    git grep -n 'FleetDeployCensusTimeout' origin/main -- internal/cloudclient/client.go

`internal/cloudclient/client.go:827` — `const FleetDeployCensusTimeout = 90 * time.Second`,
applied at `:2416-2419` by shallow-copying the Client and giving the lazily-built
`http.Client` an absolute `Timeout`. `http.Client.Timeout` is wall-clock over the
WHOLE request incl. body; the call at `:2420` is single-shot — there is no retry
anywhere on this path.

Shared default for every other cloud call: `DefaultTimeout = 30s` (`:44`).

## 2. Where the timeout does NOT live (server)

    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | grep -n 'timeout'
    git grep -n 'timeout' origin/main -- cloud/lib/barkpark_cloud/repo.ex cloud/config/

Both empty. `census/3` (`deploy_ledger.ex:1127`) issues its `Repo.all` with no
`:timeout` opt, so every query on the census path runs on Ecto's default 15s
query timeout. There is no server-side budget for the ROUTE — only per-query.

## 3. Build a provenance-clean bp and re-time serially

    git worktree add --detach /tmp/censuswt origin/main
    cd /tmp/censuswt && make cli-build            # stamps commit via -ldflags
    ./dist/bp version -o json                     # commit must be an ancestor:
    git merge-base --is-ancestor <commit> origin/main && echo ANCESTOR

    for i in 1 2 3 4 5; do
      /usr/bin/time -p ./dist/bp cloud deployments --days 27 -o json \
        > /tmp/c27_$i.json 2>/tmp/c27_$i.err
      echo "run=$i rc=$?"; grep real /tmp/c27_$i.err
    done

Compare against the default width (`--days` omitted == 7):

    /usr/bin/time -p ./dist/bp cloud deployments -o json > /tmp/c7.json

Read `uptime` BEFORE and AFTER the loop and quote both load averages beside the
timings — a reading taken under wave load is the load, not the cost.

## 4. The number the width buys

    jq '.coverage_cohorts.cohorts[]
        | {cohort, never_covered, never_covered_by_environment, too_young}' /tmp/c27_1.json

`never_covered_by_environment` carries environment splits only. There are no site
ids anywhere in `coverage_cohorts` — confirm with:

    jq '.coverage_cohorts | tostring | test("site_id")' /tmp/c27_1.json   # false

## 5. Host hazard hit while measuring

`git worktree add` of this repo materialises ~9,166 files and `make cli-build`
fills the Go build cache; on a boot disk already near full this ENOSPC'd the
whole shell (`no space left on device`) mid-loop. Put the worktree on the roomy
volume, and `git worktree remove` it when done:

    git worktree list
    git worktree remove /tmp/censuswt --force
