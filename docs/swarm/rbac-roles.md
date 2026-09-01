<!-- doc-tier: cold | canonical-for: swarm-rbac-roles | budget: 4000tok -->
# rbac-roles — provenance note

**Slug:** `rbac-roles` · **Target app:** `cloud/` (BarkparkCloud) · **Status:** candidate (judge before merge)

## What

Adds the *reader* for the already-shipped-but-inert `team_memberships.role` column:
a total authorization module plus two `Plug.Router`-idiomatic gate functions, wired
ahead of the money- and infra-destructive Cloud routes. **No new table, no migration.**

- `BarkparkCloud.Accounts.Authz` — `role/2`, `team_admin?/2`, `team_owner?/2`, a TOTAL
  `authorize/3` driven by a data-table `@action_min` map, `rank/1`, and a ranked
  anti-escalation guard `can_grant?/3`.
- `BarkparkCloud.Web.Auth.require_team_admin/2` + `require_team_owner/2` — drop-in
  replacements for the `Auth.require_user(conn, [])` line in a mutating route; halt
  `403 {"error":"forbidden"}` fail-closed.
- `BarkparkCloud.Accounts.add_member_as/4` — actor-aware membership write that refuses
  privilege escalation at the context (closes gap #3 even if a route forgets to gate).
- Five one-line route swaps gating billing/checkout (owner), go-live/launch,
  barkpark DELETE + retry, and provider-connect (admin). Reads and site CRUD stay at
  `member`.

## Why

RBAC was the 5/5 beta blocker: the role column exists and is *never read*, so any team
member can spend money and destroy infra. This ports api/'s shipped per-grant authz
model into Cloud verbatim in shape, closing the hole without inventing a parallel style.

## Coolify source anchors

- `app/Enums/Role.php` — `Role::rank` ranked roles (member < admin < owner). Mirrored by
  `Authz.@rank` / `rank/1`.
- `app/Models/Member.php` — an admin cannot promote past their own rank. Mirrored by
  `can_grant?/3`.
- `app/Policies/TeamPolicy.php` — `view` (member), `manageMembers` / `delete` (admin/owner).
  Mirrored by the `@action_min` table.
- `app/Policies/S3StoragePolicy.php::create` — admin-gated credential create. Mirrors
  `:connect_provider`.
- **Deliberately dropped** (per gap analysis "do NOT copy"): Coolify's disabled
  `return true` policies and the magic `team_id = 0` backdoor.

## Barkpark reference anchors (the template being ported)

- `api/lib/barkpark/tenancy/auth.ex` — `workspace_admin?/2`, `membership_role/2`
  (the grant-is-the-role reader). Cross-tenant P0 fix lineage: barkpark-23yi.
- `api/lib/barkpark_web/plugs/require_workspace_role.ex` — the 403 fail-closed gate.

## Barkpark files touched

| File | Action |
|---|---|
| `cloud/lib/barkpark_cloud/accounts/authz.ex` | new — Authz module |
| `cloud/lib/barkpark_cloud/accounts.ex` | edit — `add_member_as/4` |
| `cloud/lib/barkpark_cloud/web/auth.ex` | edit — `require_team_admin/2`, `require_team_owner/2`, `gate_role/3`, `forbidden/2` (arity 1 does not exist — a default `evidence \\ []` reds the `--warnings-as-errors` Cloud gate) |
| `cloud/lib/barkpark_cloud/web/router.ex` | edit — 5 gate-line swaps |
| `cloud/test/barkpark_cloud/accounts/authz_test.exs` | new — unit tests |
| `cloud/test/barkpark_cloud/web/router_test.exs` | edit — RBAC gating describe block |

## How to test

```bash
cd cloud
mix test test/barkpark_cloud/accounts/authz_test.exs
mix test test/barkpark_cloud/web/router_test.exs
```

The existing `user_with_team/0` fixture grants `"owner"`, so all prior happy-path
router tests keep passing (owner satisfies every gate). The new tests add the
member/admin negative paths (403) and the no-team/no-token boundaries.

## Caveats

- Could not run `mix format` / `mix compile` / `mix test` in the worktree — deps/_build
  are not provisioned (`import_deps :ecto` formatter error). Code is written to match the
  existing formatter output and neighbouring module conventions; verify on a provisioned
  checkout.
- `manage_members` / `delete_team` actions and `can_grant?/3` were wired into the context
  (`add_member_as/4`) ahead of any route. **The routes have since landed** —
  `GET /v1/teams/:id/members`, `PATCH|DELETE /v1/teams/:id/members/:user_id` plus the four
  invitation routes — so the escalation hole was already closed at the context when they
  appeared, exactly as planned.
- Token revocation on demotion (Coolify `RevokeUserTeamTokens`) was **out of scope here**
  and has SINCE SHIPPED: `user_tokens` carries `revoked_at`
  (`20260629120100_add_session_lifecycle_to_user_tokens.exs`), and both named hook points —
  `Accounts.update_member_role_as/4` and `Accounts.remove_member_as/3` — now call
  `delete_user_session_tokens/1`.
- Policy decision: site CRUD/deploy (`POST /v1/sites*`) stays at `member`. Spending money
  and destroying infra is the beta hole; routine content work is not. Tighten later by
  swapping one plug call.
