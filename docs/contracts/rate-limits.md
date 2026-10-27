<!-- doc-tier: agent | canonical-for: rate-limit-budgets | budget: 900tok -->
# Rate-limit budgets and principal classes

`BarkparkWeb.Plugs.RateLimit` meters every `/v1/*` read/write against one
token bucket per key (`Barkpark.RateLimiter`). It runs BEFORE the credential
plug, so it resolves a principal itself. Mechanics live in its `@moduledoc`;
this card owns the budget numbers and WHO gets which one.

## Principal classes

| Class | How it resolves | Default write budget | Default read budget |
|---|---|---|---|
| `:verified` | `Authorization: Bearer <raw>` → `@principal_resolvers` (`api_token` via `Auth.verify_token_principal/1`, SCIM via `Scim.resolve_token_id/1`), `owner_user_id` nil | `:write_per_minute` (60) | `:read_per_minute` (300) |
| `:owned` | same Bearer resolution, but `owner_user_id` set — a personal PAT, or an app token from `POST /v1/auth/app-tokens` (always owner-set, one per editor email) | `:session_write_per_minute` (180) | `:read_per_minute` (300) |
| `:session` | a login-session Bearer (`/v1/auth/login`'s token; Studio account sign-in), or a session cookie with no Bearer: `session["api_token"]` → `Auth.verify_token_id/1`, else `session["user_session"]` → `Accounts.verify_user_session/1`. Bearer and cookie of one login share one bucket | `:session_write_per_minute` (180) | `:read_per_minute` (300) |
| `:anonymous` | no resolvable credential at all | `client_ip/1`-keyed, `:write_per_minute` (60) | `:read_per_minute` (300) |

A Bearer wins over a session cookie on the same request, same precedence
`OptionalSessionToken` documents — a caller carrying both is billed as
`:verified`, never `:session`. A per-dataset override
(`config :barkpark, :rate_limits, datasets: %{"ds" => %{write: N}}`) wins over
every class default, `:session` included: an operator clamping one dataset's
abuse ceiling means it regardless of who is asking.

## Why `:session` and `:owned` are wider (task-2c31de0cf6597d32)

Studio proxies many editors through one server and IP; one 60/min bucket let
one typist 429 everyone. Each editor's login or owned token gets its own.

## A 429, and a background writer

A 429's `details.budget` names the spent bucket (`class`, `per_minute`,
`scope`, `principal`) and `details.resets_at`. Buckets are per token × class
× dataset: a background writer with its own token never spends an editor's.

## Tuning

All three knobs live in `config :barkpark, :rate_limits`
(`BARKPARK_RATE_LIMIT_*` in `runtime.exs`): `read_per_minute`,
`write_per_minute`, `session_write_per_minute`. One token (say a site
build prerendering in parallel) gets its own budget with
`tokens: %{"<api_token id>" => %{read: N}}` or
`BARKPARK_RATE_LIMIT_TOKENS="<id>:read=3000:write=120"`; it wins over class
and dataset budgets. Changing one never changes the
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
