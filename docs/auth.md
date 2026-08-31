<!-- doc-tier: agent | canonical-for: auth-tokens-roles | budget: 1400tok -->
# Auth & roles

Bearer API tokens (`Authorization: Bearer <token>`) backed by `api_tokens`
(SHA256 hash + permission list). LiveViews read it from `session["api_token"]`
via `BarkparkWeb.LiveAuth` `on_mount` hooks.

> Accounts, sessions, MFA, login tickets, field encryption/visibility and row
> ownership: the **core-auth model** —
> [docs/auth-user-sessions.md](auth-user-sessions.md) (core-auth-model).

## Tenancy — token ↔ workspace

The principal is the API token; each binds to one **workspace** (the tenancy
boundary — hierarchy: `docs/api-v1.md` §1a) by two facts that must agree:

- `api_tokens.workspace_id` — the workspace the token belongs to.
- a `workspace_memberships` row — the principal is a member of it.

Content/data requests carry both in the path
(`/w/:workspace_slug/p/:project_slug/v1/data/...`); tenancy is enforced
**before** any permission check:

| Situation | Result |
|---|---|
| `:workspace_slug` doesn't resolve | `404 not_found` |
| Resolves, no `workspace_memberships` row for the token | `403 forbidden` |
| Resolves, token is a member | proceed to permission checks |

Flat paths (`/v1/data/:dataset/*`, …) resolve to the `"Default"` scope.

`POST …/v1/data/mutate/:dataset` enforces `write` **after** tenancy: a member
lacking `write` gets `403`; reads remain available.

## Roles (`ApiToken.permissions`)

| Permission | Grants | Surfaces |
|---|---|---|
| `read` | Reads on private datasets / private schemas | `/w/:ws/p/:proj/v1/data/query/*` (flat alias `/v1/data/query/*`), `/media` |
| `write` | Mutations (create/patch/publish/unpublish/delete) | `POST /w/:ws/p/:proj/v1/data/mutate/:dataset` (flat alias `POST /v1/data/mutate/:dataset`) |
| `public-read` | Anonymous-equivalent GET-only reads | Strict-list match when `permissions == ["public-read"]` exactly (`public_read.ex:53-58`); also satisfies `:read`. Minted by `mix barkpark.rotate_public_read` or `POST …/v1/tokens` |
| `chat` | Drive `/v1/chat` sessions owned by THIS workspace | `/v1/chat/*`; 403 if the token is unbound; minted only by `create_chat_token/3` |
| `ops` | Operate the Bokbasen publish pipeline | `/admin/onixedit/bokbasen` (old `/admin/bokbasen` 301s) |
| `admin` | The above + plugin-settings reveal/audit + schema CRUD | `/studio/settings`, `/v1/schemas/*`, `/v1/plugins/settings/*`, `/v1/webhooks/*` |

> **Media upload** (`POST /media/upload`, `POST /v1/media/:dataset/upload`) needs
> a token but **not** `write` — `:media_mutate` / `:scoped_media_mutate` omit
> `RequireWritePermission`.

### Hierarchy — permission ⟂ membership

The two facts above are **orthogonal axes**, and `admin` is a superset on the
PERMISSION axis ONLY: `admin` ⊃ `ops` ⊃ `read`+`write` (`:ops` stays separate
so Bokbasen operators get submission status/retry/errors, not the encrypted
`client_secret`). It confers **no membership anywhere**.

Three tiers, never interchangeable — conflate two and you write the bug.
`RequireAdmin` (`require_admin.ex:16`): `permissions` ONLY, no membership.
`Tenancy.Auth.authorize/3` (`auth.ex:393`): member? AND the token's GLOBAL
`permissions`. `workspace_admin?/2` (`auth.ex:582`): the membership ROLE alone.
So a global-`admin` token with zero memberships passes `RequireAdmin` and
reaches the route while every `Tenancy.Auth` predicate denies it; one holding a
plain `member` row in B passes `authorize(_, B, :admin)` and correctly FAILS
`workspace_admin?(_, B)` — load-bearing, never unify (`auth.ex:74-82`,
`studio/studio_live_shares_test.exs:318-327`). Tier 2 READS membership, tier 1
does not: that near-miss is the footgun.

**The bug class:** gate on `has_permission?(_, "admin")`, then act
per-workspace off `current_workspace` — which `AssignDefaultScope` stamps as
*Default*, so every tenant's admin converges there and answers `200` against
the wrong tenant. The check is right; the INPUT is wrong. Mirrored (gate on
membership, act instance-wide) is the same defect. A flat admin route pins the
GLOBAL tier explicitly (`SecretController.resolve_scope/1` → `:global`, never
the assign); acting per-workspace needs a slug-resolving route proving
`workspace_admin?/2`.

`admin` must never enter the hardcoded `chat` literal: `RequireChatAccess`
resolves it to `:global`, stamping `owner_workspace_id = NULL` — the
tenant-less-session bug (`chat_token_controller.ex:29-32`).

## LiveView `on_mount` hooks

`live_auth.ex`: `:admin` → `"admin"`; `:ops` → `"ops"` or `"admin"`;
`:scoped_admin` → `workspace_admin?/2` on the URL's workspace (membership
axis). All halt with a flash + redirect to `/studio`.

## Plug pipelines (HTTP)

`router.ex`: `:require_token` → RequireToken; `:require_admin` adds RequireAdmin;
`:flat_admin_api` → RequireToken → DeriveWorkspaceFromToken → AssignDefaultScope
→ RequireAdmin.

Mount every **flat** (`/v1/…`) admin route on `:flat_admin_api`, which
*replaces* `:api` — `[:api, :require_admin]` is where the convergence above
bites. **Order is the fix and the wrong order fails silently:**
`DeriveWorkspaceFromToken` is no-op-if-set, so putting it *after*
`AssignDefaultScope` is a pure no-op. `FlatAdminTenancyTest` reds on a swap.

## Dev token

`barkpark-dev-token` (seeded by the `demo` profile; `clean` mints none)
carries `["read","write","admin"]` AND a `Default`
`workspace_memberships` row — both axes — so it satisfies every gate here.

**MUST rotate before prod** — starter templates bake it into `BARKPARK_TOKEN`
and `BARKPARK_SERVER_TOKEN`; replace **both**.
