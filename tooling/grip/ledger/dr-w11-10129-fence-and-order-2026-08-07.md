# dr-w11 verifier — 10129 fence, merge order, 10014 cloud gate (2026-08-07)

Re-derivation recipes. Every line below is a command that reproduces a fact in the
wave-11 verify report. `origin/main` at derivation time = `b4ef025cf`.

## A. #10129 state and its REAL conflict set (router.ex is NOT in it)

    gh pr view 10129 --json mergeable,mergeStateStatus,headRefOid
    # -> CONFLICTING / DIRTY / 514ff5c6f664a7b1af6dfc7342eafafc0700d8a6

    git fetch origin main -q
    git merge-tree --write-tree origin/main 514ff5c6f664a7b1af6dfc7342eafafc0700d8a6 \
      | grep -E 'CONFLICT|Auto-merging'
    # -> "Auto-merging cloud/lib/barkpark_cloud/web/router.ex"  (NO CONFLICT line)
    # -> CONFLICT x6: cloud/priv/static/__fixtures__/attention_order.json,
    #    internal/cli/cloud_status_cmd.go, internal/cli/cloud_status_cmd_test.go,
    #    internal/cli/testdata/attention_order_cases.json,
    #    internal/cloudclient/client.go, internal/semrole/semrole.go

    # The router.ex delta itself, for the fence ruling:
    git diff $(git merge-base origin/main 514ff5c6f) 514ff5c6f \
      -- cloud/lib/barkpark_cloud/web/router.ex | grep -E '^@@'
    # -> @@ -1891 (fleet-list JSON prefetch), @@ -8755 and @@ -8828 (private barkpark_json/5)

## B. Where the console-hardening auth region actually is

    grep -n 'router.ex:1460' .claude/workflows/bp-cloud-console-hardening-charter.md
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '1450,1465p'
    # -> wave 42's ONLY router.ex claim is line 1460, the /v1/me `team_authority` comment.
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \
      | grep -nE '^\s*(get|post|delete) "/v1/(auth|tokens|account/sessions)'
    # -> auth/session routes span 736-1758 and 5119-5197. 10129 touches none of them.

## C. Attribution: the conflicts are #9887's merge, and they are SEMANTIC

    gh pr view 9887 --json mergedAt,files
    # -> merged 2026-08-07T06:13:52Z; its 7 files are a strict superset of 10129's 6 conflicts.

    c=$(git log origin/main --format='%H %s' -30 | grep '#9887' | cut -d' ' -f1)
    git diff $c^ $c -- internal/cloudclient/client.go | grep -E '^@@'
    # -> @@ -154,6 +154,51 @@ type Barkpark struct  — the SAME insertion point 10129 uses.

    git show origin/main:internal/cli/cloud_status_cmd.go | sed -n '245,262p'
    git show 514ff5c6f:internal/cli/cloud_status_cmd.go | sed -n '/^var attention/,/^}/p'
    # -> main = 11 rungs (…degraded 4, strained 5, filling 6, unreported 7, behind 8…)
    #    10129 = 10 rungs (…degraded 4, deploys_failing 5, behind 6 … unmetered 9, ok 10)
    #    A rebase must MINT a 13-rung ladder and re-place two rungs. Charter decision.

## D. #10086 vs #10129 — no genuine content collision

    git merge-tree --write-tree origin/main 95a9200fd | grep CONFLICT   # 10086 alone: client.go
    git merge-tree --write-tree 514ff5c6f 95a9200fd | grep CONFLICT     # pair: client.go
    git diff $(git merge-base origin/main 95a9200fd) 95a9200fd \
      -- internal/cloudclient/client.go | grep -E '^@@'
    # -> 10086 hunks at old lines 26, 249, 275, 291, 2565, 2609, 2621 — all DISJOINT from 154.
    # The pairwise CONFLICT is an artifact of the stale shared base (both predate 9887).

## E. #10014's Cloud gate — one cause, not two

    gh api repos/:owner/:repo/actions/jobs/92786858340/logs | grep -E 'R_[A-Z]+:'
    # -> R_CHANGES success, R_COMPILE success, R_TEST success, R_ESCAPE failure

    gh api repos/:owner/:repo/actions/jobs/92786582581/logs | tail -5
    # -> "120 passed, 2 failed"; both failures are case 1 assertions, one root cause:
    #    "##[error]cloud-path-escape-check: UNCOVERED repo-root read: deploy/site-deploy-node.sh"

    git show origin/main:scripts/cloud-path-escape-check.sh | sed -n '98,110p'
    # -> declares deploy/site-deploy.sh (line 107); site-deploy-node.sh absent.
    git grep -n 'site-deploy-node' <10014-head> -- cloud/test
    # -> deploy_ledger_test.exs:485  Path.expand("../../../deploy/site-deploy-node.sh", __DIR__)
