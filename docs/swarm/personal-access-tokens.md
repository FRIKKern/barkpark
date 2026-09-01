<!-- doc-tier: human | canonical-for: swarm-personal-access-tokens | budget: 1200tok -->
# Personal Access Tokens (scoped) — swarm candidate

**Slug:** `personal-access-tokens` · **Branch:** `swarm/personal-access-tokens` · **Status:** CANDIDATE (judge before merge)

## What

Scoped, named, revocable API tokens a user mints for programmatic access, adapted from
Coolify's "Personal API tokens (scoped)".

- **Primary (`cloud/`):** promote the existing `user_tokens` table into a dual-purpose
  store via its already-reserved `context` column (`context = "pat"`) — no parallel
  `personal_access_tokens` table. A PAT carries a `name`, an `abilities` array
  (`read`/`write`/`deploy`/`root`), a bounded `expires_at`, a `last_used_at` liveness
  stamp, and a `revoked_at` tombstone, bound to the `team_id` it was minted under.
- **Fast-follow (`api/`):** extend `api_tokens` with `name`/`last_used_at`/`created_by`,
  add a role-gated `create_personal_access_token/3`, and stamp `last_used_at` in the
  bearer plug.

## Why this shape

The `cloud/user_tokens` migration explicitly left the seam open —
`context :string default "session"` with the comment *"room for future token kinds
without a new table"* (`cloud/priv/repo/migrations/20260626195000_create_user_tokens.exs`).
A PAT is just `context = "pat"`. One table, one verify-by-hash path, the `context` column
discriminates, and every query is scoped by it so the session lifecycle never touches PAT
rows and vice-versa. This follows the BRIEF's "do not invent a parallel style" rule and
mirrors `Registry.mint/verify/revoke_agent_token`.

**Shared win:** the new `revoked_at` column also lets session-token verify honour
revocation — `verify_user_session_token/1` now filters `is_nil(revoked_at)` and
`context == "session"`, which unblocks the logout / member-removal kill-switch gaps the
gap analysis flagged.

## Coolify source anchors

- `app/Models/PersonalAccessToken.php` — the model (token + abilities + team_id).
- `app/Models/User.php:232-250` — mint + `bpc_pat_`-style token prefix
  (`config('sanctum.token_prefix')`).
- `app/Livewire/Security/ApiTokens.php:21,23-29,57-88,90-127` — the settings UI:
  bounded expiry select (7/30/60/90/365), `updatedPermissions` exclusivity
  (root/deploy collapse the set), one-time `session()->flash('token', …)` reveal.
- `app/Http/Middleware/ApiAbility.php` — root-bypass + per-ability gate.
- `app/Policies/ApiTokenPolicy.php:91-95` — only admin/owner may mint elevated tokens.
- `database/migrations/2019_12_14_000001_create_personal_access_tokens_table.php`.

## Barkpark files touched

**cloud/ (primary):**
- `priv/repo/migrations/20260629120100_add_session_lifecycle_to_user_tokens.exs` — the PAT columns were combined into the shared session migration (integration dedup; see `_INTEGRATION-LOG.md` step 6).
- `lib/barkpark_cloud/accounts/user_token.ex` — `pat_changeset/2`, ability vocab +
  server-side `root`/`deploy` exclusivity (`normalize_abilities/1`).
- `lib/barkpark_cloud/accounts.ex` — `create/list/revoke/verify_personal_access_token`,
  throttled `last_used_at` stamp, session verify honours `revoked_at`/`context`.
- `lib/barkpark_cloud/web/auth.ex` — `require_user_or_pat/2`, `require_ability/2`,
  `forbidden/2` (a session implies `["root"]`, so the browser is never gated). Arity
  1 is refused on purpose — a default `evidence \\ []` reds the Cloud gate, which
  compiles with `--warnings-as-errors`.
- `lib/barkpark_cloud/web/router.ex` — session-only `GET/POST/DELETE /v1/tokens`,
  `pat_json/1`, `parse_expiry/1`; opted `GET /v1/me`, `GET /v1/barkparks`,
  `GET /v1/sites` (read), `POST /v1/sites/:id/deploy` (write), and go-live (deploy)
  onto `require_user_or_pat` + ability gates.
- `priv/static/{index.html, app.js, app.css}` — "API tokens" view + mint modal +
  one-time reveal + revoke.
- `test/barkpark_cloud/accounts_test.exs` (additions), `test/barkpark_cloud/web/router_pat_test.exs` (NEW).

**api/ (fast-follow):**
- `priv/repo/migrations/20260629130000_add_pat_fields_to_api_tokens.exs` — NEW.
- `lib/barkpark/auth/api_token.ex` — add `name`/`last_used_at`/`created_by`.
- `lib/barkpark/auth.ex` — role-gated `create_personal_access_token/3` + `touch_last_used/1`.
- `lib/barkpark_web/plugs/require_token.ex` — stamp `last_used_at` on verify.
- `test/barkpark/auth_test.exs` — additions.

## How to test

Deps are not provisioned in the worktree, so this was verified by parse-check only
(`Code.string_to_quoted/1` on every `.ex/.exs`; `node --check` on `app.js`). To run for real:

```bash
# cloud/
cd cloud && mix deps.get && mix ecto.migrate && mix test \
  test/barkpark_cloud/accounts_test.exs \
  test/barkpark_cloud/web/router_pat_test.exs

# api/
cd api && mix deps.get && mix ecto.migrate && mix test test/barkpark/auth_test.exs
```

Manual smoke (cloud, logged-in session token `$S`). NOTE THE PORT: the cloud control
plane listens on **4100** (`config :barkpark_cloud, BarkparkCloud.Web.Endpoint, ... port: 4100`,
and `runtime.exs` defaults `PORT` to the same); 4000 is `api/`'s Phoenix endpoint, so the
older spelling of these commands hit the wrong app.

```bash
curl -XPOST localhost:4100/v1/tokens -H "authorization: Bearer $S" \
  -H 'content-type: application/json' \
  -d '{"name":"ci-key","abilities":["write"],"expires_in_days":30}'   # → 201 {token: bpc_pat_…, pat:{…}}
PAT=bpc_pat_…
curl -fsS localhost:4100/v1/barkparks -H "authorization: Bearer $PAT"   # read → 200
curl -fsS -XPOST localhost:4100/v1/sites/$ID/deploy -H "authorization: Bearer $PAT"  # write → 201
```

## Adaptation deltas + honest caveats

- **api/ has no `users` table.** Studio is admin-gated (`LiveAuth :admin`), not
  per-user. The cloud design's `user_id` FK was DROPPED from the api/ migration; PAT
  "ownership" in api/ is the minting admin recorded in `created_by` (a string). The
  role gate in `create_personal_access_token/3` therefore takes the minter's role as an
  explicit `:role` opt (the future Studio pane passes the admin's workspace role).
- **api/ Studio settings pane is NOT built here.** The design's `Security/ApiTokens`
  LiveView pane is the largest api/ piece and would need deep `studio_live.ex` work; the
  callable, tested substrate (migration + schema + role-gated context fn + plug stamp) is
  shipped, the pane is left as a follow-up to keep the change cohesive and avoid shipping a
  broken LiveView.
- **Deferred (dependency-blocked, per the design):** the expiry-warning job
  (needs a mailer/scheduler) and the `read:sensitive` redaction tier.
- **PAT management is session-only.** You mint/list/revoke from the logged-in dashboard,
  never with a PAT — a leaked `read` token can never escalate to mint a `root` one.
- **Not compiled.** Idiomatic and parse-clean, but a full `mix compile`/`mix test` run
  was not possible in the worktree (deps absent). Judge by reading + the test files.
