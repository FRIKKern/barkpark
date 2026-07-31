# Recipe — claim-contract & born-failed-webhook test blast radius (2026-07-31)

Baseline: `origin/main` e34031104, worktree `main` c8856720573630a97fe5927f8b41cc04e01cc943.
All commands from `/Users/frikkjarl/Documents/GitHub/barkpark/cloud` unless noted.

## Green baselines (re-derive before touching anything)

```
CC=clang mix test test/barkpark_cloud/web/router_builder_test.exs
# => Result: 27 passed   (7.7s)

CC=clang mix test test/barkpark_cloud/web/router_github_webhook_test.exs \
  test/barkpark_cloud/failure_copy_test.exs \
  test/barkpark_cloud/web/router_github_connect_test.exs
# => Result: 86 passed   (96.6s)
```

## The gate is NOT DB-free

```
grep -n 'use BarkparkCloud.DataCase' test/barkpark_cloud/web/router_builder_test.exs \
  test/barkpark_cloud/web/router_github_webhook_test.exs
cat test/test_helper.exs                 # Ecto.Adapters.SQL.Sandbox.mode(..., :manual)
sed -n '13,20p' config/test.exs          # postgres@localhost/barkpark_cloud_test, Sandbox pool
psql -lqt | cut -d'|' -f1 | grep barkpark_cloud
```
config/test.exs hardcodes the connection and ignores `DATABASE_URL` — proved by
`DATABASE_URL="postgres://nope:nope@127.0.0.1:5999/nope" CC=clang mix test test/barkpark_cloud/web/router_builder_test.exs`
still returning `27 passed`.

## Claim-envelope tolerance (a new `source` key)

```
grep -n '== %{\|=== %{\|assert body ==\|Map.keys' test/barkpark_cloud/web/router_builder_test.exs   # => no matches
sed -n '6858,6885p' lib/barkpark_cloud/web/router.ex     # the 200 envelope
sed -n '224,235p' ../internal/builder/builder.go         # tolerant anonymous decode struct
grep -rn 'DisallowUnknownFields' ../internal/builder/    # => no matches
grep -c 'deployment_json(' lib/barkpark_cloud/web/router.ex   # => 17 shared call sites
```

## Flip blast radius (status failed→queued, reason→nil)

```
grep -rn "github_push_build_reason\|github_build_available\|can't be built yet\|github push builds" lib/ test/ priv/static/
sed -n '270,300p;478,508p' test/barkpark_cloud/web/router_github_webhook_test.exs
sed -n '345,357p' test/barkpark_cloud/web/router_github_connect_test.exs
grep -n 'defp handle_preview_push' lib/barkpark_cloud/web/router.ex   # 11666 — never consults the predicate
```
