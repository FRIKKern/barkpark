# CI topology for a `.claude/**` portability tripwire — re-derivation recipe (2026-08-12)

Verifier row for the epic-cycle distribution wave. Every claim below is re-derivable by the
command directly under it. Nothing here was read from a committed spec alone.

## 1. main's required contexts are exactly four

    gh api repos/FRIKKern/barkpark/branches/main/protection --jq '.required_status_checks.checks[].context'

    Elixir gate
    PR references an active task
    Cloud gate
    Console gate

## 2. doc-gates.yml is NOT push-only — it HAS a 67-path `pull_request:` block

The digest's "CONTRADICTION RESOLVED: the file on origin/main is push-to-main ONLY" is REFUTED.
It was derived from `sed -n '1,20p'`, which stops 125 lines before the second trigger.

    git show origin/main:.github/workflows/doc-gates.yml | grep -n '^on:\|^  push:\|^  pull_request:\|^jobs:'
    # 8:on:   9:  push:   145:  pull_request:   288:jobs:

    git show origin/main:.github/workflows/doc-gates.yml | sed -n '145,287p' | grep -c '^\s*- "'
    # 67

## 3. …but neither doc-gates nor shell-harnesses can ever BLOCK

Both carry workflow-level `on: … paths:`. Per `.github/required-checks.json` `_readme`
(honest-gates D18), a paths-filtered workflow is STRUCTURALLY DISQUALIFIED from being a required
context: it emits no check run on a PR that misses the paths, and an absent required context
reports `expected` forever. shell-harnesses.yml says so in its own header:

    git show origin/main:.github/workflows/shell-harnesses.yml | sed -n '80,84p'
    # "Note this workflow is NOT one of main's required contexts (those are exactly:
    #  Elixir gate, PR references an active task, Cloud gate, Console gate) —
    #  wiring the census makes it RUN, not BLOCK."

Consequence for the wave: a tripwire added to doc-gates or shell-harnesses RUNS and is advisory.

## 4. The four required aggregators have NO workflow-level paths filter

    for f in elixir.yml cloud.yml console-harness.yml pr-task-gate.yml; do
      git show origin/main:.github/workflows/$f | grep -n '^on:\|^  pull_request:\|^  push:'
    done
    # each: `on:` then bare `pull_request:` / `push:` — no `paths:` key

They gate per-job via `changes` (Dispatch (changed-path sets), elixir.yml:78) and aggregate with
`elixir-gate` (elixir.yml:635, `if: always()`, `needs: [changes, mix-test, mix-prod-compile,
validation-perf, path-escape]`). A BLOCKING `.claude/**` tripwire therefore has exactly two
shapes: (a) a new job + a new dispatcher path-set under one of these four aggregators, added to
its `needs`; or (b) a new unfiltered workflow put through
`scripts/required-checks-generate.sh` → `required-checks-floor.sh` → `required-checks-apply.sh`.

## 5. No workflow on main references `.claude` at all

    for f in $(git ls-tree --name-only origin/main .github/workflows/); do
      echo "$(git show origin/main:$f | grep -c '\.claude') $f"; done | awk '$1>0'
    # (no output)   # 48 workflow files total

## 6. A `.claude/workflows/*.workflow.js`-only PR merges green — proven on a merged PR

PR #11079, `fix(epic-cycle): PAPER_BLOCK mandates top-level blocks…`, merged 2026-08-09,
single file `.claude/workflows/bp-epic-cycle.workflow.js`, head `abb4c3c2a85`.

    gh api repos/FRIKKern/barkpark/commits/abb4c3c2a854cda8ba4913b997fe989f3c455ffb/check-runs \
      --paginate --jq '.check_runs[] | .name + " | " + (.conclusion//"null")'
    # Elixir gate | success        (its matrix leaves all `skipped`)
    # Cloud gate | success
    # Console gate | success
    # PR references an active task | success
    # …and NO "Doc budgets + anchors" line at all

Contrast PR #11420 (`.claude/workflows/…-charter.md`, head `9711f87c463`): same query DOES emit
`Doc budgets + anchors | success`, because `**/*.md` is in doc-gates' pull_request paths.
So doc-gates fires on charter `.md` edits and is silent on engine `.js` edits — today the
distributed engine files pass through CI completely unexamined.
