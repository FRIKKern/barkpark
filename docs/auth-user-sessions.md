<!-- doc-tier: agent | canonical-for: core-auth-model | budget: 4000tok -->
# User accounts, sessions, MFA, encryption & visibility

The **core-auth model**: first-class user accounts (distinct from `api_tokens`),
login sessions, multi-factor auth, field encryption-at-rest, per-field
visibility redaction, and row ownership. Additive and opt-in — with no
encrypted/private/owner-scoped fields declared, read/write behaviour is
byte-identical to a tokens-only Barkpark. API-token auth, roles, and tenancy
remain owned by [docs/auth.md](auth.md) (`canonical-for auth-tokens-roles`).

## User accounts

`Barkpark.Accounts` owns users. `register_user/1` hashes the password with
**argon2** (`Argon2.hash_pwd_salt`, NIF) and never stores the plaintext —
`hashed_password` starts `$argon2`. `get_user_by_email_and_password/2` verifies
in constant time (a dummy hash check for unknown emails defeats timing oracles).
Emails are lower-cased on write; duplicates are rejected by a unique constraint.

Email confirmation and password reset run through single-use, context-bound
tokens (`build_email_token/2` with context `"confirm"` / `"reset"`): a confirm
token cannot drive a reset, and consuming a token invalidates it. A consumed
reset also revokes every live session of that user, and the JSON door reports
the count: `POST /v1/auth/reset` answers `{ok: true, sessionsRevoked: n}`
(`AuthController`, PDS-D503) — a receipt, not a promise; `n` is what the revoke
actually stamped.

## Sessions

`Barkpark.Accounts.UserSession` is the login bearer, separate from API tokens.

- **Hash-at-rest.** Only `token_hash` (SHA-256, lowercase hex) is stored; the
  plaintext is returned once at mint and is unrecoverable.
- **Absolute expiry.** `expires_at` bounds lifetime (default 30 days,
  `default_validity_days/0`). `verify_user_session_token/1` enforces
  `is_nil(expires_at) or expires_at > now` — the only expiry check on the read
  path.
- **Liveness.** `last_used_at` is refreshed on every successful verify.
- **Kill switch.** `revoked_at` is set by `revoke_user_session_token/1`
  (single logout) and `revoke_all_user_sessions/1` (sign-out-everywhere).

### Expiry predicates (pure, opt-in)

`UserSession` exposes pure predicates for a future hardened verify path:

| Function | Meaning |
|---|---|
| `expired?(session, now \\ utc_now)` | absolute `expires_at` has passed (`nil` ⇒ never) |
| `idle_expired?(session, now)` | idle past `idle_timeout_seconds/0` measured from `last_used_at` |
| `active?(session, now)` | not revoked AND not expired AND not idle-expired |
| `idle_timeout_seconds/0` | idle window in seconds, or `nil` when disabled |

**Idle-logout is intentionally NOT wired in.** `idle_timeout_seconds/0` ships
`nil` (disabled), so `idle_expired?/2` is always `false` today and
`verify_user_session_token/1` is untouched. Wiring idle-logout into the verify
path would evict currently-valid sessions — a behaviour regression. The
predicates exist so enforcement is a one-line, reviewed change later, not a
silent flip.

### Login rate-limit

Brute-force defense lives in the router, not the controller. The `:user_auth`
pipeline (`api/lib/barkpark_web/router.ex`) runs `BarkparkWeb.Plugs.RateLimit`
keyed on the client **IP** before any `/v1/auth/*` handler — anonymous by
design, since login is pre-auth. No per-account counter; the IP key is the
chokepoint.

## MFA (TOTP)

TOTP enrolment is a two-step confirm: `mfa_enroll` returns a secret, `mfa_verify`
confirms it with a current six-digit code before MFA is armed. The secret is
**encrypted at rest** via the field-encryption envelope (below), never stored in
the clear. Enrolment also issues one-time **recovery codes** — single-use
fallbacks accepted by `auth.login`'s `recovery_code` when the authenticator is
unavailable; each code is consumed on use. `mfa_disable` (SDK `client.auth.disableMfa(password)`)
turns MFA back off — it requires the account password and clears the secret + recovery codes.

### Studio sign-in rides these accounts

`GET /login` signs into Studio with email+password (+ TOTP/recovery second
step) via `POST /login/account` + `/login/mfa`, minting the same
`user_session` the API issues; SSO browser callbacks (OIDC/SAML) redirect
HTML callers into `/studio` on their fresh cookie (API callers keep JSON).
A user is a first-class Studio principal: workspace access flows from
user-type memberships through `Tenancy.Auth.authorize/3`, and the flat
admin surfaces accept a Default-workspace owner/admin. API-token paste and
login tickets remain as the machine paths. **Production Studio requires a
sign-in**: the anonymous Default-workspace demo posture is gated by
`config :barkpark, :public_demo_studio` (dev/test true; prod opt-in via
`BARKPARK_PUBLIC_DEMO_STUDIO=1`) — flag-off anonymous browsers redirect to
`/login`; published papers stay world-readable regardless.

The machine path is the one-click login ticket (dwb-7):
`POST /v1/auth/login-tickets` (bearer) mints a single-use 60s ticket bound
to that raw token, and `GET /login/ticket/:t` consumes it atomically (one
winner), sets `session["api_token"]` and redirects to `/studio`.
Unknown/used/expired are indistinguishable (no oracle); the response is
`no-store` + `no-referrer`. See `BarkparkWeb.LoginTicketController`.

Browser password-reset rides the same email tokens as the JSON flow:
`GET|POST /login/reset` ("Forgot password?", anti-enumeration — always the
same confirmation) and `GET|POST /auth/reset/:token` (the emailed link's
landing page; render never consumes the token, only submit verifies it).
Magic-link (passwordless) is the same shape: `GET|POST /login/magic`
(request, anti-enumeration) + `GET /auth/magic/:token` (consume →
`user_session`). Both browser landings (`/auth/reset`, `/auth/magic`) are
the emailed URLs the JSON flow already sent but which 404'd in a browser.
Magic-link consume routes through the **same second-factor step as password
login** (`complete_sign_in/3`): a TOTP-armed user gets `/login/mfa`, an
org-governed factor-less user is blocked — magic-link is never a 2FA bypass
(the JSON `/magic-login` still issues directly; the browser surface is the
hardened one).
On a cloud-managed instance, `BARKPARK_CLOUD_URL` (→ `:cloud_login_url`)
puts a **Log in with Barkpark Cloud** button on `/login`: it deep-links to
`<cloud>/#/instance-login?url=<own-origin>`; the cloud SPA matches the
origin against the signed-in user's own fleet and rides the existing
studio-link mint back to `/login/ticket/:t` — the href carries no secret
and authorization stays on the cloud route. Unset → no button.

### Org-wide required MFA (opt-in overlay)

`organizations.require_mfa` (default false; admin-portal toggle) forces factor
enrolment. **Governing rule: ANY-org-requires → enforce (strictest-wins)** — a
user is governed by every org reachable via their user-type workspace
memberships (`Tenancy.org_requires_mfa_for_user?/1`); one requiring org is
enough, a laxer org grants no bypass, org-less workspaces never govern. A
governed, factor-less user still logs in (the body adds
`mfa_enrolment_required: true`) but the session surface answers
`403 mfa_enrolment_required` except `/me`, `/logout`, and the TOTP/passkey
enrolment endpoints (`RequireOrgMfaEnrolment` in the `:require_user` pipeline).
Enrolling any factor opens the gate. Flag unset everywhere → byte-identical.

## Field encryption (at rest)

`Barkpark.Crypto.FieldCipher` wraps a value in an AES-256-GCM envelope
`%{"_bpenc" => 1, "k" => version, "v" => base64}`. The DEK scope is the GCM AAD;
content fields encrypt under scope `"dataset:" <> dataset`. `DataKeys` manages
the active DEK, versioned rotation, and rewrap.

**Ciphertext-at-rest is never auto-decrypted on read.** Normal reads — search,
drafts, broadcasts, export — keep ciphertext and never see plaintext.
Decryption is an explicit, privileged `Content.reveal_fields/..` call only.
Encrypting an already-encrypted envelope is a no-op (idempotent).

## Field visibility (redaction)

Visibility redaction has ONE chokepoint: `Barkpark.Content.Envelope.render/3`
(and `render_many/3`) — `@canonical capability:visibility-redaction`. Every read
surface (REST query, search, share-link, history, reference expansion) threads
its caller through here, so a `private` / `owner_only` / allowlisted field is
dropped before it can leave the system. Contract:

- `caller_context == nil` ⇒ no redaction (internal/writer paths carry the full
  doc by design).
- `caller_context.is_admin` ⇒ no redaction (admins see all; ciphertext is still
  NOT decrypted here).
- any other caller ⇒ encrypted-ciphertext fields are dropped (encrypted ⇒
  **private by default**), and declared `private` / `readable_by` fields drop
  unless the caller is authorized.

Redaction extends to the query itself: **filtering or ordering on a field the caller can't read returns `422 forbidden_field`** (`Errors.to_envelope/2`), not a silent empty page — otherwise filter/sort would be an oracle to binary-search or sort by a hidden field's value even though the body is redacted.

With no encrypted values and no visibility metadata, output is byte-identical to
the legacy `render/1`.

## Ownership (row-level)

`owner_scoped` field types let a document carry an owner principal; a non-admin
caller sees only rows they own on the surfaces threaded through the visibility
chokepoint. Like everything above it is opt-in: declare nothing and ownership is
inert.

## HTTP surface & manifest

Routes (`api/lib/barkpark_web/router.ex`, `/v1/auth/*`):

| Verb | Method · Path | Tier | Gate |
|---|---|---|---|
| register | POST `/v1/auth/register` | none | `:user_auth` |
| login | POST `/v1/auth/login` | none | `:user_auth` |
| verify-email | POST `/v1/auth/verify-email` | none | `:user_auth` |
| request-reset | POST `/v1/auth/request-reset` | none | `:user_auth` |
| reset | POST `/v1/auth/reset` | none | `:user_auth` |
| me | GET `/v1/auth/me` | read | `:require_user` |
| logout | DELETE `/v1/auth/logout` | read | `:require_user` |
| mfa-enroll | POST `/v1/auth/mfa/enroll` | read | `:require_user` |
| mfa-verify | POST `/v1/auth/mfa/verify` | read | `:require_user` |
| mfa-disable | POST `/v1/auth/mfa/disable` | read | `:require_user` |

These appear in the capabilities manifest under the `auth` noun
(`Barkpark.Plugins.Capabilities`, `source: "core"`). The 5 public verbs are
tier `none` (an anonymous caller can discover login); the 5 session-gated verbs
are tier `read` (existence-hidden from anon, shown to any authenticated caller).

**Discovery only, not bp execution.** The session-gated verbs require a USER
session (`RequireUserSession`), not an `api_token`. `bp` authenticates with an
api_token and cannot drive a user-session verb — these are surfaced in the
manifest for documentation/discovery, not for `bp` execution.

> Manifest note: the Go golden fixtures under `docs/cli/fixtures/` are a frozen
> curated SUBSET that already omits some core nouns, so the `auth` noun does not
> require a fixture regen. If a future contract test round-trips the LIVE
> manifest against those fixtures, regenerate to include the `auth.*` commands.
