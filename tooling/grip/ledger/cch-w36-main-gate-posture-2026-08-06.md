# cch-w36 — main gate posture, re-derivation recipes (2026-08-06)

Verifier lane `main-gate-posture`. Every row is a command that re-derives the
fact from scratch. `main` head at time of writing: `070c7584b820745e1ac8377ca6926edef6d2f257`.

## R1 — what is actually red on main's head

    cd /Volumes/SATECHI/github/barkpark && git fetch origin -q
    sha=$(git rev-parse origin/main)
    gh api "repos/:owner/:repo/commits/$sha/check-runs?per_page=100" \
      --jq '.check_runs[]|"\(.conclusion // "PENDING")\t\(.name)"' | sort

Expect exactly two failures, both UNREGISTERED names:
`Required-check spec gate` and `Required-check spec drift (advisory)`.
All four REQUIRED contexts are green on that head (the Elixir gate was merely
in flight at 12:00Z and concluded `success` by 12:12Z — a PENDING is not a red).

## R2 — the four required contexts, live

    gh api repos/:owner/:repo/branches/main/protection \
      --jq '{checks:.required_status_checks.checks,strict:.required_status_checks.strict,admins:.enforce_admins.enabled}'

`strict:false` is the load-bearing field: a PR is NOT required to be up to date
with `main`, so main's own head never gates a PR's merge.

## R3 — the deciding output of the failing clause

    gh api repos/:owner/:repo/actions/jobs/92607849052/logs \
      | grep -nE "UNPINNED|STALE|passed, .* failed"

## R4 — recompute the census WITHOUT running the suite (hash = sha256(path|text))

    # Take the regex from the source of truth rather than re-typing it here —
    # quoting it verbatim would make THIS ledger a new UNPINNED census member.
    RE=$(git show origin/main:scripts/required-checks.test.sh | sed -n 's/^PROTECTION_CLAIM_RE=.\(.*\).$/\1/p')
    git grep -nHE "$RE" origin/main -- .claude/workflows .github docs scripts \
        tooling/grip/ledger CLAUDE.md ':!scripts/required-checks.test.sh' \
      | sed 's/^origin\/main://' \
      | while IFS= read -r l; do p="${l%%:*}"; r="${l#*:}"; t="${r#*:}"; \
          printf '%s %s:%s\n' "$(printf '%s' "$p|$t" | shasum -a 256 | cut -c1-12)" "$p" "${r%%:*}"; done

Compare against the pin list:

    git show origin/main:scripts/required-checks.test.sh | grep -E '^[0-9a-f]{12}  ' | awk '{print $1}' | sort -u

41 hits, 32 pins -> 11 UNPINNED + 2 STALE. The pin key is `sha12("$path|$text")`,
NOT path:line — so the line drift between the source comment (`:4496`) and the
CI row (`:4567`) is cosmetic and does not invalidate the pre-measured paste.

## R5 — prove the pre-measured fix closes it exactly

Union the 32 pins with the 11 hashes already written verbatim into
`scripts/required-checks.test.sh` (the block beginning `89ed1af64d9b  B`),
minus the two STALE pins `ce745c039e38` and `562eb5d348c9` -> 41 pins,
UNPINNED empty, STALE empty. Simulated on origin/main content, both sides `[]`.

## R6 — blast radius if the name were registered as a fifth context

    gh pr list --state open --json number,mergeable,mergeStateStatus,headRefOid
    for p in 9600 9530 8465 6028 6086 6057 2907; do
      gh api "repos/:owner/:repo/commits/$(gh pr view $p --json headRefOid --jq .headRefOid)/check-runs?per_page=100" \
        --jq '.check_runs[]|select(.name|test("spec gate"))|"\(.conclusion)\t\(.completed_at)"'
    done

Every green spec-gate verdict on an open PR is STALE (2026-07-31 .. 2026-08-05),
i.e. it was rendered against a merge ref whose base PREDATES the ledger commits
that now red the census. `required-checks-drift.yml` carries no `on: paths:`
key (deliberately, per its own header), so any re-push renders the name again —
red. 7 of 7 open PRs; 3 of them (6086/6057/2907) are CONFLICTING and render no
modern check names at all, so they would additionally route to
"expected forever" (D18).

## R7 — the exclusion's re-evaluation trigger is dead

    git show origin/main:.github/required-checks.json | python3 -c "import json,sys; print(json.load(sys.stdin)['exclusions'][5])"
    gh pr view 8222 --json state,mergedAt,closedAt

The exclusion says the gate is "green on main" (false as of 070c7584b) and that
it should be re-evaluated "once #8222 lands or is rebased" — #8222 is CLOSED,
`mergedAt: null`, closed 2026-07-31T02:45:36Z. The trigger can never fire.
