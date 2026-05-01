# Auth & roles

Barkpark uses bearer-token API tokens (`Authorization: Bearer <token>`)
backed by `api_tokens` (SHA256 token hash + permission list per token).
Browser LiveViews read the same token from `session["api_token"]` via the
`BarkparkWeb.LiveAuth` `on_mount` hooks.

## Roles (permissions list on `ApiToken.permissions`)

| Permission | Grants                                                              | Surfaces                                                     |
|------------|---------------------------------------------------------------------|--------------------------------------------------------------|
| `read`     | Public reads on private datasets / private schemas                  | `/v1/data/query/*`, `/media`                                 |
| `write`    | Mutations (create, patch, publish, unpublish, delete)               | `POST /v1/data/mutate/:dataset`, `POST /media/upload`        |
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
`["read", "write", "admin"]` and therefore satisfies every gate in
this document. Production deployments should issue narrower tokens
per persona (publisher gets `ops`; everyone else gets `read`/`write`
without `admin` or `ops`).
