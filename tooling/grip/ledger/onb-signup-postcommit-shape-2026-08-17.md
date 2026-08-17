# onb signup post-commit half-state — re-derivation recipe (2026-08-17)

Verifier: signup-postcommit-shape. All against origin/main (a6535504204d worktree, cloud tree matches origin for these paths).

## Client error surface — raw transport error, no idempotency
    sed -n '284,327p' internal/cloudclient/client.go   # do/doWithHeaders: dropped resp -> (0,nil,err)
    sed -n '413,430p' internal/cloudclient/client.go   # Register: returns err RAW (not via cloudError) on transport err
    grep -ni idempoten internal/cloudclient/client.go  # -> zero hits: no Idempotency-Key seam

## Server register path — one atomic tx, NO replay seam
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '1065,1097p'   # register route
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '9342,9376p'   # defp register/4: single Repo.transaction
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -ni idempoten     # only OTHER routes; register has none

## Endpoint error plug — EXISTS today (premise stale)
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '253p'          # use Plug.ErrorHandler
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '8800,8817p'    # handle_errors/2 -> JSON {error: crash_slug, request_id}
    git log origin/main --oneline -S "def handle_errors" -- cloud/lib/barkpark_cloud/web/router.ex  # 467f7e2837 (#9521), AFTER July
    git log origin/main --oneline | grep 3783                                             # e5ef99525a merged

## Envelope regression suite — PASSES, DB provisioned locally
    cd cloud && mix test test/web/auth_onboarding_error_test.exs   # 8 tests, 0 failures, 3.5s
