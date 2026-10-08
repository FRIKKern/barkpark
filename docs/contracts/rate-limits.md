<!-- doc-tier: agent | canonical-for: rate-limit-budgets | budget: 900tok -->
# Rate-limit budgets and principal classes

`BarkparkWeb.Plugs.RateLimit` meters every `/v1/*` write/read pair against one
process-global token bucket per key (`Barkpark.RateLimiter`). It runs BEFORE
the pipeline's own credential plug (cheapest-first), so it resolves a
principal itself rather than reading `conn.assigns`. Full mechanics and the
cost rationale live in the module's own `@moduledoc`; this card owns the
budget numbers and WHO gets which one.

## Principal classes

| Class | How it resolves | Default write budget | Default read budget |
|---|---|---|---|
| `:verified` | `Authorization: Bearer <raw>` → `@principal_resolvers` (`api_token` via `Auth.verify_token_id/1`, SCIM via `Scim.resolve_token_id/1`) | `:write_per_minute` (60) | `:read_per_minute` (300) |
| `:session` | a session cookie, no Bearer present: `session["api_token"]` (token-sign-in) → `Auth.verify_token_id/1`, else `session["user_session"]` (account/SSO login) → `Accounts.verify_user_session/1` | `:session_write_per_minute` (180) | `:read_per_minute` (300) |
| `:anonymous` | no resolvable credential at all | `client_ip/1`-keyed, `:write_per_minute` (60) | `:read_per_minute` (300) |

A Bearer wins over a session cookie on the same request, same precedence
`OptionalSessionToken` documents — a caller carrying both is billed as
`:verified`, never `:session`. A per-dataset override
(`config :barkpark, :rate_limits, datasets: %{"ds" => %{write: N}}`) wins over
every class default, `:session` included: an operator clamping one dataset's
abuse ceiling means it regardless of who is asking.

## Why `:session` is wider (task-2c31de0cf6597d32)

Barkpark Studio proxies many human editors through one server-side
credential and/or one egress IP. Before this class existed, N concurrent
editors shared ONE 60/min write bucket — one person typing for ~15s could
429 everyone else. `:session` keys each editor's OWN resolved credential
(token-sign-in cookie or account login) into its own bucket, so N editors get
N independent 180/min budgets instead of one shared 60/min bucket. The
`:verified` and `:anonymous` defaults are untouched by this — raising
`:session_write_per_minute` can never widen the budget abuse-prevention
traffic (a bare API token, an unauthenticated caller) is held to.

## Tuning

All three knobs live in `config :barkpark, :rate_limits`
(`BARKPARK_RATE_LIMIT_*` in `runtime.exs`): `read_per_minute`,
`write_per_minute`, `session_write_per_minute`. Changing one never changes the
full-refill window (always 60s for this plug — capacity and refill scale
together), so `Barkpark.RateLimiter`'s `@stale_after_ms` invariant holds
without re-deriving it.

## Adding a new credential kind

`rate_limit_principal_coverage_test.exs` is the tripwire: it walks
`router.ex`, finds every pipeline mounting `RateLimit`, and refuses any
credential plug not accounted for in its `@accounted` map. A new Bearer kind
needs a resolver in `@principal_resolvers`; a new session-cookie kind needs a
branch in `RateLimit.session_principal_id/1` (same file) — either way, add the
row to `@accounted` with which bucket it keys, or that test reds at the mount
site instead of silently metering the new kind as anonymous (the SCIM
incident this test exists to prevent, see its own moduledoc).
