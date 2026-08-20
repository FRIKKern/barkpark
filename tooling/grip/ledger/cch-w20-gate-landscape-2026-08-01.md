# Gate landscape — re-derivation recipes (cch wave 20 verifier, 2026-08-01)

Every line below is a command, not a claim. Run it; do not quote this file's prose.

## 1. Live branch protection on main (L1)

    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '{contexts:.required_status_checks.contexts,strict:.required_status_checks.strict,admins:.enforce_admins.enabled}'

Observed 2026-08-01:
`{"admins":true,"contexts":["Elixir gate","PR references an active task"],"strict":false}`

Protection IS enforced. TWO required contexts. `Console gate`, `Cloud gate`,
`CSSOM parity`, `Overflow guard (rendered)` are NOT among them.

## 2. The committed spec disagrees (this is what the drift advisory reports)

    git show origin/main:.github/required-checks.json | \
      python3 -c "import json,sys;d=json.load(sys.stdin);print(d['enforced'],[c['context'] for c in d['protection']['required_status_checks']['checks']])"

Observed: `True ['Cloud gate', 'Console gate', 'Elixir gate', 'PR references an active task']`

NOTE: a stale primary checkout reads `enforced:false` / 2 contexts. Use `git show origin/main:`.

## 3. Reproduce the drift verdict locally, by name

    mkdir -p /tmp/omain && git archive origin/main .github scripts | tar -x -C /tmp/omain
    cd /tmp/omain && GH_TOKEN=$(gh auth token) bash scripts/required-checks-verify.sh

Observed tail:
`DRIFT  required_status_checks.checks disagree` / `MISSING from live: Cloud gate (app_id 15368)` /
`MISSING from live: Console gate (app_id 15368)` / `FAIL: live config and the committed spec disagree.`

## 4. The CI advisory's own failing line

    gh run list --workflow=required-checks-drift.yml --branch=main --limit 1 \
      --json databaseId -q '.[0].databaseId' | xargs -I{} gh run view {} --log-failed | \
      grep -E "FAIL|required-checks: "

Observed: `FAIL full mode reds on the committed spec — hgw2-s7's slice gate cannot pass`
and `required-checks: 114 passed, 1 failed`. ONE failure, and it is item 2 above.

WARNING: `gh run list --json conclusion` reports this run as `success` (rollup), because the
job carries continue-on-error. Read the CHECK-RUN, not the run.

## 5. Shape of a green cloud-only PR this week

    sha=$(gh pr view 8946 --json headRefOid -q .headRefOid)
    gh api "repos/FRIKKern/barkpark/commits/$sha/check-runs?per_page=100" \
      -q '.check_runs[]|"\(.conclusion)\t\(.name)"' | sort

32 names. 7 `skipped` (the Elixir heavy jobs, via the dispatcher shim — GitHub counts
`skipped` as passing). `Elixir gate` green by shim. One `failure`: the drift advisory.
PR merged anyway — non-required reds do not block.

## 6. The unpaid registration row

    bp task get cch-w11-s1-flip-behind-a-generator-that-cannot-lose -o json | \
      python3 -c "import json,sys;c=json.load(sys.stdin)['doc']['content'];print(c['lifecycle_status'],c['priority']);[print(i,a['met'],a['criterion'][:90]) for i,a in enumerate(c['acceptance_criteria'],1)]"

`open`, priority 0, 9/13. Criterion 10 — "THE PUT, in ONE SITTING with the merge" — is FALSE.
The spec merged as #8394 (`dcd8c9cef`); the PUT to the GitHub API never ran.
