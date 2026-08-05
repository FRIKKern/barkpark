# Re-derivation recipes — PDS w49 verifier: `skipped` vs ABSENT, and the web-checks conclusion

Written 2026-08-05 by the wave-49 verifier for `pds-bl-w48-web-gate-cannot-block-and-greens-vacuously`.
No repo state changed. Every row below is a command that reproduces the fact from scratch.

## R1 — main's required contexts (four, enforce_admins on)

    gh api repos/:owner/:repo/branches/main/protection \
      --jq '{contexts:.required_status_checks.contexts,admins:.enforce_admins.enabled}'

Observed: `{"admins":true,"contexts":["Elixir gate","PR references an active task","Cloud gate","Console gate"]}`

## R2 — no required context has EVER concluded `skipped` on a merged head (n=200)

    gh pr list --state merged --limit 200 --json number,headRefOid -q '.[]|"\(.number) \(.headRefOid)"' > /tmp/prs.txt
    while read -r n h; do
      gh api "repos/:owner/:repo/commits/$h/check-runs?per_page=100" \
        --jq '.check_runs[]|select(.name=="Elixir gate" or .name=="Cloud gate" or .name=="Console gate" or .name=="PR references an active task")|"\(.name)|\(.conclusion)"' 2>/dev/null &
    done < /tmp/prs.txt | sort | uniq -c

Observed: Cloud gate|success 200 · Console gate|success 198, failure 2 · Elixir gate|success 200 · PR references an active task|success 200.
Zero `skipped`. The four required names are `if: always()` AGGREGATORS, which structurally cannot skip.
=> the "does skipped satisfy protection" question has NO live in-repo instance to read.

## R3 — the D19 probe exists but does NOT prove protection satisfaction

    gh pr view 6369 --json number,mergedAt,baseRefName,headRefOid
    gh api repos/:owner/:repo/commits/e6aae4f468c7a9ebe42e3f3acf06154e7961da1f/check-runs?per_page=100 \
      --jq '.check_runs[]|"\(.name) => \(.conclusion)"'
    gh api repos/:owner/:repo/branches/hg-probe-base/protection   # 404 Branch not found

PR #6369 "PROBE: skip semantics live proof" merged into `hg-probe-base`, NOT main, and its head carries
`PR references an active task => failure` — a required-on-main context, red, merged anyway. So that base
was unprotected: the probe proves check-run CONCLUSIONS (`probe-skipped-if => skipped`,
`probe-needs-failed-default => skipped`), not that `skipped` satisfies branch protection.

## R4 — a paths-filtered workflow emits NO check run (the real deadlock mechanism)

    gh api repos/:owner/:repo/commits/f1c33790/check-runs?per_page=100 --jq '.total_count'   # 13
    gh api repos/:owner/:repo/commits/f1c33790/check-runs?per_page=100 \
      --jq '.check_runs[].name' | grep -ci console                                            # 0

Matches console-harness.yml:27-37's own recorded measurement verbatim.

## R5 — ci.yml is paths-filtered; the web names are PRESENT/ABSENT by head shape

    git show origin/main:.github/workflows/ci.yml | sed -n '15,26p'     # on: push+pull_request, paths: web/**, lighthouserc.json, ci.yml

    # web-touching head (PR #9599):
    gh api repos/:owner/:repo/commits/47d113bb1a64b97d6fdffa0546be7534b10c0aa9/check-runs?per_page=100 \
      --jq '.check_runs[]|select(.name|test("web/"))|"\(.name) => \(.conclusion)"'
    #   Lighthouse CI — web/ => success
    #   web/ typecheck + unit tests + lint => success

    # non-web heads (PR #9614, and origin/main tip 4a0405128e42fc2df6b239753a91ffe9a37c96c9):
    gh api repos/:owner/:repo/commits/b7202bea8092c23b84890733480dbb998c290251/check-runs?per_page=100 \
      --jq '.check_runs[].name' | grep -c "web/"     # 0
    gh api repos/:owner/:repo/commits/4a0405128e42fc2df6b239753a91ffe9a37c96c9/check-runs?per_page=100 \
      --jq '.check_runs[].name' | grep -c "web/"     # 0

## R6 — web-checks concludes SUCCESS, never `skipped`, when web/ is absent

    git show origin/main:.github/workflows/ci.yml | sed -n '148,167p'

Job `web-checks` has NO job-level `if:` (line 148 `web-checks:` / 149 `name:` / 150 `runs-on:` / 152 `steps:`).
The `Skip — web/ not present` step at :165-167 is UNGATED-on-failure and merely echoes, exit 0.
=> job runs, all eight real steps evaluate false, job concludes `success`. It cannot produce `skipped`.
Also: `git show origin/main:web/package.json` exists, so the present=false branch is unreachable on main today.

## R7 — required-checks.json carries no web row in EITHER list

    git show origin/main:.github/required-checks.json > /tmp/rc.json
    grep -ic '"context": "[^"]*[Ww]eb' /tmp/rc.json    # 0
    grep -c  'Lighthouse' /tmp/rc.json                 # 0
