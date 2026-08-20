# cch w70 V6 — S4 transport + scope + flat-detail constraint: re-derivation recipes (2026-08-17)

Verified at origin/main = d21641abd8 (cloud/ + internal/cloudclient byte-identical to d020382028 for every file below).

| # | Claim | Re-derive |
|---|---|---|
| 1 | Both refusal chains share the flat `\|\|` chain; `teardown_refusal/2` EXISTS (post-#11706) | `git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex \| sed -n '1905,1931p'` |
| 2 | The nested-aware extractor pair lives 220 lines up in the SAME module | `git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex \| sed -n '1658,1691p'` |
| 3 | Box refuses rollback/teardown NESTED `%{error: %{code, message}}` (409 already_running, 409 box_at_capacity, 400, 500, 503) | `grep -n 'json(%{error: %{' api/lib/barkpark_web/controllers/site_deploy_controller.ex` |
| 4 | box_relay relays pre-poll refusals VERBATIM (`other ->`) so the nested shape physically reaches both chains | `git show origin/main:cloud/lib/barkpark_cloud/sites/box_relay.ex \| sed -n '145,170p;223,240p'` |
| 5 | Committed rollback/teardown fixtures are FLAT-ONLY; nested fixtures exist for `start:` but never `rollback:`/`teardown:` | `grep -n 'rollback: {:ok\\\|teardown: {:ok' cloud/test/barkpark_cloud/sites_deploy_test.exs cloud/test/barkpark_cloud/web/router_sites_test.exs` |
| 6 | The two suites are green on origin/main (192 tests, 0 failures) | `git worktree add /tmp/wt origin/main --detach && cd /tmp/wt/cloud && CC=/usr/bin/clang MIX_ENV=test mix test test/barkpark_cloud/sites_deploy_test.exs test/barkpark_cloud/web/router_sites_test.exs` |
| 7 | `mint_failure_copy/2` (router.ex:12517) reads flat-only while its REAL refusals are nested (TokenController 422 + auth-plug 401/403) | `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| sed -n '12517,12525p'; sed -n '130,137p' api/lib/barkpark_web/controllers/token_controller.ex; grep -n 'json(%{error: Map.delete' api/lib/barkpark_web/plugs/require_workspace_role.ex` |
| 8 | The CLI site rollback/delete arms read FLAT top-level error+detail only (`cloudError`); the nested-tolerant `decodeRollbackError` serves the INSTANCE route, not sites | `git show origin/main:internal/cloudclient/client.go \| sed -n '2614,2646p'; git show origin/main:internal/cloudclient/client.go \| sed -n '/^func cloudError/,/^}/p'` |
| 9 | The CP site routes ship `{ok:false, error:"rollback_failed"\|"teardown_failed", detail}` flat | `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| grep -n 'error: "rollback_failed"\\\|error: "teardown_failed"'` |

Rulings fed to Decide: (1) nested REACHES both chains + mint; fixtures must add the nested SiteDeployController shape while keeping the flat settle_* shape (both real). (2) Reuse `refusal_detail/1`+`refusal_code/1` in-module for S4; mint chain = SIBLING ROW (extractors are `defp` in Sites.Deploy, router.ex is another module — widening S4 breaks D847's one-file-region claim). (3) Flat-detail criterion: box words must land in top-level `detail` STRING or the CLI receipt goes mute.
