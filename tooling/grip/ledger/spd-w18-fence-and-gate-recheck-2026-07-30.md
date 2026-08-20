# spd-w18 verifier — fence-and-gate recheck (2026-07-30)

Re-derivation recipes. Every line is a single command that reproduces the fact
from scratch. Authority: L1 (live GitHub / live ledger) unless marked.

## Required checks (L1, live GitHub)

    gh api repos/FRIKKern/barkpark/branches/main/protection -q '{admins:.enforce_admins.enabled,strict:.required_status_checks.strict,checks:[.required_status_checks.checks[]?.context]}'
    # => {"admins":true,"checks":["Elixir gate","PR references an active task"],"strict":false}

## tooling/** is dispatched on by NOTHING in the Elixir gate

    printf 'tooling/studio-journey/journey.mjs\n' | bash scripts/elixir-path-escape-check.sh --match compile   # false
    printf 'tooling/studio-journey/journey.mjs\n' | bash scripts/elixir-path-escape-check.sh --match test      # false
    git show origin/main:scripts/elixir-path-escape-check.sh | sed -n '69,101p'   # the two declared sets; no tooling/ entry
    git grep -n 'tooling/' origin/main -- .github/workflows   # only advisory/paths-filtered workflows

## Only compile|test set names exist (a third path set needs a code edit)

    git show origin/main:scripts/elixir-path-escape-check.sh | sed -n '/^assert_set_name/,/^}/p'

## The aggregator must be edited to gate a new job

    git show origin/main:.github/workflows/elixir.yml | sed -n '606,610p'   # needs: [changes, mix-test, mix-prod-compile, validation-perf, path-escape]

## The ratchet is under-inclusion-only (declaring an unread path is free)

    bash scripts/elixir-path-escape-check.sh --check   # "OK: every repo-root read ... is dispatched on."

## pr-task-gate accepts a freshly claimed task without any clock input

    bash scripts/pr-task-gate.test.sh 2>&1 | grep -E 'active task passes|in_progress needs no PR_OPENED_AT'

## pr-task-gate reds on the three unclaimed slice tasks (live ledger)

    for t in spd-w17-browser-journey spd-w17-never-blank spd-w17-pending-honest; do TASK_ID=$t PR_OPENED_AT=2026-07-30T00:00:00Z bash scripts/pr-task-gate.sh; done

## pr-task-gate re-fire surface (reading, L4)

    git show origin/main:.github/workflows/pr-task-gate.yml | sed -n '54,78p'
    # types: [opened, synchronize, reopened, edited, labeled, unlabeled]
    # NO trigger fires on a LEDGER change: claiming after a red needs a push/edit/re-run.

## Fence PRs

    for n in 2907 6055; do gh pr view $n --json mergeable,mergeStateStatus,updatedAt; done
    gh pr view 6055 --json statusCheckRollup -q '.statusCheckRollup[]|"\(.name // .context) \(.conclusion // .state)"'
    # "Elixir gate" is ABSENT from 6055's head rollup — head predates the aggregator:
    git log origin/main -1 --format='%H %ad' -S'elixir-gate:' -- .github/workflows/elixir.yml   # 2c7f864e, Tue Jul 28 2026

## Browser-harness precedent cost (L1)

    gh run list --workflow=search-starter-smoke.yml --limit 8 --json conclusion,createdAt,updatedAt -q '.[]|"\(.conclusion) \(.createdAt) -> \(.updatedAt)"'
    # pull_request runs: 1m07s .. 2m16s wall, system /usr/bin/google-chrome, no npm install
