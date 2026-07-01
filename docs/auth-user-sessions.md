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
token cannot drive a reset, and consuming a token invalidates it.

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

Redaction extends to the query itself: **filtering or ordering on a field the caller can't read returns `403 forbidden_field`**, not a silent empty page — otherwise filter/sort would be an oracle to binary-search or sort by a hidden field's value even though the body is redacted.

Redaction extends to the query itself: **filtering or ordering on a field the caller can't read returns `403 forbidden_field`**, not a silent empty page — otherwise filter/sort would be an oracle to binary-search or sort by a hidden field's value even though the body is redacted.

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
