# deploy-truth wave 1 — gate reality, re-derivation recipes (2026-08-05)

Verifier: gate-reality. Every row below is a command that re-derives the fact
from scratch. Nothing here is read off YAML; everything was RUN.

IMPORTANT — the primary checkout was 434 commits behind origin/main and does not
even CONTAIN `scripts/cloud-path-escape-check.sh` or
`scripts/console-path-escape-check.sh`. Every recipe therefore reads origin/main
(`git show`) or runs inside a worktree pinned at origin/main. A builder who runs
these from the stale primary checkout gets a false answer.

## R1 — live branch protection == committed contract (all fields, not just two)

    gh api repos/:owner/:repo/branches/main/protection --jq '{strict: .required_status_checks.strict, contexts: .required_status_checks.contexts, admins: .enforce_admins.enabled, reviews: .required_pull_request_reviews, linear: .required_linear_history.enabled, force: .allow_force_pushes.enabled, deletions: .allow_deletions.enabled, conversation: .required_conversation_resolution.enabled}'

    git show origin/main:.github/required-checks.json | python3 -c "
    import json,sys
    p=json.load(sys.stdin)['protection']
    print(json.dumps({'strict':p['required_status_checks']['strict'],'contexts':sorted(c['context'] for c in p['required_status_checks']['checks']),'admins':p['enforce_admins'],'reviews':p['required_pull_request_reviews'],'linear':p['required_linear_history'],'force':p['allow_force_pushes'],'deletions':p['allow_deletions'],'conversation':p.get('required_conversation_resolution')},indent=1,sort_keys=True))"

Both sides: admins true; strict false; reviews null; linear/force/deletions/
conversation false; contexts exactly {Cloud gate, Console gate, Elixir gate,
PR references an active task}. IDENTICAL, field for field.

## R2 — which ratchet fires for which file (`--match`, NOT a bare filename)

The assignment's literal form `bash scripts/elixir-path-escape-check.sh <file>`
is NOT a supported mode — it hits the `*)` arm and exits 2 with a usage line.
The real interface takes changed paths on STDIN:

    for f in templates/search-starter/lib/graph.ts \
             templates/astro-search-starter/src/lib/bp.ts \
             deploy/site-deploy-node.sh \
             cloud/lib/barkpark_cloud/sites/deploy.ex \
             api/lib/barkpark_web/plugs/public_read.ex \
             internal/cli/cloud_site_cmd.go \
             cloud/lib/barkpark_cloud/web/router.ex; do
      printf '%-55s elixir=%s cloud=%s console=%s\n' "$f" \
        "$(echo "$f" | bash scripts/elixir-path-escape-check.sh  --match test)" \
        "$(echo "$f" | bash scripts/cloud-path-escape-check.sh   --match cloud)" \
        "$(echo "$f" | bash scripts/console-path-escape-check.sh --match console)"
    done

Result: both templates/** files and internal/cli/cloud_site_cmd.go match NOTHING.

## R3 — templates/** trips no blocking gate yet still auto-deploys

    git show origin/main:.github/workflows/deploy.yml | sed -n '1,30p'   # templates/** IS a deploy trigger
    git show origin/main:.github/workflows/pr-task-gate.yml | sed -n '/^on:/,/^jobs:/p'   # no paths filter

Live confirmation on a real merged all-skip PR (#9528, one ledger file — the
same gate topology a templates-only PR would get):

    gh api repos/:owner/:repo/commits/40035704c8928ce99913c3c61d952a049f1a332a/check-runs \
      --paginate --jq '.check_runs[] | "\(.conclusion)\t\(.name)"' | sort -u

All four required contexts `success`; every substantive job `skipped`. The only
jobs that really ran are the three path-escape ratchets (deliberately unfiltered)
— and none of them reads templates/.

## R4 — local green baselines, taken on a tree pinned at origin/main

Worktree `omwt` @ 467f7e2837b0690d45a2c8a573e7242b6d720833, `git status` clean.

    node --check cloud/priv/static/app.js
    node cloud/priv/static/__app.test.mjs        # 826 pass / 0 fail
    CC=clang go build ./...                      # rc 0
    CC=clang go vet ./internal/cli/...           # rc 0
    CC=clang go test ./internal/cli/...          # rc 0, 4 ok packages
    for s in elixir cloud console; do bash scripts/$s-path-escape-check.sh --selftest; done
                                                 # 113 + 122 + 151 = 386 assertions, 0 failed

Capture rc EXPLICITLY (`cmd > f 2>&1; echo $?`). `cmd | tail` discards the rc.

## R5 — the baselines can actually lose (mutation, not reading)

Console harness:

    perl -0pi -e 's/\bfaultCopy\b/faultCopyZZZ/g' cloud/priv/static/app.js
    node cloud/priv/static/__app.test.mjs   # rc 1, 824 pass / 2 fail
    git checkout -- cloud/priv/static/app.js

Go, control (must be caught) — delete failure_reason from siteFailure's ladder:

    reason = siteOr(failedDetail, siteFailureFallback); _ = d.FailureReason
    CC=clang go test ./internal/cli/   # rc 1 — TestRunCloudSiteDeployFailed +2 more

Go, the finding (NOT caught) — merely INVERT the ladder's priority:

    reason = siteOr(failedDetail, siteOr(strings.TrimSpace(d.FailureReason), siteFailureFallback))
    CC=clang go test ./internal/cli/   # rc 0 — every test still passes

The suite pins "failure_reason is consulted" but not "failure_reason WINS".
Cause is visible in the fixtures: cloud_site_cmd_test.go:707 sets failure_reason
with no stage detail; :982 comments "No failure_reason at the deployment level".
No fixture ever sets BOTH, so the ordering is untestable as written.

## R6 — `bp cloud site status` cannot render a failure, by construction

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '10823,10832p'
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '7305,7320p'

`put_current_deployment/3` resolves ONLY `site.current_deployment_id`, and that
pointer is written solely on `make_current=true AND status=live` (an illegal
`failed -> live` edge is a 409). So `current_deployment` is always a LIVE row.
`internal/cli/cloud_site_cmd_test.go:1144` (TestRunCloudSiteStatusShowsStageDetail)
hand-feeds `"current_deployment":{"status":"failed"}` — a payload the control
plane is structurally incapable of emitting. The failure-rendering branch is
real and tested against a shape that cannot occur.
