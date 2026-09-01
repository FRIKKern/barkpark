<!-- doc-tier: human | canonical-for: swarm-teams-invitations | budget: 1200tok -->
# Swarm candidate — Teams & invitations (`teams-invitations`)

**Target app:** `cloud/` (`BarkparkCloud`). **Status:** CANDIDATE — judge before merge.

## What

Adds the full team-invitation lifecycle + member management + role enforcement to
Barkpark Cloud, entirely inside `cloud/`. The existing `teams` / `team_memberships`
model is reused verbatim (no shape change). New:

- A `TeamInvitation` schema + `team_invitations` table storing only a SHA-256 hash
  of an opaque accept token (the plaintext is returned once, in the accept URL).
- Context functions on `Accounts`: `invite_member/4`, `accept_invitation/2`,
  `get_live_invitation/1`, `list_invitations/1`, `revoke_invitation/2`,
  `list_team_members/1`, `remove_member/2`, `update_member_role/3`, `team_role/2`,
  `team_admin?/2`, `delete_user_session_tokens/1`.
- Role-rank helpers on `TeamMembership` (`rank/1`, `admin?/1`, `outranks?/2`).
- An HTTP role gate `Web.Auth.require_team_role/3` (cloud twin of api/'s
  `RequireWorkspaceRole`, copied not reused) + `require_primary_team_admin/1`.
- 8 JSON routes (members, invitations, accept) + an RBAC gate wired onto the
  previously any-member-reachable `billing/checkout`, `launch`/`go-live`, and
  `DELETE /v1/barkparks/:id`.
- `role` added to the `/v1/me` payload (the only existing response shape touched).

## Why

`teams` + `team_memberships` existed but had no way to **invite** anyone, no
member CRUD, and the `role` column was inert — every authenticated team member
could open billing, launch a billed box, or delete an instance. This closes the
RBAC hole and ships the invite path beta needs.

## Coolify source anchors (read-only reference)

- `app/Models/TeamInvitation.php` — invite model (`uuid`, `email` downcased, `role`,
  `link`, `via`, `isValid()` expiry). We reject its `Crypt::encryptString(...)`
  magic-login link in favor of a hashed opaque token.
- `app/Enums/Role.php` — `rank()/lt()/gt()` (member<admin<owner) → `TeamMembership.rank/outranks?`.
- `app/Actions/User/RevokeUserTeamTokens.php` — delete-sessions-on-removal →
  `Accounts.delete_user_session_tokens/1`.
- `app/Livewire/Team/{InviteLink,Invitations,Member}.php` — UI feature surface.
- `database/migrations/2023_03_20_112813_create_team_invitations_table.php`.

## Barkpark files

Added:
- `cloud/lib/barkpark_cloud/accounts/team_invitation.ex`
- `cloud/priv/repo/migrations/20260629120400_create_team_invitations.exs`
- `cloud/test/barkpark_cloud/accounts_invitations_test.exs`
- `cloud/test/barkpark_cloud/web/router_invitations_test.exs`

Changed:
- `cloud/lib/barkpark_cloud/accounts/team_membership.ex` (rank helpers)
- `cloud/lib/barkpark_cloud/accounts.ex` (lifecycle + member mgmt + token delete)
- `cloud/lib/barkpark_cloud/web/auth.ex` (`require_team_role/3`, `require_primary_team_admin/1`)
- `cloud/lib/barkpark_cloud/web/router.ex` (8 routes, helpers, RBAC gates, `/v1/me` role)

## Data model

`team_invitations`: `id` (binary_id PK), `team_id` (FK → teams, ON DELETE CASCADE),
`invited_by_id` (FK → users, ON DELETE SET NULL), `email` (downcased), `role`,
`token_hash` (UNIQUE), `expires_at`, `accepted_at` (nil = live), timestamps.
Partial unique `(team_id, email) WHERE accepted_at IS NULL` = one live invite per
email per team.

## How to test

Deps/_build are not provisioned in the worktree, so a full `mix test` can't run here.
Once provisioned:

```bash
cd cloud
mix ecto.migrate          # applies 20260629120400_create_team_invitations
mix test test/barkpark_cloud/accounts_invitations_test.exs \
          test/barkpark_cloud/web/router_invitations_test.exs
```

All touched files were syntax-checked with `Code.string_to_quoted!/1` and formatted
with `Code.format_string!` (Ecto `locals_without_parens`).

## Caveats / review risks

1. **`primary_team` gating** on billing/go-live/DELETE assumes the user acts within
   their primary team (exact in single-team beta; revisit with an explicit
   `:current_team` when multi-team lands).
2. **Register-on-accept** creates a personal team — an invitee who registers via the
   accept flow ends with their own team plus the invited one. A `skip_team: true`
   register variant is the tidy follow-up.
3. **Global logout on removal/demotion** — `delete_user_session_tokens/1` deletes ALL
   the user's sessions (tokens are global, not team-scoped). Desirable now; narrow
   to team-scoped when tokens carry a `team_id`.
4. **No expiry sweep** — expired invites are filtered out on every read (like
   Coolify), not actively purged. Rows are tiny and cascade-delete with the team.
5. **No mailer / no SPA UI — both have since shipped.** The invite is emailed on
   create (`send_invite_email/3` -> `Notifications.deliver_invite/1`), and the dashboard
   Members panel exists in `cloud/priv/static/app.js`. The accept URL is no longer
   copy-paste-only.
