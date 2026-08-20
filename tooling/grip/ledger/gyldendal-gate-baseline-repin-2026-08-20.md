# gate-baseline re-pin — Gyldendal field-report wave 1

Verifier: gate-baseline-now. Date 2026-08-20. NOT committed by me; Decide commits.

## The sha

Charter pins `6f724edfd8` (line 5). LIVE main is `a07a0baa138d628987706e94a31329379410f23a`
(2 commits ahead, both docs/ci-only). `internal/` is BYTE-IDENTICAL across the pair, so a
local Go run at 6f724edfd8 is a valid test of live main's Go tree.

    gh api repos/FRIKKern/barkpark/commits/main -q .sha
    git diff --stat 6f724edfd8 a07a0baa138d628987706e94a31329379410f23a -- internal/   # empty
    git log --oneline 6f724edfd8..a07a0baa138d628987706e94a31329379410f23a

## Elixir gate on live main

    gh run list --workflow=elixir.yml --branch=main --limit 6 \
      --json status,conclusion,headSha -q '.[]|"\(.status)/\(.conclusion) \(.headSha[0:10])"'
    gh run view 32385756173 --json jobs -q '.jobs[]|"\(.status)/\(.conclusion)\t\(.name)"'

SETTLED: run 32385756173 concluded **completed/success**. All seven jobs green, including
`Test (Elixir 1.18.1 / OTP 27.0)` and the `Elixir gate` aggregator. It was `in_progress` for
~12 minutes first — a survey that sampled early would honestly have read PENDING, which is
what the charter-era note recorded.

All THREE renderable required contexts are green on a07a0baa13:

    gh api "repos/FRIKKern/barkpark/commits/a07a0baa138d628987706e94a31329379410f23a/check-runs?per_page=100" \
      -q '.check_runs[]|select(.name=="Cloud gate" or .name=="Console gate" or .name=="Elixir gate")|"\(.conclusion) \(.name)"'
    # success Cloud gate / success Console gate / success Elixir gate

The fourth required context, "PR references an active task", renders on PR heads only and is
correctly ABSENT on a main commit. Do not read that absence as a red.

**BASELINE FOR THIS WAVE: origin/main a07a0baa138d628987706e94a31329379410f23a, required gates GREEN.**

## The Go red — the charter names the WRONG test

`go-tests` on main: 18 failure / 4 success / 3 cancelled over the last 25 runs.

    gh run list --workflow=go-tests.yml --branch=main --limit 25 --json conclusion -q '.[].conclusion' | sort | uniq -c

Two DISTINCT causes, not one:

1. `TestMomentumInFlightDenominatorCollapsed` (internal/taskboard, render_test.go:321) —
   the CHRONIC one, in 7 of 8 sampled reds spanning 2026-08-18..08-19. **ALREADY FIXED** by
   `0bdc9f8bf2 fix(taskboard): restore the D115/D120 mutation control's teeth after D124
   moved the collapse into BuildBoard (#12720)`. go-tests went green at exactly that head
   (2026-08-20T04:04:29Z) and the test has not failed since. NOT a builder hazard.

2. `TestRemoveFullCycleByteClean` (internal/scaffy) — the one the charter names. A REAL but
   INTERMITTENT flake, 1 red in the 5 runs after the taskboard fix. Root cause proven:
   `snapshotTree` (internal/scaffy/apply_test.go:97) does `filepath.Walk(root, ...)` with
   **no `.git` exclusion**, and the test does `git init` / `add -A` / `commit` inside root.
   Git's background auto-maintenance creates and deletes `.git/objects/maintenance.lock`
   concurrently with the walk. Both observed failure lines are the same cause:
     · remove_test.go:87  `lstat …/.git/objects/maintenance.lock: no such file or directory`
     · remove_test.go:128 `after remove: file .git/objects/maintenance.lock vanished`

   **UNREPRODUCIBLE LOCALLY BY CONSTRUCTION.** CI runs git 2.55.0; this host runs
   2.39.5 (Apple Git-154), which does not create the lock. 5/5 local passes are honest and
   prove nothing about CI.

       for i in 1 2 3 4 5; do go test ./internal/scaffy/ -race -count=1 -run TestRemoveFullCycleByteClean; done
       # NOTE: -count=1 is MANDATORY. Without it runs 2..N report "(cached)" and are vacuous.
       gh run view 32355132650 --log-failed | grep -A3 'FAIL: TestRemoveFullCycleByteClean'

   One-line fix available: skip `.git/` in snapshotTree. `.git` contents are not what
   "byte-clean" means — the test separately asserts the real D34 gate (`git diff --stat` empty).

## go-tests is NOT a required check, and NOT excluded either

`.github/required-checks.json` `required_status_checks.checks` is exactly FOUR:
Cloud gate, Console gate, Elixir gate, "PR references an active task". `go-tests` appears
in neither `checks` nor `exclusions`.

    git show origin/main:.github/required-checks.json | jq -r '.protection.required_status_checks.checks[].context'
    git show origin/main:.github/required-checks.json | jq -r '.exclusions[].context' | grep -i go

Reason is documented in the file's own `_readme`: go-tests.yml carries a workflow-level
`on: … paths:` filter (`**/*.go`, go.mod, templates/**, …), which makes it S4 structurally
disqualified from being required; and exclusions "are what the sample saw", so a
paths-filtered workflow that did not render on the sampled heads is invisible to the
generator. Same blind spot the `gofmt drift ceiling` exclusion row documents at length.

**Consequence for this wave:** a D4-adjacent PR touching `internal/cli` DOES re-trigger
go-tests (paths `**/*.go`), can inherit the scaffy flake, and that red BLOCKS NOTHING —
it is advisory by absence. Budget it as noise; do not let a builder chase it as their own
regression.

## "Absent required-context census" — failed, but NOT on a missing context

    gh api "repos/FRIKKern/barkpark/commits/6f724edfd84efc9fd804e97de3051d712e3fa574/check-runs?per_page=100" \
      -q '.check_runs[]|select(.name=="Absent required-context census")|"\(.conclusion) \(.html_url)"'
    gh run view --job=96436880002 --log | tail -40

Decisive line: `SUMMARY  absent=0  stale-queued=15  unknown=0`.

**absent=0** — every required context renders on every open head. The failure is entirely
`stale-queued=15`: abandoned queued runs on dead branches, oldest `pr-task-gate.yml` run
29988818645 at attempt 9, age 677.5h (28 days). None touch this wave.

It is neither required nor excluded BY DESIGN, documented in
`.github/workflows/absent-context-census.yml` reason #2: it is `schedule` +
`workflow_dispatch` only, with NO `pull_request` trigger, precisely so the required-checks
generator cannot see it and it can never become eligible to gate a merge. Not an oversight.

It has failed on all 6 most recent scheduled runs (2026-08-19T07:04 → 08-20T13:10) — a
chronic red nobody is clearing. Worth its own task; irrelevant to S1/S2.
