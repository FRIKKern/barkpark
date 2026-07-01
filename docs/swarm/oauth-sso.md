# oauth-sso — Consumer OAuth / SSO login ("Continue with GitHub / Google")

**Candidate** for Barkpark Cloud. Slug: `oauth-sso`. Target app: `cloud/`
(`BarkparkCloud`). Judge before merge.

## What

Social sign-in for the Cloud account itself — a "Continue with GitHub" /
"Continue with Google" button on the existing auth screen that lands the same
`{token, team_id}` session a password login produces. New users get an account
+ personal team + owner membership on first sight; returning users converge onto
their existing account.

The load-bearing decision: identities are linked on a real `external_identities`
table keyed on the composite-unique `(provider, provider_uid) → user_id` — the
IdP's **stable subject id**, never email. `email` is stored display/audit-only.

## Why this shape

- **No new OAuth dependency.** The repo has a deliberate no-new-HTTP-dep ethos
  (`Billing.HttpClient` reaches Stripe over OTP's bundled `:httpc` with verified
  TLS; all crypto is hand-rolled). Instead of Assent/Ueberauth I hand-rolled a
  tiny authorization-code client against the *exact* `Billing.Gateway` template:
  a `Provider` behaviour + `Github`/`Google` strategies + an injectable
  `http_client` (real = the verified-TLS `:httpc` transport billing already uses;
  test = a stub). Assent is flagged as the right call only when per-team
  enterprise OIDC/SAML lands (PKCE, nonce, JWKS) — overkill for two fixed
  consumer providers, and it breaks the house style.
- **Cookieless seams.** `cloud/` is a token-bearer JSON API + vanilla SPA with no
  session cookie. So (a) CSRF `state` is a stateless **HMAC-signed** token
  (mirroring the Stripe-webhook constant-time-compare idiom), and (b) the session
  token handoff rides the URL **fragment** (`/#oauth=<token>&team=<id>`, never the
  query — a fragment stays out of access logs / `Referer`), which `app.js`'s
  bootstrap reads into the existing `setSession`.

## The Coolify footgun this avoids

Coolify links OAuth identities by **email**:

```php
// coolify: app/Http/Controllers/OauthController.php
$email = strtolower(trim((string) $oauthUser->email));
$user  = User::whereEmail($email)->first();   // ← any provider asserting this
if (! $user) { $user = User::create([...]); } //   email lands on this account
Auth::login($user);
```

Any IdP that lets a user set an arbitrary email (and many do, pre-verification)
can therefore take over an existing account. Barkpark keys on the IdP's stable
subject id instead, and only ever *converges* on an email the IdP marked
**verified** — it never *forks* and never trusts an unverified address.

### Coolify source anchors (reference, read-only)

- `app/Http/Controllers/OauthController.php` — the email-only link (the footgun).
- `app/Models/OauthSetting.php` — provider model + `couldBeEnabled` completeness
  gate (our `OAuth.enabled_providers/0` analog).
- `bootstrap/helpers/socialite.php:10-12` — `redirect_uri` auto-backfill (we
  *derive* it from `base_url`, never store it).
- `resources/views/auth/login.blade.php` — the provider buttons.
- `database/migrations/2024_03_11_150013_create_oauth_settings.php`.

## Barkpark files

### Added
- `cloud/lib/barkpark_cloud/accounts/external_identity.ex` — the join schema
  (`(provider, provider_uid)` composite-unique; `email` display-only).
- `cloud/priv/repo/migrations/20260629120000_create_external_identities.exs` —
  table + `user_id` FK (`on_delete: :delete_all`) + the composite unique index.
- `cloud/lib/barkpark_cloud/oauth.ex` — the context: `enabled_providers/0`,
  `authorize_url/1`, `verify_state/2`, `fetch_identity/2`, signed-state mint/verify.
- `cloud/lib/barkpark_cloud/oauth/provider.ex` — the strategy `@behaviour`.
- `cloud/lib/barkpark_cloud/oauth/github.ex`, `.../google.ex` — the two strategies.
- `cloud/test/support/oauth_stub.ex` — canned IdP transport (€0, hermetic).
- `cloud/test/barkpark_cloud/oauth_test.exs` — context + signed-state + linking.
- `cloud/test/barkpark_cloud/web/router_oauth_test.exs` — route-level tests.

### Changed
- `cloud/lib/barkpark_cloud/accounts.ex` — `register_with_team/2` (reusable
  signup primitive), `get_or_create_user_from_oauth/1` (safe linking precedence),
  `link_external_identity/2`, `get_user_by_external_identity/2`.
- `cloud/lib/barkpark_cloud/accounts/user.ex` — `has_many :external_identities`;
  the moduledoc "no OAuth" note replaced with the now-true description.
- `cloud/lib/barkpark_cloud/web/router.ex` — three unauthenticated routes
  (`GET /v1/auth/oauth/providers`, `/:provider`, `/:provider/callback`) + a
  `redirect_to/2` helper.
- `cloud/config/{config,runtime,test}.exs` — OAuth config (env-fed creds in prod,
  disabled-by-default in dev, fixed secret + stub client in test).
- `cloud/priv/static/{app.js,index.html,app.css}` — the fragment handoff + the
  "Continue with …" buttons (rendered from `GET /v1/auth/oauth/providers`).

## Data model

```
external_identities
  id           uuid  PK
  user_id      uuid  FK users(id) ON DELETE CASCADE, NOT NULL
  provider     text  NOT NULL          -- "github" | "google"
  provider_uid text  NOT NULL          -- GitHub numeric id / Google OIDC sub
  email        text                    -- display/audit ONLY, nullable
  inserted_at, updated_at
  UNIQUE (provider, provider_uid)       -- one IdP identity → at most one user
  INDEX (user_id)
```

Linking precedence in `get_or_create_user_from_oauth/1`:
1. `(provider, provider_uid)` match → that exact user (the durable key).
2. else a **verified**-email match to an existing user → LINK (converge, never
   fork) — the anti-Coolify behaviour.
3. else birth user → team → owner membership + the identity, in ONE transaction.

## How to test

Deps are not provisioned in the worktree, so a full `mix compile` / `mix test`
can't run here (bcrypt's NIF won't build in the sandbox). With a normal
checkout + `mix deps.get` + a Postgres test DB:

```bash
cd cloud
mix ecto.migrate            # creates external_identities (test DB)
mix test test/barkpark_cloud/oauth_test.exs \
         test/barkpark_cloud/web/router_oauth_test.exs
```

Every file was parse-validated with `Code.string_to_quoted/1`. The token-exchange
and userinfo legs run through `BarkparkCloud.OAuthStub` — zero network calls.

To exercise it live, set in the environment:
`GITHUB_OAUTH_CLIENT_ID/SECRET`, `GOOGLE_OAUTH_CLIENT_ID/SECRET`,
`OAUTH_STATE_SECRET`, `OAUTH_BASE_URL`, and register
`<base>/v1/auth/oauth/<provider>/callback` as each provider app's redirect URI.

## Honest caveats

- **Login-CSRF.** The signed `state` blocks forged provider responses (an
  attacker can't mint a valid HMAC) but, without a browser-bound cookie, not
  classic login-CSRF where a victim completes an attacker-initiated flow. Low
  risk for a sign-IN (the session lands in whoever's browser finished). A
  cookie-bound state is required before a `link-to-authed-account` action ships;
  v1 only signs in.
- **Email convergence vs. unverified local emails.** Step 2 converges on an
  IdP-**verified** email. Barkpark has no local email-verification step yet, so a
  password account's email is itself unverified — an attacker controlling an IdP
  account with a verified email matching a victim's *unverified* local email
  could link in. Still strictly safer than Coolify (we never fork, the durable
  key is the uid, and we drop unverified IdP emails to nil), but it is a real
  residual to close once email verification lands.
- **`register_with_team/2` vs the router's `register/3`.** The design proposed
  *lifting* the router's signup transaction into the context. To avoid regressing
  the router's well-tested edge cases (reserved-slug + control-char validation),
  this candidate adds `register_with_team/2` as the OAuth path's birth chain and
  leaves the router's `register/3` intact; folding the router onto the primitive
  is a clean follow-up, not done here.
- **Nested transaction on the birth path.** `get_or_create_user_from_oauth/1`
  wraps `register_with_team/2` (itself transactional) in its outer transaction so
  the user/team/membership/identity commit atomically. The happy path is clean; a
  rare birth failure rolls everything back (correct), though the error-return
  plumbing through the nested rollback is worth a reviewer's eye.
- **No unlink UI, no email-verification gate on the OAuth email, no callback
  rate-limiter** (a fronting-proxy concern, as the existing `/v1/auth/register`
  already notes). Out of scope, as stated.
- **Out of scope (stated):** per-team enterprise SSO (SAML/OIDC), token
  storage/refresh/profile sync, any admin provider-config UI.
