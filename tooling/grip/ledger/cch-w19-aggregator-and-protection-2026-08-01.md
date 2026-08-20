# cch-w19 — aggregator wiring + live branch protection (re-derivation recipes)

Verifier lane [aggregator-and-protection], 2026-08-01. Every row re-derives from
origin/main or the LIVE GitHub API. Nothing here is quoted from a prior phase.

## R1 — needs↔env↔decide chain in console-gate is 6/6/6 and set-equal
    git show origin/main:.github/workflows/console-harness.yml \
      | grep -nE 'needs: \[|R_[A-Z]+:|decide "'
    git show origin/main:.github/workflows/console-harness.yml | grep -c 'decide "'   # 6
Expect: needs=[changes, console-unit, cssom-parity, tier-floor-render,
overflow-guard, path-escape] (6); six R_* env bindings; six decide calls.
`overflow-guard` is present in all three: needs[5], `R_OVERFLOW`, and
`decide "overflow-guard" "${R_OVERFLOW}" "${O_CONSOLE}"` (line 639).

## R2 — no continue-on-error anywhere in console-harness.yml
    git show origin/main:.github/workflows/console-harness.yml \
      | grep -cE '^\s*continue-on-error\s*:'    # 0
The 4 textual hits are prose in comments (lines 354, 411, 470, 550).

## R3 — the chain is MACHINE-enforced, not comment-enforced (D36)
The emitter + its four-direction mutation proof live in
scripts/console-path-escape-check.test.sh, reached from CI via
`console-path-escape-check.sh --selftest` (which `exec`s the .test.sh):
    git show origin/main:scripts/console-path-escape-check.test.sh \
      | grep -nE 'needs_without_decide|assert_fact_min|direction '
    git show origin/main:scripts/console-path-escape-check.sh | sed -n '345,347p'
    git show origin/main:.github/workflows/console-harness.yml | sed -n '192,207p'
Assertions: `needs_without_decide = ""` (set-based, stronger than a count),
`coe_in_needs = ""`, `blocking_not_in_needs = ""`, plus MIN-4 counts.
Mutation modes: clean / needs / env / wired.
NOTE: the min-4 counts do NOT pin 6 — the teeth are the set assertion.

## R4 — LIVE required contexts on main (authority: the API, not the file)
    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '.required_status_checks.checks'
    gh api repos/FRIKKern/barkpark/rules/branches/main        # [] — no rulesets
Live = exactly ["Elixir gate", "PR references an active task"];
strict=false, enforce_admins=true. "Console gate" and "Cloud gate" are NOT
required. The committed spec lists four:
    git show origin/main:.github/required-checks.json | python3 -c \
      "import json,sys;print([c['context'] for c in json.load(sys.stdin)['protection']['required_status_checks']['checks']])"

## R5 — the drift is already reported, advisorily
    gh run view 30708222070 --log --job 91391131283 | sed -n '271,281p'
=> "── 11 (live half). full mode tracks the COMMITTED spec against reality ──"
   "FAIL full mode reds on the committed spec"; "114 passed, 1 failed".
The job carries continue-on-error, so main merges over it.

## R6 — both aggregator + guard already ran green on ubuntu on main HEAD
    gh api "repos/FRIKKern/barkpark/commits/$(git rev-parse origin/main)/check-runs?per_page=100" \
      --jq '.check_runs[]|"\(.name)\t\(.conclusion)"' | sort
=> "Overflow guard (rendered) success" and "Console gate success" at 29cb76e60.
Also visible: "Cloud gate failure" on a main head whose required set is green —
independent proof that Cloud gate cannot block a merge today.
