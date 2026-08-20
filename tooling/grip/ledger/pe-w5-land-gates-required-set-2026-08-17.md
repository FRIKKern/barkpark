<!-- ledger: re-derivation recipe, pe-w5 land-gates-proof, 2026-08-17 -->

# PE wave-5 LAND gate proof — required-check set + advisory-red classification

Branch-protection REST/GraphQL 503'd all session. The required set is re-derivable from the
committed spec CI verifies live protection against — this is the authoritative alternate path.

## Required set (FOUR, strict:false, enforce_admins:true)

    git show origin/main:.github/required-checks.json | jq '.protection.required_status_checks.checks[].context'

Yields exactly: `Cloud gate`, `Console gate`, `Elixir gate`, `PR references an active task`.
Cross-confirmed by MEMORY.md [no-branch-protection-sr1] ("the set is FOUR as of 2026-08-03").
Sobelow / Doc budgets / Format / Required-check spec drift are all enumerated in `.exclusions`
(S2 advisory, S4 paths-filtered, S6 leaf-of-excluded-aggregator) — none can gate a merge.

## All four required green on every PR head

    for h in <11845-head> <11814-head> <11854-head>; do
      gh api repos/FRIKKern/barkpark/commits/$h/check-runs \
        --jq '.check_runs[]|select(.name=="Cloud gate" or .name=="Console gate" or .name=="Elixir gate" or .name=="PR references an active task")|{name,conclusion}'
    done

11845 head f25fe995 · 11814 head 6b018c63 · 11854 head c826bd39 — 4/4 success each.
mergeStateStatus UNSTABLE is driven ONLY by excluded advisory reds.

## Sobelow red = stale-baseline line-shift, NOT a new finding (no waiver needed)

    gh run view --repo FRIKKern/barkpark --job <sobelow-job> --log \
      | grep -F "Sobelow (--skip reads" | grep -E "Confidence|File:"

Deciding scan on 11814 head AND on main head a9d29985 both report the SAME 6
`Config.CSRF: Missing CSRF Protections - High Confidence` findings, all in
`lib/barkpark_web/router.ex`. Neither #11814 nor #11854 touches router.ex
(`gh pr diff <n> --name-only | grep router` → empty). Fails identically on main → precedent red.

## Main-head Doc-budgets red = infra flake, not budget overflow

Main head Doc-budgets job failed at `actions/setup-go` download: `429 Too Many Requests` /
`503` after 3 attempts. No budget/anchor assertion ran. Paths-filtered (excluded), so it does
not render on the two PR heads at all.

## Main Elixir gate on current head: success (was in_progress at survey)

    gh api repos/FRIKKern/barkpark/commits/main/check-runs --jq '.check_runs[]|select(.name=="Elixir gate")'
