# cch wave 36 — prior-art resweep, re-derivation recipes (2026-08-06)

Verifier lane `prior-art-resweep`. bp was DOWN for 12 of 16 wave-36 surveyors and
exits 0 on that failure, so "no prior art" in most survey reports meant "never
checked". bp is up; every search below was re-run for real.

Tree of record: `origin/main` = `070c7584b820`, committed 2026-08-06T11:51:23Z,
confirmed identical to the remote head at read time.

## Recipes

    # bp is actually up (not exit-0 silence)
    bp capabilities -o json | head -c 200

    # the tree is current, not a stale local origin/main
    gh api repos/FRIKKern/barkpark/commits/main --jq '.sha[0:12]'
    git rev-parse --short=12 origin/main

    # prior art per candidate ("query" sub-verb is REQUIRED)
    bp search query "friendly precedence ERRORS map forbidden slug" -o json
    bp search query "un-predicated write affordance checkout owner admin" -o json
    bp search query "operator silent bounce authority" -o json
    bp search query "meCache role unknown loadMe" -o json
    bp search query "protection claim census section 18" -o json
    bp search query "ERRORS map narrowness allowlist pinned census client predicate" -o json
    bp search query "client predicate server gate pairing census app.js role" -o json
    bp search query "checkout_path 402 payload admin owner go_live" -o json
    bp search query "role unknown boot race loadMe un-awaited predicate coerce null" -o json
    bp search query "metricsFailureCopy operatorPaint retry cannot succeed 403" -o json

    # the two briefs two surveyors failed to fetch
    bp task get cch-w35-s4-forbidden-evidence-beats-the-global-slug -o json
    bp task get cch-w34-bl-bare-friendly-renders-billing-copy-on-four-reads -o json

    # the ratified ruling that decides the anchor slice's lane
    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
      | grep -n 'D395'

    # the live required-context set (four; the spec gate is NOT one of them)
    gh api repos/FRIKKern/barkpark/branches/main/protection \
      --jq '{contexts:.required_status_checks.contexts, enforce_admins:.enforce_admins.enabled}'

    # the merge-half exhibit, run on a CLEAN worktree cut from origin/main
    cd <worktree-at-070c7584b> && bash scripts/required-checks.test.sh --hermetic
    # -> exit 1, "115 passed, 1 failed", sole failing clause is section 18

    # the section-18 delta is PRE-WRITTEN in the guard's own comment
    git show origin/main:scripts/required-checks.test.sh | sed -n '1595,1620p'

    # pins are matched by CONTENT HASH ONLY (path:line in a pin row is annotation)
    git show origin/main:scripts/required-checks.test.sh | sed -n '1735,1746p'

## Standing hazard for anyone writing in this directory

`tooling/grip/ledger/**` is inside section 18's scan set. A ledger that quotes
the census's own search terms arrives as a new unreviewed row and reds the gate
locally. That is by design and the guard's comment says so. This file was
written to avoid those literals deliberately.
