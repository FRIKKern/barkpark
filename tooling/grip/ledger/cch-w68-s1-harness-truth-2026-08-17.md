# cch-w68 S1 harness truth — re-derivation recipes

Baseline: `origin/main` = `4b5d802a1d5a31030f79fa4eb8d4761eb4995db2` (2026-08-17).
All four facts re-derive from `git show origin/main:` plus a local `cloud` test run.

## 1 — router_sites_test.exs is `async: true` (DDL is NOT safe there)

    git show origin/main:cloud/test/barkpark_cloud/web/router_sites_test.exs | sed -n '18p'
    # => use BarkparkCloud.DataCase, async: true

Both in-repo DDL precedents are `async: false`:

    git show origin/main:cloud/test/barkpark_cloud/registry/content_publish_test.exs | grep -n 'use BarkparkCloud'   # line 25, async: false
    git show origin/main:cloud/test/web/crash_envelope_census_test.exs | grep -n 'use BarkparkCloud'                 # line 42, async: false
    git show origin/main:cloud/test/support/data_case.ex | grep -n 'start_owner!'                                    # shared: not tags[:async]

Consequence: an `ALTER TABLE site_artifacts ... ON DELETE RESTRICT` inside
router_sites_test.exs runs in a NON-shared sandbox owner while 19 other async
cases hold their own connections; `ACCESS EXCLUSIVE` on a hot table serialises
or deadlocks them. Flipping the 2973-line file to `async: false` is the price.

## 2 — a raised Ecto.ConstraintError CANNOT be read as `conn.status == 500`

    grep -n -A25 'def __catch__' cloud/deps/plug/lib/plug/error_handler.ex
    # line 116: :erlang.raise(kind, reason, stack)   <- ALWAYS re-raises after handle_errors/2

    cd cloud && MIX_ENV=test mix run -e 'IO.inspect Plug.Exception.status(%Ecto.ConstraintError{type: :foreign_key, constraint: "x", message: "x"})'
    # => 500        (phoenix_ecto is NOT a dep: mix.lock grep -c phoenix_ecto => 0)

So the envelope really is `500 {"error":"server_error"}` (router.ex:8744 →
`crash_slug(_reason, status) when status >= 500`), but `Router.call/2` raises.
The ONLY honest harness shape is the crash-envelope idiom:

    git show origin/main:cloud/test/web/crash_envelope_census_test.exs | sed -n '90,110p'
    # register_before_send/2 forwards {:crash_response, status, headers, body}
    # to the test pid; try/rescue receives it. NO callback = the zero-byte class.

`router_sites_test.exs` contains ZERO `assert_raise`, `rescue`, `try do`, or
`register_before_send` today:

    git show origin/main:cloud/test/barkpark_cloud/web/router_sites_test.exs | grep -c 'assert_raise\|register_before_send\|try do'   # => 0

## 3 — no 502/504 assertion anywhere inside the DELETE describe

    git show origin/main:cloud/test/barkpark_cloud/web/router_sites_test.exs | grep -n '502\|504'
    # 858, 863   -> describe at 792 (W10 typed box refusal, deploy start)
    # 1188, 1212 -> describe at 1097 (POST /v1/sites mint refusal)
    # 2326       -> COMMENT, describe at 2300 (credential refusal)
    # DELETE describe spans 2116..2299 -> zero hits. 504 appears ZERO times in the file.

## 4 — the router's cited guard EXISTS and PASSES

    git show origin/main:cloud/test/barkpark_cloud/site_cascade_census_test.exs | grep -n 'NOT NULL and ON DELETE CASCADE'
    # 202: test "sites.barkpark_id is NOT NULL and ON DELETE CASCADE (... D811)"

    cd cloud && MIX_ENV=test mix test test/barkpark_cloud/site_cascade_census_test.exs
    # 6 tests, 0 failures — census prints 3 FKs, all confdeltype=c

## BONUS — the brief's 502 mechanism is WRONG by one hop

    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '1813,1837p'
    # {:ok, 502, body} -> {:error, 422, ...}   (a relay 5xx becomes 422!)
    # {:error, reason} -> {:error, 502, unreachable(bp, reason)}

Route 502 is driven by `FakeBoxRelay.program(teardown: {:error, :econnrefused})`,
NOT by `{:ok, 502, ...}`. The fake returns the programmed term verbatim:

    git show origin/main:cloud/test/support/sites_fake_box_relay.ex | sed -n '157,162p'

The 30s budget is unreachable from route tests — it lives in `BoxRelay.HTTP`
(module opens at box_relay.ex:101, `@teardown_budget_ms 30_000` at :142), which
the test env replaces via `:site_box_relay`. Only its 504 RELAY COPY is
route-testable, and via `{:ok, 504, ...}` it lands as **422**, not 504.
