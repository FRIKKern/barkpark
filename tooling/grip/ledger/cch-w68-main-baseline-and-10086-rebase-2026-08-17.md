# cch wave 68 — the dispatch-time baseline on main HEAD 4b5d802a, and #10086's true rebase cost

Re-derivation recipes. Every line below is a command that reproduces the fact from scratch.
Written 2026-08-17 by the wave-68 verifier `main-baseline-now`. Not committed by me.

## 1. The Elixir gate on main HEAD 4b5d802a1d5a31030f79fa4eb8d4761eb4995db2

    gh run view 32002029334 --json status,conclusion,createdAt,updatedAt
    gh run view 32002029334 --json jobs --jq '.jobs[]|"\(.status)\t\(.conclusion)\t\(.name)"'
    gh api 'repos/FRIKKern/barkpark/commits/4b5d802a1d5a31030f79fa4eb8d4761eb4995db2/check-runs?per_page=100' \
      --jq '.check_runs[]|"\(.conclusion // .status)\t\(.name)"' | sort

The run was QUEUED 15 minutes (created 06:31:42, jobs started 06:46:57) and then ran. It is not
jammed — it is serialized behind the run for the previous merge, which held the same runner for
14m43s. `Elixir gate` is an AGGREGATE job that renders only AFTER `Test (Elixir …)`; on the
previous sha it landed 6 s after Test:

    gh api 'repos/FRIKKern/barkpark/commits/e88296b79d1cdce1e2e124b7172f48aa595138fd/check-runs?per_page=100' \
      --jq '.check_runs[]|select(.name|test("Elixir"))|"\(.conclusion)\t\(.name)\t\(.completed_at)"'

So "no `Elixir gate` check-run on the HEAD sha" is the EXPECTED reading while Test is in flight —
absence of the aggregate is not a jam signal. The jam signal is `updatedAt` not advancing.

Expected Test duration on this repo (quiet-host measurement from the immediately prior run):

    gh run view 32002021040 --json jobs \
      --jq '.jobs[]|select(.name|startswith("Test"))|"\(.conclusion)\t\(.startedAt)\t\(.completedAt)"'
    # success  2026-08-17T06:32:05Z  2026-08-17T06:46:48Z   → 14m43s

## 2. Crown reconcile's failure on the same HEAD is PRE-EXISTING and is now CURED

    gh run list --workflow crown-reconcile.yml --limit 25 \
      --json databaseId,headBranch,conclusion,createdAt \
      --jq '.[]|"\(.createdAt)\t\(.conclusion)\t\(.databaseId)"'
    gh run view 32002029369 --log-failed | grep -E "POPULATION|COULD NOT VERIFY"
    gh run view 31901232051 --log-failed | grep -E "POPULATION|COULD NOT VERIFY"   # 2026-08-15, same text
    gh run view 32003613747 --log | grep -E "POPULATION|RECONCILED"                # the cure

Verdict is rc=2 SILENCE with the named condition `POPULATION: 0 successful deploy.yml run(s) on
main in the window`. Six consecutive scheduled runs failed this way from 2026-08-15T18:28 through
2026-08-17T06:31 — i.e. it began BEFORE #11552/#11553 existed, and its cause is a repo that did
not deploy for 24 h, not a regression. The 06:55 re-run on the SAME sha reports
`POPULATION: 2 … 2 of them DELIVERED` and `RECONCILED`. Wave 67's own merges are what cured it.

## 3. #10086 is NOT unrebasable — its whole conflict is a one-line import collision

    git fetch origin pull/10086/head:pr10086tmp
    B=$(git merge-base origin/main pr10086tmp)
    git log -1 --format='%H %ci %s' $B          # 95642c5500 2026-08-07 → 345 commits behind
    git rev-list --count $B..origin/main
    git merge-tree $B origin/main pr10086tmp | grep -c '<<<<<<<'      # → 1
    git merge-tree $B origin/main pr10086tmp | sed -n '265,300p'

The single marker is client.go's import block: `"strconv"` (main) vs `"sort"` (PR). Union
resolution, gofmt-sorted. `internal/cli/cloud_support_cmd_test.go` is "changed in both" but merges
clean. Only 2 of the PR's 6 files moved on main since the base, and `cloudError`'s own body did
not move:

    git diff $B origin/main --stat -- internal/cloudclient/client.go internal/cli/errors.go \
      internal/cli/cloud_support_cmd.go internal/cli/cloud_rollback_cmd.go internal/cli/cloud_support_cmd_test.go

The fix is genuinely UNLANDED (do not assume the census work superseded it):

    git show origin/main:internal/cli/errors.go | grep -n 'no_team'          # rc=1, nothing
    git show origin/main:internal/cloudclient/client.go | grep -n CloudRefusal   # nothing
    git ls-tree origin/main internal/cloudclient/ --name-only | grep refusal_test  # absent

Its row is open at 8/9 with only the MERGE-GATED criterion unmet:

    bp task get cch-w40-s4-the-cli-reads-the-refusal-evidence-instead-of-printing-a-bare-slug
