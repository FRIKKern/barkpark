<!-- doc-tier: agent | canonical-for: auth-tokens-roles | budget: 1400tok -->
# Auth & roles

Bearer API tokens (`Authorization: Bearer <token>`) backed by `api_tokens`
(SHA256 hash + permission list); LiveViews read `session["api_token_session"]`
via `on_mount`.

> Accounts, sessions, MFA, login tickets, field visibility, row ownership:
> [auth-user-sessions.md](auth-user-sessions.md).

## Tenancy — token ↔ workspace

The principal is the API token; each binds to one **workspace** (tenancy boundary;
hierarchy: `docs/api-v1.md` §1a) by two facts that must agree:

- `api_tokens.workspace_id` — the workspace the token belongs to.
- a `workspace_memberships` row — the principal is a member of it.

Requests carry both in the path
(`/w/:workspace_slug/p/:project_slug/v1/data/...`); tenancy is enforced
**before** any permission check: slug unresolved → `404 not_found`; resolved but
no `workspace_memberships` row for the token → `403 forbidden`, reason
`not_a_member`, naming the workspace (`bp whoami` lists seats); member → on to
permission checks. Flat paths (`/v1/data/:dataset/*`, …) resolve to the `"Default"` scope.

Mutate needs `write` after tenancy (else `403`). Minted with an explicit
`dataset` (`dataset_bound`), a token gets `403 dataset_not_bound` elsewhere;
unbound, `dataset` binds nothing.

## Roles (`ApiToken.permissions`)

| Permission | Grants | Surfaces |
|---|---|---|
| `read` | Reads on private datasets / schemas | `…/v1/data/query/*` `/media` |
| `write` | Mutations (create/patch/publish/unpublish/delete) | `POST …/v1/data/mutate/:dataset` |
| `public-read` | Anonymous-equivalent GET-only reads | Membership, `"public-read" in permissions` (`PublicRead`), not list equality; also satisfies `:read`. Mint: `mix barkpark.rotate_public_read` / `POST …/v1/tokens` |
| `chat` | Drive `/v1/chat` sessions of THIS workspace | `/v1/chat/*`; 403 if unbound; minted only by `create_chat_token/3` |
| `ops` | Operate the Bokbasen publish pipeline | `/admin/onixedit/bokbasen` |
| `admin` | The above + plugin-settings reveal/audit + schema CRUD | `/studio/settings`, `/v1/schemas/*`, `/v1/plugins/settings/*`, `/v1/webhooks/*` |

> **Media upload** (`POST /media/upload`, `POST /v1/media/:dataset/upload`) needs
> a token, **not** `write`: `:media_mutate`/`:scoped_media_mutate` omit `RequireWritePermission`.

### Hierarchy — permission ⟂ membership

`admin` is a superset on the PERMISSION axis ONLY (`admin` ⊃
`ops` ⊃ `read`+`write`; `:ops` stays separate so Bokbasen operators never see the
encrypted `client_secret`) and confers **no membership anywhere**.

Three tiers (seat rule since ruling #2, 2026-10-03):
`RequireAdmin`: `admin` permission, plus admin authority in the token's
workspace (bound token) or its owner's (workspace-less PAT); a workspace-less
machine token needs no seat. `Tenancy.Auth.authorize/3`: seat AND
`permissions` AND the seat role (and a PAT owner's role) allow the action, so
demotion bites at once. `workspace_admin?/2`: the membership ROLE alone.

**The bug class:** gate on `has_permission?(_, "admin")`, then act
per-workspace off `current_workspace` — which `AssignDefaultScope` stamps as
*Default*, so every tenant's admin gets a `200` against the wrong tenant. The mirror (gate on membership, act instance-wide) is the
same defect. A flat admin route pins the
GLOBAL tier explicitly (`SecretController.resolve_scope/1` → `:global`, never
the assign); acting per-workspace needs a slug-resolving route proving
`workspace_admin?/2`.

`admin` must never enter the hardcoded `chat` literal: `RequireChatAccess`
resolves it to `:global`, stamping `owner_workspace_id = NULL`
(`ChatTokenController`).

**Tier 0 — instance operator** (`RequirePlatformOperator`): `admin` plus an
env allowlist; see [instance-operator-tier.md](contracts/instance-operator-tier.md).

## Minting `write`/`admin`

Only `POST …/v1/tokens/elevated` (`Auth.mint_delegated_token/3`) mints them:
caller has flat `admin` AND an admin seat, gets at most its own set; seated,
audited `token_minted`. `bp token create --permissions read,write,admin`.
`bp token rotate` refuses Cloud's credential (label `barkpark cloud admin`)
without `--force`.

## LiveView `on_mount` hooks

`live_auth.ex`: `:admin` → `"admin"`; `:ops` → `"ops"` or `"admin"`;
`:scoped_admin` → `workspace_admin?/2` on the URL's workspace (membership axis);
all halt with a flash + redirect to `/studio`.
`paper_viewer.ex` `:viewer` (paper readers): never halts; assigns
`:current_user`/`:api_token`/`:viewer` + fail-closed `:can_edit?` (`authorize/3`
`:write`, in `BulldocsLive.mount/3`).

## Plug pipelines (HTTP)

`router.ex`: `:require_token` → RequireToken; `:require_admin` adds RequireAdmin;
`:flat_admin_api` → RequireToken → DeriveWorkspaceFromToken → AssignDefaultScope
→ RequireAdmin; `:require_platform_operator` → RequirePlatformOperator, THIRD
on `[:api, :require_admin]` (instance-global only).

Mount every **flat** (`/v1/…`) admin route on `:flat_admin_api`, which
*replaces* `:api` — `[:api, :require_admin]` is where the convergence above
bites. `DeriveWorkspaceFromToken` is no-op-if-set, so placing it *after*
`AssignDefaultScope` silently does nothing; `FlatAdminTenancyTest` reds on a swap.

## Dev token

`barkpark-dev-token` (seeded by the `demo` profile; `clean` mints none) carries
`["read","write","admin"]` AND a `Default` `workspace_memberships` row, so it
passes every gate.
**MUST rotate before prod** — starter templates bake it into `BARKPARK_TOKEN`
and `BARKPARK_SERVER_TOKEN`; replace **both**.
