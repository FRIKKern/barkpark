<!-- doc-tier: cold | canonical-for: cch-w71-charter-coverage-smoke-rederivation | budget: 900tok -->

# cch-w71 charter-coverage smoke — re-derivation recipe (2026-08-17)

Wave-71 verifier `charter-coverage-smoke`. All wave-70 decisions (D853-D860) live
ONLY on the unmerged charter branch until #11831 merges. Re-derive every fact:

## D853-D860 full texts (branch-sourced, ABSENT on origin/main)

    BR=origin/epic-charter/cloud-console-hardening-20260817T133644Z
    CH=.claude/workflows/bp-cloud-console-hardening-charter.md
    git fetch origin
    git show $BR:$CH | grep -nE '^\| D85[3-9]|^\| D860'   # rows at ~1324-1330
    # verbatim D854 (mint-sibling fixture ruling): git show $BR:$CH | sed -n '1325p'

## E1 guard — D853+ are branch-only; ceiling on main is still D852

    git show origin/main:$CH | grep -oE '^\| D8[0-9][0-9]' | tail -3   # => D850/D851/D852
    for d in D853 D858 D860 D861; do echo "$d main:$(git show origin/main:$CH|grep -c "^| $d ")"; done  # all 0
    for d in D853 D860 D861; do echo "$d branch:$(git show $BR:$CH|grep -c "^| $d ")"; done              # 1/1/0

## Required-check blocking set (branch-protection API was 503; spec is CI-proven == live)

    git show origin/main:.github/required-checks.json | jq -r '.protection.required_status_checks.checks[].context'
    # => Cloud gate · Console gate · Elixir gate · PR references an active task  (4; strict:false; enforced:true)
    # "Required-check spec gate" (blocking, passes on #11850) enforces spec == live protection.

## #11831 (charter) and #11850 (S5 worker-normalise) rollups

    gh pr view 11831 --repo FRIKKern/barkpark --json state,mergeStateStatus,mergeable
    # => OPEN / UNSTABLE / MERGEABLE  (UNSTABLE = advisory "Required-check spec drift" red only)
    gh pr checks 11850 --repo FRIKKern/barkpark
    # => all 4 blocking contexts PASS incl "Cloud control-plane (test)" 2m57s; only advisory spec-drift fails => merge-ready

NOTE: GitHub graphql + branches/*/protection endpoints returned HTTP 503 intermittently;
REST check-runs and `git show` were authoritative. Re-run protection API when it recovers to cross-check the 4.
