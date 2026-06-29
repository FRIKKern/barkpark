<!-- doc-tier: cold | canonical-for: swarm-account-sessions | budget: 4000tok -->
# swarm: account-sessions

**Candidate — judge before merge.** Adapts Coolify's "Account management & sessions"
into Barkpark Cloud (`cloud/`, `BarkparkCloud.*`).

## What

Makes USER session tokens **revocable** and exposes the verbs Coolify gets from
its `DeletesUserSessions` kill-switch, plus the per-device active-sessions
list/revoke UI Coolify itself lacks.

Parts 1–3 (beta-critical, zero new deps) are **built**:

1. **Sessions are revocable + carry device metadata.** Migration adds
   `revoked_at`, `ip_address`, `user_agent`, `last_used_at` to `user_tokens`.
   `verify_user_session_token/1` now rejects revoked tokens and refreshes
   `last_used_at`. New context verbs: `revoke_user_session_token/1` (single-device
   logout), `revoke_user_session/2` (one row, ownership-scoped),
   `revoke_all_user_sessions/2` (sign out everywhere, with `:except`),
   `list_user_sessions/1`.
2. **Password change ⇒ sign out everywhere.** `User.password_changeset/2` +
   `Accounts.update_user_password/4` verify the current password timing-safe, then
   in ONE transaction write the new hash, revoke all other user sessions, and call
   the new `Registry.revoke_all_agent_tokens_for_user/1` (joined through the user's
   teams' barkparks). The acting tab is re-minted a fresh token so the caller stays
   logged in.
3. **Account & sessions SPA panel** in `priv/static/app.{js,css}`: sessions table
   (current row badged "This device"), per-row revoke, "sign out everywhere else",
   change-password form, and a logout that calls the API.

Routes (all hang off the existing user-session block in `web/router.ex`):
`DELETE /v1/auth/logout`, `GET /v1/account/sessions`,
`DELETE /v1/account/sessions/:id`, `DELETE /v1/account/sessions`,
`PUT /v1/account/password`.

Parts 4 (self-service deletion) and 5 (verified email change) are **designed but
NOT built** — they are gated on deps that don't exist yet (a `Billing.cancel/1`
and a mailer respectively). See the design doc for the full sketch.

## Why

Barkpark Cloud is exiting beta. A leaked/stolen session token currently has no
kill switch — `UserToken` deliberately omitted `revoked_at` ("YAGNI",
user_token.ex). Coolify treats the mass-invalidate-on-password-change as
table-stakes account hygiene. This copies the already-proven
`Registry.AgentToken` revocable-token pattern (which carries `revoked_at` +
`revoke_agent_token/1`) verbatim into the user layer, so the two never drift.

## Coolify source anchors

- `app/Traits/DeletesUserSessions.php:13-37` — the kill switch: `deleteAllSessions()`
  wipes `sessions` for the user and calls `RevokeUserTeamTokens::forUser`; a `boot
  …` hook fires it on `wasChanged('password')`. We do the same as an EXPLICIT
  context step (`update_user_password/4`), not a model hook.
- `app/Actions/User/RevokeUserTeamTokens.php:20-23` — `forUser($id)` deletes every
  `PersonalAccessToken` for the user. Maps to
  `Registry.revoke_all_agent_tokens_for_user/1`.
- Coolify's `sessions` table carries `ip_address` / `user_agent` / `last_activity`
  but never surfaces them — we capture the same three (`ip_address`,
  `user_agent`, `last_used_at`) AND show them.

## Barkpark patterns mirrored

- `cloud/lib/barkpark_cloud/registry/agent_token.ex` + `registry.ex`
  (`mint_agent_token/3`, `verify_agent_token/1` with its `is_nil(revoked_at)`
  guard, `revoke_agent_token/1` struct + plaintext clauses) — the verbatim
  template for the user-token verbs.
- `web/auth.ex` `bearer_token/1` (already public) — re-extracts the calling
  token plaintext in the logout / password routes.
- `web/router.ex` register/login device-capture threads `session_opts(conn)`
  (peer IP + User-Agent) into the mint.

## Files touched

| File | Change |
|---|---|
| `cloud/priv/repo/migrations/20260629120000_add_session_lifecycle_to_user_tokens.exs` | **new** — +4 cols, +index |
| `cloud/lib/barkpark_cloud/accounts/user_token.ex` | +4 fields, widen cast, moduledoc |
| `cloud/lib/barkpark_cloud/accounts/user.ex` | +`password_changeset/2` |
| `cloud/lib/barkpark_cloud/accounts.ex` | revoke/list/`update_user_password`; verify guard + touch; mint opts; moduledoc |
| `cloud/lib/barkpark_cloud/registry.ex` | +`revoke_all_agent_tokens_for_user/1` |
| `cloud/lib/barkpark_cloud/web/router.ex` | +5 routes, `session_json/2`, device-capture helpers, register/4 |
| `cloud/priv/static/app.js` + `app.css` | Account & sessions panel |
| `cloud/test/barkpark_cloud/accounts_test.exs` | +6 describe blocks |
| `cloud/test/barkpark_cloud/web/router_sessions_test.exs` | **new** — the 5 routes |

## How to test

Deps aren't provisioned in the worktree, so a full `mix test` can't run here. Once
deps + DB exist:

```bash
cd cloud
mix ecto.migrate                       # applies the new migration
mix test test/barkpark_cloud/accounts_test.exs
mix test test/barkpark_cloud/web/router_sessions_test.exs
```

Syntax was verified with `Code.string_to_quoted!/1` on every touched `.ex/.exs`
and `node --check` on `app.js`.

## Caveats / honest assessment

- **`verify_user_session_token/1` now writes on every read** (the `last_used_at`
  touch, a single keyed `update_all`). That is a deliberate behaviour change —
  every authenticated request issues one extra UPDATE. Fine at beta scale; if it
  ever shows up hot, debounce it (only touch when `last_used_at` is older than N
  minutes) or move it off the request path.
- **`revoke_all_agent_tokens_for_user/1` kills agent creds for EVERY team the user
  belongs to**, not just boxes they solely own. That is the safe default for a
  password compromise; a narrower rule is a later refinement.
- **Not run against a DB.** Logic is verified by reading + parse-checks + the test
  suite, but the migration has not been applied and the tests have not executed.
- **`mix format` not run** (formatter needs `:ecto` from deps). Code was written to
  the project's existing formatting by hand.
- Parts 4 + 5 are designed only — see `03-designs/account-sessions.md`.
