<!-- doc-tier: cold | canonical-for: onb-w5-round0-ci-red-root-cause-rederivation | budget: 900tok -->

# Onboarding W5 Round-0 CI-red root cause — re-derivation recipe

Verifier ci-red-root-cause, 2026-08-17. Re-derive every claim from a clean checkout.

## The FOUR blocking required contexts (live branch protection)

    gh api repos/{owner}/{repo}/branches/main/protection --jq '.required_status_checks.contexts,.required_status_checks.strict'
    # => ["Elixir gate","PR references an active task","Cloud gate","Console gate"]  strict=false

Memory's "set is FOUR" holds. All four PASS on 12029 and 12030:

    for ctx in "Elixir gate" "PR references an active task" "Cloud gate" "Console gate"; do
      gh pr checks 12030 | grep -F "$ctx"$'\t'; done   # all pass
    gh pr view 12030 --json mergeable,mergeStateStatus   # MERGEABLE / UNSTABLE

UNSTABLE = mergeable-but-failing-NON-required-checks. The merge button is FREE.
No repair prefix is required to merge any of the 8 PRs. The "waiting-room deadlock" is NOT active.

## Why the three red gates are red — ALL exogenous main drift (0/8 PRs touch them)

1. Doc budgets + anchors (blocking) — deciding line, NOT the local run:
   gh run view --job 95502041179 --log | grep 'canonical-for'
   => FAIL: canonical-for 'none' has more than one owner:
      ./tooling/grip/ledger/cch-w35-telegram-webhook-dead-union-2026-08-17.md
      ./tooling/grip/ledger/cch-w35-connectors-public-route-rederive-2026-08-17.md
   Both on origin/main (git show origin/main:<path> | head -1 => canonical-for: none).
   LOCAL `bash scripts/docs-anchors-check.sh` fails for a DIFFERENT reason (untracked mainbase/
   tree duplicates every slug) — ignore that; CI has no mainbase/. `bash scripts/check-doc-budgets.sh` PASSES.
   REPAIR: give each colliding ledger file a UNIQUE canonical-for slug (six files carry
   'none' on main; 3 are .claude/workflows charters the §5 scan skips, so dedupe the ledger ones).

2. Required-check spec gate (NOT required, red) — `scripts/required-checks.test.sh --hermetic`,
   176 passed / 1 failed:
   gh run view --job 95502041945 --log | grep 'protection-claim census moved'
   => FAIL ... UNPINNED 25db097ed62f / 451500fdf367
      tooling/grip/ledger/felix-w25-sobelow-row-verdicts-2026-08-17.md:39-40
   Exogenous Felix-domain ledger file on origin/main. REPAIR: pin the two protection-claim
   lines (drop the pin in the SAME commit) — arguably Felix wave's own repair.

3. gofmt drift ceiling (blocking, NOT required):
   git show origin/main:internal/cli/scaffy_describe_cmd_test.go > /tmp/sd.go && gofmt -l /tmp/sd.go
   => /tmp/sd.go (UNFORMATTED). Scaffy file, untouched by any of the 8 PRs.
   REPAIR: gofmt -w internal/cli/scaffy_describe_cmd_test.go on main.

## Ordered Round-0 repair list (lead, all on main, all one-time)

None GATE the merge button. Do them to stop compounding main drift + honor never-merge-red:
R0a. gofmt -w internal/cli/scaffy_describe_cmd_test.go
R0b. dedupe canonical-for:'none' on the two cch-w35 ledger files (+ cch-w69 to be safe)
R0c. pin (or drop) felix-w25-sobelow-row-verdicts lines 39-40 protection claims
Then merge the 8 PRs (already MERGEABLE). No PR-specific repair exists — the reds are shared main drift.
