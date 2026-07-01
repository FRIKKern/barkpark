<!-- doc-tier: agent | canonical-for: auth-tokens-roles | budget: 1400tok -->
# Auth & roles

Barkpark uses bearer-token API tokens (`Authorization: Bearer <token>`)
backed by `api_tokens` (SHA256 token hash + permission list per token).
Browser LiveViews read the same token from `session["api_token"]` via the
`BarkparkWeb.LiveAuth` `on_mount` hooks.

> User accounts, login sessions, MFA, field encryption, field visibility, and
> row ownership are the **core-auth model** — see
> [docs/auth-user-sessions.md](auth-user-sessions.md) (canonical-for
> core-auth-model).

## Tenancy — token ↔ workspace

The principal of a request is the API token; every token is bound to
exactly one **workspace** (the tenancy boundary; see the
Workspace → Project → Dataset hierarchy in `docs/api-v1.md` §1a). The
binding is two facts that must agree:

- `api_tokens.workspace_id` — the workspace the token belongs to.
- a `workspace_memberships` row — the token's principal is a member of
  that workspace.

Content/data requests carry the workspace + project in the path
(`/w/:workspace_slug/p/:project_slug/v1/data/...`). The server resolves
the workspace and project from the path and enforces tenancy **before**
any permission check:

| Situation | Result |
|---|---|
| `:workspace_slug` does not resolve to a workspace | `404 not_found` |
| Workspace resolves, but the token has no `workspace_memberships` row for it | `403 forbidden` |
| Workspace resolves and the token is a member | proceed to permission checks below |

Every content read and write is scoped by the resolved workspace — a token
can only see and mutate documents in its own workspace. There is no
cross-workspace read.

### Write gate

The core mutate endpoint
(`POST /w/:workspace_slug/p/:project_slug/v1/data/mutate/:dataset`)
enforces the `write` permission **after** tenancy passes. A token that is a
valid member lacking `write` (a read-only token) gets `403 forbidden` on
mutate; reads remain available.

### Default workspace + flat alias

Flat content paths (`/v1/data/:dataset/*`, etc.) still work, resolving to
the `"Default"` workspace/project. The dev token below is a `Default`
member, so flat-route callers work unchanged.

## Roles (permissions list on `ApiToken.permissions`)

| Permission | Grants                                                              | Surfaces                                                     |
|------------|---------------------------------------------------------------------|--------------------------------------------------------------|
| `read`     | Public reads on private datasets / private schemas                  | `/w/:workspace_slug/p/:project_slug/v1/data/query/*` (flat alias `/v1/data/query/*`), `/media` |
| `write`    | Mutations (create, patch, publish, unpublish, delete)               | `POST /w/:workspace_slug/p/:project_slug/v1/data/mutate/:dataset` (flat alias `POST /v1/data/mutate/:dataset`) |
| `ops`      | Operate the Bokbasen publish pipeline (read-only on plugin secrets) | `/admin/onixedit/bokbasen` LiveView (old `/admin/bokbasen` 301-redirects here) |
| `admin`    | All of the above + plugin-settings reveal/audit + schema CRUD       | `/studio/settings`, `/v1/schemas/*`, `/v1/plugins/settings/*`, `/v1/webhooks/*`, `/v1/plugins/onixedit/export/*` |

> **Media upload** (`POST /media/upload`, `POST /v1/media/:dataset/upload`) needs a valid
> token (bearer or session) but **not** `write` — the `:media_mutate` /
> `:scoped_media_mutate` pipelines omit `RequireWritePermission`.

### Hierarchy

`admin` is a **superset** of every other permission. Granting `admin`
grants `ops` (and `read` + `write` for routes that check those plugs).
The `BarkparkWeb.LiveAuth.:ops` hook accepts either `ops` or `admin`,
so existing admin tokens keep working when an `ops`-gated route is added.

### Why `:ops` is separate from `:admin`

Bokbasen operators need submission status/retry/errors but must not read
the encrypted `client_secret` that `/studio/settings` exposes.

## LiveView `on_mount` hooks

```elixir
# api/lib/barkpark_web/live_auth.ex
on_mount :admin   # → requires "admin"
on_mount :ops     # → requires "ops" OR "admin"
```

Both halt with a flash + redirect to `/studio` when the session token
is missing, malformed, or lacks the required permission.

### One-click login tickets (dwb-7)

`POST /v1/auth/login-tickets` (bearer) mints a single-use 60s ticket bound
to that raw token; `GET /login/ticket/:t` consumes it atomically (one
winner), sets `session["api_token"]`, redirects to `/studio`. Unknown/used/
expired are indistinguishable (no oracle); response: `no-store` +
`no-referrer`. See `BarkparkWeb.LoginTicketController`.

## Plug pipelines (HTTP)

```elixir
# api/lib/barkpark_web/router.ex
pipeline :require_token  # → BarkparkWeb.Plugs.RequireToken
pipeline :require_admin  # → RequireToken + RequireAdmin
```

## Dev token

`barkpark-dev-token` (seeded by the `demo` seed profile — `Barkpark.Seeds.Demo`; the `clean` profile mints none) carries
`["read", "write", "admin"]` and is bound to the `Default` workspace
(with a `workspace_memberships` row), so it satisfies every gate in this
document and works on both the scoped and flat-alias routes. Production
should issue narrower per-persona tokens bound to their own workspace.

**MUST rotate before prod**: the dev token has read + write + admin scopes
and must not be used in production. Starter templates bake
`barkpark-dev-token` into `BARKPARK_TOKEN` and `BARKPARK_SERVER_TOKEN`;
replace **both** with freshly-issued tokens before deploying.
