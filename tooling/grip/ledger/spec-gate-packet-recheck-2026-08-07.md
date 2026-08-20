# Spec-gate human packet — re-derivation recipe (2026-08-07, wave 38 verify)

Every number below is re-derivable with the command beside it. Run from a worktree cut at
`origin/main` — the primary checkout is 504 commits behind and gives a FALSE RED off a 2.2x
smaller suite (54 passed / 1 failed vs 119 passed / 0 failed, same command, same second).

    git worktree add --detach /tmp/wt-sg38 origin/main && cd /tmp/wt-sg38

| claim | rerun |
|---|---|
| hermetic suite: `119 passed, 0 failed`, rc 0 | `bash scripts/required-checks.test.sh --hermetic; echo RC=$?` |
| live suite (token exercises §10/§11): `123 passed, 0 failed`, rc 0 | `bash scripts/required-checks.test.sh; echo RC=$?` |
| primary checkout is behind, and its suite is smaller | `git rev-list --count HEAD..origin/main` in the primary checkout, then the hermetic run there |
| identity sweep short-circuits (no candidate = no evidence) | `bash scripts/registration-deadlock-sweep.sh --ref-rev origin/main --limit 100` |
| build the 5-context candidate | `jq '.protection.required_status_checks.checks += [{"context":"Required-check spec gate","app_id":15368}]' .github/required-checks.json > /tmp/_cand5.json` |
| sweep with the fifth context: rc 0, **2 ok / 20 skip of 22**, denominator NOT printed | `bash scripts/registration-deadlock-sweep.sh --spec /tmp/_cand5.json --ref-rev origin/main --limit 100; echo RC=$?` |
| floor refuses growth (rc 2), names the added context | `bash scripts/required-checks-floor.sh --ref-rev origin/main /tmp/_cand5.json; echo RC=$?` |
| verify is RED (rc 1) while spec says 5 and live says 4 — the announced drift red | `bash scripts/required-checks-verify.sh --spec /tmp/_cand5.json --ci; echo RC=$?` |
| gh token reaches the admin-only protection endpoint; live set is 4, enforce_admins true | `gh api repos/FRIKKern/barkpark/branches/main/protection --jq '.required_status_checks.checks[].context, .enforce_admins.enabled'` |
| #8222 is CLOSED, mergedAt null — the exclusion's stated trigger can never fire | `gh pr view 8222 --json state,mergedAt` |
| generate.sh:146 still carries the pre-wave-36 stale reason; the JSON was hand-corrected and the generator was not | `awk 'NR==146' scripts/required-checks-generate.sh \| grep -c 'CORRECTED AGAIN'` (0) vs `jq -r '.exclusions[]\|select(.context=="Required-check spec gate").reason' .github/required-checks.json \| grep -c 'CORRECTED AGAIN'` (1) |
| the two arrays are index-parallel, so deleting the name forces deleting the reason | `grep -n 'EXCLUDED_BY_DECISION' scripts/required-checks-generate.sh` → :141 NAMES, :145 REASONS, :713-715 index zip |
| three OPEN duplicate roster rows for one act | `for t in cch-w35-bl-register-spec-gate-as-fifth-context cch-w36-bl-register-spec-gate-after-census-green cch-w37-bl-register-spec-gate-human-gate; do bp task get "$t" -o json \| jq -c '.doc.lifecycle_status'; done` |
| #9921 is the fix that makes the sweep print its own coverage | `gh pr view 9921 --json title,mergeStateStatus,files` |

VERDICT: the packet is NOT authorized today. Not because a command failed — every one passed —
but because the sweep that authorizes the flip evaluated 2 of 22 open PRs and its own footer does
not say so. #9921 must land first; it turns that footer into `evaluated 2, skipped 20 (…)` plus a
`PARTIAL COVERAGE` line, which is the sentence a human must paste into the authorization.
