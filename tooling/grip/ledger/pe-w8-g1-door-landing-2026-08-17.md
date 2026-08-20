# pe-w8 G1 door-landing — re-derivation recipes (2026-08-17)

Verifier lane g1-door-landing. Read-only survey; Decide commits this file.

## Required contexts on main (the ONLY blocking set)
    gh api repos/FRIKKern/barkpark/branches/main/protection/required_status_checks --jq .contexts
    # => ["Elixir gate","PR references an active task","Cloud gate","Console gate"]

## Door #11934 state — BLOCKED on the required Elixir gate only
    gh pr view 11934 --json mergeStateStatus,state -q '.state+" "+.mergeStateStatus'
    # => OPEN BLOCKED
    # Required rollups: Cloud gate SUCCESS, Console gate SUCCESS, PR-references-task SUCCESS,
    #   Elixir gate FAILURE  <-- the sole blocker
    # All other reds (gofmt drift ceiling "blocking", Doc budgets+anchors, Required-check spec gate,
    #   Green arm, Compose smoke, Sobelow) are NON-required => advisory, do not block merge.

## Root cause of the Elixir-gate FAILURE — deterministic doc-coverage miss (DOOR DEFECT)
    gh run view --job 95481522169 --log-failed | grep -A2 errors_doc_coverage_test.exs:51
    # 1) test every Content.Errors.known_codes/0 code is documented in §9
    # docs/api-v1.md §9 is missing 2 error code(s) that Content.Errors.known_codes/0 can emit:
    #   create_wall, slug_mismatch
    # 27 doctests, 13902 tests, 1 failure, 48 excluded  (single failure — a rerun WILL NOT clear it)

## Why: #11983 (branch head 726fb0e) registered the codes but never documented them
    git show 726fb0e62e --stat | grep -E "errors.ex|openapi|api-v1"
    # touches api/lib/barkpark/content/errors.ex (+13, registers codes) and docs/openapi.json (+2 enum)
    # does NOT touch docs/api-v1.md  <-- the gap
    git show origin/loop-epic/bp-paper-new-create-on-push-one-door-fro-2:docs/api-v1.md | grep -c create_wall   # 0
    git show origin/loop-epic/bp-paper-new-create-on-push-one-door-fro-2:docs/api-v1.md | grep -c slug_mismatch # 0
    # FIX (door-defect class, one small commit to the branch): add create_wall (422) + slug_mismatch (422)
    #   to docs/api-v1.md "## 9. Error Codes" (line 163) with HTTP status + one-line meaning, then re-run.

## Branch is 20 commits behind main (stale-base + double-bump risk)
    git merge-base 726fb0e62e origin/main                 # 94b12757a0e7...
    git rev-list --count 94b12757a0e7..origin/main         # 20
    # #11983 also "bumps PDS census baseline"; #11984/#11985/#11986 already merged into main mid-survey.
    # Rebase before merge to avoid a stale-green break on main's moved counters.

## Guerrilla serving sha — door NOT deployed
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cd /opt/barkpark && git rev-parse HEAD && cat .instance-deploy-last'
    # => 6ea916104c75...  (== origin/main HEAD)   .instance-deploy-last == 6ea916104c75...
    git merge-base --is-ancestor 8859c88a64 6ea916104c75f5b7364f355b6c94130628f4821f; echo $?  # 1 => DOOR-NOT-IN-SERVING

## D47 sentinel caveat — the fresh-slug sync grep is an UNRELIABLE landing oracle
    S=w8-lc-$(date +%s)
    curl -s -X POST ".../v1/plugins/bulldocs/papers/$S/sync" -d '{"bpml":"<paper .../>","baseRev":"1"}'
    # => {"error":{"code":"not_found","message":"no paper for slug ...","hint":"publish it first, then pull"}}
    # This is a SEMANTIC not_found (slug absent). The sync endpoint is ALREADY live on guerrilla (#11640,
    #   on main). A fresh-slug sync returns not_found REGARDLESS of whether #11934 landed, so
    #   `grep not_found => NOT-LANDED` will keep printing NOT-LANDED even AFTER the door deploys.
    # TRUSTWORTHY deploy oracle instead: ssh rev-parse HEAD, then
    #   git merge-base --is-ancestor 8859c88a64 <serving HEAD>  (rc 0 = LANDED).

## G2 key — still unprovisioned
    env | grep -i anthropic            # (empty)
    security find-generic-password -s ANTHROPIC_API_KEY   # item could not be found
