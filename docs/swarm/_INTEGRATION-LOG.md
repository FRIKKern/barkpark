<!-- doc-tier: human | canonical-for: swarm-integration-foundation-log | budget: 2000tok -->
# Swarm integration log — `swarm/integration-foundation`

Integrated 7 Coolify→Barkpark swarm candidates into one foundation branch off
`bef11206` (the user's HEAD). Each candidate was a single commit built in an
isolated worktree; merged here in dependency-closure order with one `--no-ff`
merge commit per step so history stays auditable.

Final HEAD: **`162b6160`** — note this SHA and the renumber SHA `fda80cce` below no
longer resolve; the base `bef11206` still does. Squash-merge plus gc retired them, so
verify this log by CONTENT, not by ref.

## Per-step summary

| # | Branch | Result | Files union-merged / hand-reconciled | Migrations dropped |
|---|---|---|---|---|
| 1 | oban-substrate | clean | — | — |
| 2 | rbac-roles | clean (ort auto) | — | — |
| 3 | account-sessions | clean (ort auto) | accounts.ex, registry.ex, router.ex (disjoint regions) | — |
| 4 | notifications-email | **conflicted** | mix.exs (deps union), config.exs + runtime.exs (config-block union), router.ex (register/ tx — combined `Notifications.ensure_settings` + `create_user_session_token/2`) | — |
| 5 | teams-invitations | **conflicted** | accounts.ex (added fns both sides), auth.ex (kept `gate_role` + adopted `json_halt` trio, dropped rbac's dup `forbidden`), router.ex (notifications vs team/member routes; 3 gate call-sites picked `require_primary_team_admin`) | — |
| 6 | personal-access-tokens | **conflicted** | accounts.ex, **user_token.ex** (deduped schema fields + merged moduledoc), auth.ex (union `require_team_admin/owner` + `require_user_or_pat`/`require_ability`), router.ex (token routes + go_live gate), app.js / index.html (UI union), accounts_test.exs | **`add_pat_columns_to_user_tokens`** (combined into the session migration) |
| 7 | subscription-billing | clean (ort auto) | registry.ex, router.ex, runtime.exs (disjoint) | — |

## Critical: the shared `user_tokens` migration (steps 3 + 6)

Both account-sessions and personal-access-tokens shipped a migration altering
`user_tokens` at the same timestamp. Resolution:

- Kept **one** combined migration, `..._add_session_lifecycle_to_user_tokens.exs`,
  now adding the **superset** of columns:
  `revoked_at, ip_address, user_agent, last_used_at` (sessions) +
  `name, abilities (NOT NULL default ["read"]), team_id → teams` (PAT), plus
  indexes `[:user_id, :revoked_at]`, `[:team_id]`, `[:user_id, :context]`.
- Deleted the PAT duplicate `add_pat_columns_to_user_tokens.exs`.
- Fixed the auto-merge's **duplicate schema fields** in `accounts/user_token.ex`
  (`revoked_at` / `last_used_at` were each declared twice — would not compile);
  the schema now declares the deduped union once and agrees with the migration.

## Migration version renumber (all collided at one timestamp)

Each isolated candidate reused `20260629120000` / `...120100`, so the merged tree
had **5 migrations at version 20260629120000** and **2 at 120100** — a guaranteed
`mix ecto.migrate` duplicate-version failure. Renumbered to unique, ordered
versions in merge order (commit `fda80cce`). All touch independent tables
(or base tables created far earlier), so ordering among them is safe.

### Final `cloud/priv/repo/migrations/` (new rows only)

```
20260629120000_add_oban_jobs.exs                       (step 1)
20260629120100_add_session_lifecycle_to_user_tokens.exs (steps 3+6, COMBINED)
20260629120200_create_email_notification_settings.exs  (step 4)
20260629120300_create_notification_deliveries.exs      (step 4)
20260629120400_create_team_invitations.exs             (step 5)
20260629120500_add_lifecycle_to_subscriptions.exs      (step 7)
20260629120600_add_suspended_to_barkparks.exs          (step 7)
```

`api/priv/repo/migrations/20260629130000_add_pat_fields_to_api_tokens.exs`
(step 6, the api/ fast-follow) is a **different Ecto repo** — no collision, left
as-is.

## Code hand-reconciled (beyond mechanical union)

- **`web/auth.ex` helper consolidation** — teams-invitations refactored
  `unauthorized/forbidden/not_found` into a single `json_halt/3`; kept that and
  dropped rbac-roles' standalone multiline `forbidden/1`. The duplicate slipped
  back via auto-merge in step 6 (PAT re-added it) and the **compiler caught it**
  ("previous clause always matches") — removed again in `162b6160`.
- **`web/router.ex` gate call-sites** — `DELETE /v1/barkparks/:id`,
  `POST /v1/billing/checkout`, and the shared `go_live/0` each had two competing
  gates (rbac's `require_team_admin`/`require_team_owner` vs teams'
  `require_primary_team_admin`). All helper fns coexist; only the call-site was
  chosen. See caveats.
- **`web/router.ex` interleaved route blocks** — the notifications/teams routes
  (HEAD) and the token routes (PAT) shared common `require_user` / `if-halted`
  bodies and trailing `end`s; reconstructed each route fully formed.
  (An early pass accidentally dropped the `defp go_live(conn) do` header — caught
  by a parse check and restored before commit.)

## Verification

- `elixir Code.string_to_quoted!` parse-check on every conflict-resolved file.
- `node --check` on `priv/static/app.js`.
- `mix deps.get` (resolved + locked oban / swoosh / gen_smtp into `mix.lock`).
- **`mix compile` → exit 0, `Generated barkpark_cloud app`.** (The repo aliases
  `cc` to a non-compiler; the bcrypt NIF needs `CC=/usr/bin/clang`.)
- Remaining warnings are **pre-existing candidate issues**, not from the merge:
  Oban `:states` uniqueness in `StaleProvisionJobReaper` (oban-substrate), and
  `register/4` unused default args (account-sessions).
- Tests were **not run** (no database provisioned). Candidates were never
  individually compiled; a green test suite is not expected.

## Caveats for the reviewer (most important first)

1. **Authorization policy was softened at two gates — BOTH HAVE SINCE BEEN
   RE-TIGHTENED. This item is history, not a live caveat.**
   - `go_live` (launch): shipped PAT-flexible
     (`require_user_or_pat |> require_ability("deploy")`), so a plain session
     member could go-live. FIXED: the launch gate's `cond` now carries a session
     branch requiring `Accounts.team_admin?/2` on the resolved team and otherwise
     halting via `Auth.forbidden(conn, required: "admin", scope: "team")`.
   - `POST /v1/billing/checkout`: shipped as `require_primary_team_admin`.
     FIXED: `Auth.require_primary_team_owner/1` was written and the route calls
     it, matching `@action_min billing: [owner]`. The refusal is `403`, not the
     `422 no_team` this entry claimed.
   Neither is flagged with a `NOTE(integration):` comment — that marker appears
   nowhere in the repo, so do not grep for it.

2. **Compiles, but never migrated or tested against a DB.** Review the combined
   `user_tokens` migration's column nullability/defaults and the new FKs before
   `mix ecto.migrate`. The two judge-flagged "revise" items in the candidates'
   own `docs/swarm/*.md` still apply.

3. **Half of this is stale.** `require_team_admin/2` is NOT dead — it now has 16
   router call sites (github installations, notification settings + test,
   push-relay, env vars, ...), so the codebase standardized on it. Only
   `require_team_owner/2` is genuinely callerless; the primary-team variants
   (`require_primary_team_admin/1`, `require_primary_team_owner/1`) hold the
   billing and launch gates. Re-derive the call-site count against
   `cloud/lib/barkpark_cloud/web/router.ex` before acting on this row.
