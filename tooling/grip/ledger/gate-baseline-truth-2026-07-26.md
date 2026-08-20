# Gate baseline on clean origin/main — 2026-07-26 (W10 verifier: gate-baseline-truth)

Baseline commit: `45c3bcc81` (`origin/main` == local `HEAD`, 0 ahead / 0 behind).

**Tree caveat at run time:** `api/lib/barkpark/search/documents_retriever.ex` carried an
uncommitted +34-line PROTOTYPE from the concurrent visibility-leak-fix-seam verifier, and it
WAS compiled into `_build/test` (`strings … .beam | grep -c scope_to_public_types` → 3).
The local api numbers below are therefore "green WITH the prototype". The clean-main
authority for the same six files is main's own `elixir` CI job on `45c3bcc81`
(job `Test (Elixir 1.18.1 / OTP 27.0)`, conclusion `success`), which runs an unfiltered
`mix test` (`.github/workflows/elixir.yml:243`).

| Gate | Result | Re-derivation command |
|---|---|---|
| api six suites (53 tests) | PASS 53/0 | `cd api && CC=clang mix test test/barkpark_web/anon_perspective_test.exs test/barkpark_web/contract/search_anon_perspective_test.exs test/barkpark_web/integration/public_read_enforcement_test.exs test/barkpark_web/sibling_controller_leak_test.exs test/barkpark_web/channels/search_channel_test.exs test/barkpark_web/controllers/graph_controller_test.exs` |
| anon_perspective_test | PASS 6/0 | `cd api && CC=clang mix test test/barkpark_web/anon_perspective_test.exs` |
| contract/search_anon_perspective_test | PASS 7/0 | `cd api && CC=clang mix test test/barkpark_web/contract/search_anon_perspective_test.exs` |
| integration/public_read_enforcement_test | PASS 10/0 | `cd api && CC=clang mix test test/barkpark_web/integration/public_read_enforcement_test.exs` |
| sibling_controller_leak_test | PASS 8/0 | `cd api && CC=clang mix test test/barkpark_web/sibling_controller_leak_test.exs` |
| channels/search_channel_test | PASS 11/0 | `cd api && CC=clang mix test test/barkpark_web/channels/search_channel_test.exs` |
| controllers/graph_controller_test | PASS 11/0 | `cd api && CC=clang mix test test/barkpark_web/controllers/graph_controller_test.exs` |
| cloud router_sites + freshness (61 tests) | PASS 61/0 | `cd cloud && CC=clang mix test test/barkpark_cloud/web/router_sites_test.exs test/barkpark_cloud/sites/template_freshness_worker_test.exs` |
| go build | PASS exit=0 | `CC=clang go build ./...` |
| go vet internal/cli | PASS exit=0 | `CC=clang go vet ./internal/cli/...` |
| go test internal/cli (4 pkgs) | PASS all `ok` | `CC=clang go test ./internal/cli/...` |
| node --check app.js | PASS | `node --check cloud/priv/static/app.js` |
| console harness (698 tests) | PASS 698/0 | `node cloud/priv/static/__app.test.mjs` |
| astro-finder-drift selftest | PASS (mutation-proven) | `bash scripts/check-astro-finder-drift.sh --selftest` |
| astro-finder-drift | PASS exit=0 | `bash scripts/check-astro-finder-drift.sh` |
| check-deployyml-filters | PASS exit=0, 7 paths + 1 exempt | `bash scripts/check-deployyml-filters.sh` |
| live strict journey smoke (search-ember) | PASS 5/5, 24.5s, WS reply count=552 | `node tooling/search-smoke/journey-smoke.mjs --url https://guerrilla.barkpark.cloud/sites/search-ember/ --strict` |

**Main's own CI on `45c3bcc81`:** all workflows green — `elixir`, `doc-gates`, `go-tests`,
`astro-finder-drift`, `astro-search-finder-test`, `search-starter-smoke`, `Deploy (production)`,
`security`. No main-gate jam. The two `cancelled` rows at 14:14:07Z are concurrency
supersession by the 14:16:08Z push, not failures — the same workflows are `success` there.
`gh run list --branch main --limit 25`

**Sobelow is NOT a blocker this wave:** `security.yml:55` sets `continue-on-error: true` on the
sobelow job (stale-baseline class, documented). `mix-audit` in the same workflow IS blocking
(`security.yml:121`). Security fires on `api/**`, so every clamp-slice PR will run it.
`grep -n continue-on-error .github/workflows/security.yml`
