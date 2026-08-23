<!-- doc-tier: agent | canonical-for: auth-tokens-roles | budget: 1400tok -->
# Auth & roles

Barkpark uses bearer-token API tokens (`Authorization: Bearer <token>`)
backed by `api_tokens` (SHA256 hash + permission list per token).
Browser LiveViews read the same token from `session["api_token"]` via
`BarkparkWeb.LiveAuth` `on_mount` hooks.

> User accounts, sessions, MFA, login tickets, field encryption/
> visibility, and row ownership are the **core-auth model** — see
> [docs/auth-user-sessions.md](auth-user-sessions.md) (canonical-for
> core-auth-model).

## Tenancy — token ↔ workspace

The request principal is the API token; every token binds to exactly one
**workspace** (the tenancy boundary — hierarchy: `docs/api-v1.md` §1a). The binding is two facts that must agree:

- `api_tokens.workspace_id` — the workspace the token belongs to.
- a `workspace_memberships` row — the principal is a member of it.

Content/data requests carry the workspace + project in the path
(`/w/:workspace_slug/p/:project_slug/v1/data/...`). The server resolves
both from the path and enforces tenancy **before** any permission check:

| Situation | Result |
|---|---|
| `:workspace_slug` doesn't resolve | `404 not_found` |
| Workspace resolves, token has no `workspace_memberships` row for it | `403 forbidden` |
| Workspace resolves, token is a member | proceed to permission checks |

### Write gate

The mutate endpoint (`POST …/v1/data/mutate/:dataset`) enforces `write`
**after** tenancy passes. A valid member lacking `write` gets
`403 forbidden` on mutate; reads remain available.

### Default workspace + flat alias

Flat content paths (`/v1/data/:dataset/*`, etc.) resolve to the `"Default"`
workspace/project; the dev token below is a `Default` member.

## Roles (permissions list on `ApiToken.permissions`)

| Permission | Grants | Surfaces |
|---|---|---|
| `read` | Public reads on private datasets / private schemas | `/w/:ws/p/:proj/v1/data/query/*` (flat alias `/v1/data/query/*`), `/media` |
| `write` | Mutations (create, patch, publish, unpublish, delete) | `POST /w/:ws/p/:proj/v1/data/mutate/:dataset` (flat alias `POST /v1/data/mutate/:dataset`) |
| `public-read` | Anonymous-equivalent GET-only reads | Query/media reads; strict-list match when `permissions == ["public-read"]` exactly (`public_read.ex:53-58`); also satisfies `:read` (`tenancy/auth.ex:27`). Minted by `mix barkpark.rotate_public_read` (weekly) or `POST …/v1/tokens` (site-spawner) |
| `chat` | Drive `/v1/chat` sessions owned by THIS workspace | `/v1/chat/*`; 403 fail-closed if the token is unbound; minted only by `create_chat_token/3`, which hardcodes `["chat"]` |
| `ops` | Operate the Bokbasen publish pipeline (read-only on plugin secrets) | `/admin/onixedit/bokbasen` LiveView (old `/admin/bokbasen` 301-redirects here) |
| `admin` | All of the above + plugin-settings reveal/audit + schema CRUD | `/studio/settings`, `/v1/schemas/*`, `/v1/plugins/settings/*`, `/v1/webhooks/*`, `/v1/plugins/onixedit/export/*` |

> **Media upload** (`POST /media/upload`, `POST /v1/media/:dataset/upload`) needs a valid
> token (bearer or session) but **not** `write` — the `:media_mutate` /
> `:scoped_media_mutate` pipelines omit `RequireWritePermission`.

### Hierarchy

`admin` is a **superset** of every other permission. Granting `admin`
grants `ops` (and `read` + `write`); `:ops`
stays separate because Bokbasen operators need submission status/retry/errors
but must not read the encrypted `client_secret` `/studio/settings` exposes.

But `admin` is **workspace-blind**: `RequireAdmin` takes no workspace
argument, so `:require_admin` gates WHO may call a verb, never WHICH
tenant — slug-resolving routes must also prove
`Tenancy.Auth.workspace_admin?/2` in the action.

`admin` must never enter the hardcoded `chat` literal: `RequireChatAccess`
resolves `admin` to `:global`, stamping `owner_workspace_id = NULL` and
reopening the tenant-less-session bug (`chat_token_controller.ex:29-32`).

## LiveView `on_mount` hooks

```elixir
# api/lib/barkpark_web/live_auth.ex
on_mount :admin   # → requires "admin"
on_mount :ops     # → requires "ops" OR "admin"
```

Both halt with a flash + redirect to `/studio` when the session token
is missing, malformed, or under-permissioned.

## Plug pipelines (HTTP)

```elixir
# api/lib/barkpark_web/router.ex
pipeline :require_token   # → RequireToken
pipeline :require_admin   # → RequireToken + RequireAdmin
pipeline :flat_admin_api  # → RequireToken → DeriveWorkspaceFromToken
                          #   → AssignDefaultScope → RequireAdmin
```

Mount every **flat** (`/v1/…`) admin route on `:flat_admin_api`, which
*replaces* `:api`. On `[:api, :require_admin]`, `AssignDefaultScope` stamps
`current_workspace = Default` before the admin gate, so callers from every
workspace converge on Default — answering `200` against the wrong tenant.

**Order is the fix, and the wrong order fails silently.**
`DeriveWorkspaceFromToken` is no-op-if-set, so appending it *after*
`AssignDefaultScope` is a pure no-op. `FlatAdminTenancyTest` reds on a swap.

## Dev token

`barkpark-dev-token` (seeded by the `demo` profile — `Barkpark.Seeds.Demo`;
`clean` mints none) carries `["read", "write", "admin"]`, bound to the
`Default` workspace (with a `workspace_memberships` row), so it satisfies
every gate here on scoped and flat-alias routes.

**MUST rotate before prod** — starter templates bake `barkpark-dev-token`
into `BARKPARK_TOKEN` and `BARKPARK_SERVER_TOKEN`; replace **both** with
freshly-issued tokens before deploying.
