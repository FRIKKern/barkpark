# doc-gates requirability — S4 is a workflow-level `pull_request: paths:` test, not a name test (2026-08-18)

VERDICT: "Doc budgets + anchors" CAN become a required context. S4 does NOT exclude
"every check inside a paths-filtered workflow by construction" in the sense that no edit
could ever change it — it excludes every check whose workflow declares a WORKFLOW-LEVEL
`on: pull_request: paths:` (or `paths-ignore:`) key. Delete that one key from
`.github/workflows/doc-gates.yml` (the `on: push:` paths block may stay) and the same job,
same name, same fixtures is KEPT and emitted into `protection.required_status_checks.checks`.

Baseline facts on origin/main 541195b5d1:
- required contexts = 4 (Cloud gate, Console gate, Elixir gate, PR references an active task).
- "Doc budgets + anchors" sits in `.exclusions` with the S4 reason.
- It is NOT in ADVISORY_BY_INTENT_NAMES nor EXCLUDED_BY_DECISION_NAMES — S4 is its SOLE blocker.
- doc-gates.yml `on: pull_request:` carries 69 enumerated `paths:` entries (lines 160-310).

## Re-derive the structural read

    git show origin/main:scripts/required-checks-generate.sh | sed -n '298,304p'   # pf=1 set here
    git show origin/main:scripts/required-checks-generate.sh | sed -n '707,712p'   # S4 uses pf only
    git show origin/main:scripts/required-checks-generate.sh | sed -n '524,552p'   # no CLI override exists

`pf` is set by one awk line inside the `on:` block: `inon && inpr && /^    paths(-ignore)?:/ { pf = 1 }`.
Stage 2 can only ever ADD a reason; no later stage (S3/S5/S6/S7) un-excludes. No flag
(`--expect-promoted` included) forces a pf=1 name in.

## Re-derive the empirical proof (hermetic, no network, no repo mutation)

    T=$(mktemp -d); mkdir -p $T/wf $T/fix
    git -C <repo> show origin/main:scripts/required-checks-generate.sh > $T/gen.sh
    # control workflow, always-on
    printf 'name: plain\non:\n  pull_request:\njobs:\n  plain:\n    name: Control gate\n    runs-on: ubuntu-latest\n' > $T/wf/plain.yml
    # two check runs on two shas + a green main fixture
    R='{ "check_runs": [ {"name":"Doc budgets + anchors","conclusion":"success","started_at":"2026-08-01T01:00:00Z","app":{"id":15368}}, {"name":"Control gate","conclusion":"success","started_at":"2026-08-01T01:00:00Z","app":{"id":15368}} ] }'
    echo "$R" > $T/fix/checkruns-shaA.json; echo "$R" > $T/fix/checkruns-shaB.json
    echo "$R" > $T/fix/checkruns-shaMAIN.json; echo shaMAIN > $T/fix/main-shas.txt

    # VARIANT A — pull_request paths: present  -> EXCLUDED (S4), 0 contexts, exit 5 (floor)
    printf 'name: doc-gates\non:\n  pull_request:\n    paths:\n      - "**/*.md"\njobs:\n  gates:\n    name: Doc budgets + anchors\n    runs-on: ubuntu-latest\n' > $T/wf/docgates.yml
    bash $T/gen.sh --workflows $T/wf --fixture-dir $T/fix --no-merge --sha shaA --sha shaB --explain --out $T/A.json

    # VARIANT B — paths: removed              -> KEPT, emitted into protection
    printf 'name: doc-gates\non:\n  pull_request:\njobs:\n  gates:\n    name: Doc budgets + anchors\n    runs-on: ubuntu-latest\n' > $T/wf/docgates.yml
    bash $T/gen.sh --workflows $T/wf --fixture-dir $T/fix --no-merge --sha shaA --sha shaB --out $T/B.json
    jq -c '.protection.required_status_checks.checks' $T/B.json
    # -> [{"context":"Control gate","app_id":15368},{"context":"Doc budgets + anchors","app_id":15368}]

    # VARIANT C — push paths-filtered, pull_request UNfiltered -> KEPT (push filter is irrelevant to S4)
    # VARIANT D — pull_request paths-ignore:                   -> EXCLUDED (same S4 reason)

## Two prerequisites a promotion PR must also carry

1. `doc-gates.yml` sets `concurrency.cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}`.
   A required context whose latest run concluded `cancelled` blocks with a THIRD refusal
   shape and clears only on a re-run or push (generate.sh line 983; verify.sh lines 382-414).
   Promotion without changing that concurrency policy ships a self-inflicted merge stall.
2. Growth of the required set is gated, not forbidden: `required-checks-floor.sh` is a
   superset check and prints "FLOOR: the candidate ADDS required context(s)" unless
   `--acknowledge-growth` is passed. Verified live: `bash scripts/required-checks-verify.sh`
   on a clean `git archive origin/main` tree exits OK against real branch protection.
