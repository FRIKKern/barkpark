# Auth & roles

Barkpark uses bearer-token API tokens (`Authorization: Bearer <token>`)
backed by `api_tokens` (SHA256 token hash + permission list per token).
Browser LiveViews read the same token from `session["api_token"]` via the
`BarkparkWeb.LiveAuth` `on_mount` hooks.

## Tenancy — token ↔ workspace

The principal of a request is the API token, and every token is bound to
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
valid member of the workspace but lacks `write` (a read-only token) gets
`403 forbidden` on mutate. Reads remain available to such a token.

### Default workspace + flat alias

The old flat content paths (`/v1/data/:dataset/*`, etc.) still work and
resolve to a `"Default"` workspace + `"Default"` project. Existing content
was auto-backfilled into `Default`/`Default` with zero data loss. The dev
token (below) is a member of `Default`, so flat-route callers keep working
unchanged.

## Roles (permissions list on `ApiToken.permissions`)

| Permission | Grants                                                              | Surfaces                                                     |
|------------|---------------------------------------------------------------------|--------------------------------------------------------------|
| `read`     | Public reads on private datasets / private schemas                  | `/w/:workspace_slug/p/:project_slug/v1/data/query/*` (flat alias `/v1/data/query/*`), `/media` |
| `write`    | Mutations (create, patch, publish, unpublish, delete)               | `POST /w/:workspace_slug/p/:project_slug/v1/data/mutate/:dataset` (flat alias `POST /v1/data/mutate/:dataset`), `POST /media/upload` |
| `ops`      | Operate the Bokbasen publish pipeline (read-only on plugin secrets) | `/admin/bokbasen` LiveView                                   |
| `admin`    | All of the above + plugin-settings reveal/audit + schema CRUD       | `/studio/settings`, `/v1/schemas/*`, `/v1/plugins/settings/*`, `/v1/webhooks/*`, `/v1/plugins/onixedit/export/*` |

### Hierarchy

`admin` is a **superset** of every other permission. Granting `admin`
grants `ops` (and `read` + `write` for routes that check those plugs).
The `BarkparkWeb.LiveAuth.:ops` hook accepts either `ops` or `admin`,
which means existing admin tokens keep working unchanged when an
`ops`-gated route is added (Phase 8 WI5 backwards-compat).

### Why `:ops` is separate from `:admin`

The Bokbasen publish console (`/admin/bokbasen`, Phase 7 WI6) needs to
be operated by people who should *not* be able to read the encrypted
Bokbasen `client_secret` (which is what `/studio/settings` exposes via
the plugin-secret reveal flow). Splitting `ops` out lets a publishing
operator see submission status, retry failed jobs, and inspect last
errors — without ever holding the `admin` permission.

## LiveView `on_mount` hooks

```elixir
# api/lib/barkpark_web/live_auth.ex
on_mount :admin   # → requires "admin"
on_mount :ops     # → requires "ops" OR "admin"
```

Both halt with a flash + redirect to `/studio` when the session token
is missing, malformed, or lacks the required permission.

## Plug pipelines (HTTP)

```elixir
# api/lib/barkpark_web/router.ex
pipeline :require_token  # → BarkparkWeb.Plugs.RequireToken
pipeline :require_admin  # → RequireToken + RequireAdmin
```

There is no `require_ops` plug today — the only ops surface is a
LiveView, so the `on_mount` gate is sufficient. Add a plug here if
HTTP-only operator endpoints land.

## Dev token

`barkpark-dev-token` (seeded in `priv/repo/seeds.exs`) carries
`["read", "write", "admin"]` and is bound to the `Default` workspace
(with a `workspace_memberships` row), so it satisfies every gate in this
document and works on both the scoped and flat-alias routes. Production
deployments should issue narrower tokens per persona (publisher gets
`ops`; everyone else gets `read`/`write` without `admin` or `ops`), each
bound to the workspace its principal belongs to.
