<!-- doc-tier: agent | canonical-for: auth-tokens-roles | budget: 1400tok -->
# Auth & roles

Bearer tokens (`Authorization: Bearer <token>`) in `api_tokens`;
LiveViews read `session["api_token_session"]`
(or `session["api_token"]`) via `on_mount`.

> Accounts, sessions, MFA, login tickets, field visibility, row ownership:
> [auth-user-sessions.md](auth-user-sessions.md).

## Tenancy — token ↔ workspace

The principal is the API token, bound to one workspace (`docs/api-v1.md` §1a) by two agreeing facts: `api_tokens.workspace_id`
and its `workspace_memberships` row.

The path carries both
(`/w/:workspace_slug/p/:project_slug/v1/data/...`); tenancy is checked
before permissions: slug unresolved → `404 not_found`; no seat → `403 forbidden`
`not_a_member` naming the workspace (`bp whoami` lists seats). Flat paths (`/v1/data/:dataset/*`) resolve to `"Default"`.

Mutate and any `:scoped_admin` write need `write` (or 403). A token bound to a
`dataset` (`dataset_bound`; old `bp` mints: re-mint) gets `403 dataset_not_bound`
elsewhere, on workspace/project create, playground, import. Admin reads/writes (audit,
export, seats, grants, shares, tokens, chat hosts, secrets, workspace
delete/archive/restore/reinstate; not self-revoke): audited; 403 on
`:dataset_bound_admin_reads` `:enforce`.

## Roles (`ApiToken.permissions`)

| Permission | Grants | Surfaces |
|---|---|---|
| `read` | Reads on private datasets/schemas | `…/v1/data/query/*` `/media` |
| `write` | Mutations | `POST …/v1/data/mutate/:dataset` |
| `public-read` | Anonymous-level GET reads | `"public-read" in permissions` (`PublicRead`), not list equality; also satisfies `:read`. Mint: `mix barkpark.rotate_public_read` / `POST …/v1/tokens` |
| `chat` | Drive `/v1/chat` sessions of THIS workspace | `/v1/chat/*`; 403 if unbound; minted only by `create_chat_token/3` |
| `ops` | Bokbasen publishing | `/admin/onixedit/bokbasen` (old `/admin/bokbasen` 301s) |
| `admin` | The above + plugin-settings reveal/audit, secrets + webhooks (both tiers), flat schema CRUD (scoped: `write` + admin seat) | `/studio/settings`, `/v1/schemas/*`, `/v1/plugins/settings/*`, `/v1/secrets/*`, `/v1/webhooks/*` |

> **Media upload** (`POST /media/upload`, `POST /v1/media/:dataset/upload`) needs
> a token, not `write`: `:media_mutate`/`:scoped_media_mutate` omit `RequireWritePermission`.

### Hierarchy — permission ⟂ membership

`admin` is a superset on the PERMISSION axis ONLY (`admin` ⊃
`ops`, `read`, `write`; `ops` (no `read`/`write`) is separate so Bokbasen
operators never see `client_secret`) and confers **no membership**.

Three tiers:
`RequireAdmin`: `admin` permission plus admin authority in the bound token's
workspace or a workspace-less PAT owner's; a workspace-less
machine token needs no seat. `Tenancy.Auth.authorize/3`: seat AND
`permissions` AND the seat role (and a PAT owner's) allow it. `workspace_admin?/2`: the ROLE alone.

**The bug class:** gate on `has_permission?(_, "admin")`, then act
per-workspace off `current_workspace` (`AssignDefaultScope` stamps *Default*):
every tenant's admin gets `200` on the wrong tenant. So is the mirror (gate
on membership, act instance-wide). A flat admin route pins the
GLOBAL tier (`SecretController.resolve_scope/1` → `:global`, never the assign);
acting per-workspace needs a slug-resolving route proving `workspace_admin?/2`.

`admin` must never enter the `chat` literal: `RequireChatAccess`
resolves it to `:global`, stamping `owner_workspace_id = NULL`
(`ChatTokenController`).

**Tier 0: instance operator** (`RequirePlatformOperator`): `admin` plus an
env allowlist once set (flat `/v1/secrets` too); [instance-operator-tier.md](contracts/instance-operator-tier.md).

## Minting `write`/`admin`

`POST …/v1/tokens/elevated` (`Auth.mint_delegated_token/3`), the only HTTP `admin` mint (offline: `admin-token` recovery and the seeds):
caller has flat `admin` AND an admin seat, gets at most its own set; seated,
audited `token_minted`.
`bp -w acme token create ci --permissions read,write --dataset staging`.
`bp token rotate` needs `--force` on Cloud's credential
(label `barkpark cloud admin`).
Self-mint caps a PAT at `read` (member) or `read`+`write`
(owner/admin), never `admin`; the seat
writes ([sessions](auth-user-sessions.md)).

## LiveView `on_mount` hooks

`live_auth.ex`: `:admin` → `"admin"`; `:ops` → `"ops"` or `"admin"`;
`:scoped_admin` → `workspace_admin?/2` on the URL's workspace (membership axis);
all halt: flash + redirect to `/studio`.
`paper_viewer.ex` `:viewer`: never halts; assigns
`:current_user`/`:api_token`/`:viewer` + fail-closed `:can_edit?` (`authorize/3`
`:write`, in `BulldocsLive.mount/3`).

## Plug pipelines (HTTP)

`router.ex`: `:require_token` → RequireToken; `:require_admin` adds RequireAdmin;
`:flat_admin_api` → RequireToken → DeriveWorkspaceFromToken → AssignDefaultScope
→ RequireAdmin; `:require_platform_operator` → RequirePlatformOperator, THIRD
on `[:api, :require_admin]` (instance-global only).

Mount every flat (`/v1/…`) admin route on `:flat_admin_api`, which
replaces `:api`: `[:api, :require_admin]` hits the bug class above.
`DeriveWorkspaceFromToken` is no-op-if-set: *after*
`AssignDefaultScope` it does nothing; `FlatAdminTenancyTest` reds on a swap.

## Dev token

`barkpark-dev-token` (seeded by `demo`; `clean` mints none outside dev) carries
`["read","write","admin"]` AND a `Default` `workspace_memberships` row;
passes every gate.
**MUST rotate before prod**: starter templates bake it into `BARKPARK_TOKEN`
and `BARKPARK_SERVER_TOKEN`; replace both.
