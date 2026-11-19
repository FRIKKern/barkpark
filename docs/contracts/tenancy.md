<!-- doc-tier: agent | canonical-for: tenancy-model | budget: 2000tok -->
# Tenancy — workspace · project · dataset · membership

How Barkpark's **API layer** isolates data across tenants and scopes every read/write; cloud-side team/barkpark object authz is `docs/contracts/cloud-object-authz.md`. Code: `api/lib/barkpark/tenancy/` (schemas, `Barkpark.Tenancy`, `Tenancy.Auth`) and `api/lib/barkpark/content/scope.ex` (the data-layer scope).

## The hierarchy

```
Workspace ──< Project ──< Dataset
   │
   └──< Membership (binds a principal + role)
```

| Entity | Boundary | Slug uniqueness | Table |
|---|---|---|---|
| **Workspace** | the **hard tenant boundary** — owns Projects + Memberships | global | `workspaces` |
| **Project** | under exactly one Workspace | per-workspace | `projects` |
| **Dataset** | under exactly one Project; promotes the legacy `dataset` *string* into a row | per-project | `datasets` |
| **Membership** | binds a principal (`principal_type` ∈ `api_token · user`) to a Workspace with a role | one per `(workspace, principal_type, principal_id)` | `workspace_memberships` |

Workspace + Project slugs match `^[a-z0-9][a-z0-9-]*$` and exclude reserved prefixes `admin api _plugins studio login media v1 w p`, enforced by the **changeset** (`validate_exclusion`), not the router.

## The context — `Barkpark.Tenancy`

All tenant mutation goes through `api/lib/barkpark/tenancy.ex`; never insert/delete these rows directly:

- **`create_workspace_with_owner/2`** — one transaction: workspace + owner Membership + Default project + production Dataset. The only correct way to stand up a tenant.
- **`create_project_with_dataset/2`** — atomic project + production dataset.
- **`get_or_create_dataset/2`** — idempotent (`on_conflict: :nothing` on `(project_id, slug)`); reloads for the persisted id.
- **`list_workspaces_for/1`** — INNER JOIN on memberships: only the principal's workspaces; unknown → `[]`.
- **`multi_tenant?/0`** — true when >1 workspace exists; **fail-closed** (rescues to `true`), flipping stricter scoping on.
- **`resolve_scope_slugs/2`** — `{workspace_id, project_id}` → `{ws_slug, project_slug}`, falling back to `"default"` for a nil/stale id.

### Safe delete — NEVER `Repo.delete/1` on a Workspace

Use only **`Tenancy.delete_workspace/1`**. Scope FKs `CASCADE`, so `Repo.delete(workspace)` skips the blob/CDN purge + lifecycle hooks. In order: (1) `media_files` → `Media.delete_file/2` (blob, CDN, renditions, hooks); (2) `documents` → `Content.delete_document/4` (delete hooks); (3) `Repo.delete(workspace)`, CASCADE prunes the rest; (4) its chats (`chat_sessions.owner_workspace_id`, no FK) + messages; NULL-owned chats stay. No `delete_project/1` yet.

## Roles & enforcement

Roles live on the **membership row** (`workspace_memberships.role` ∈ `owner · admin · member · contributor`, `membership.ex` `@roles`; `contributor` writes drafts, never publishes: `Auth.publish_refused?/2`). The membership role — not global permissions — decides workspace-admin authority (`Tenancy.Auth.workspace_admin?/2`, true for `owner`/`admin`), so a globally-privileged token added elsewhere is a `member` there, **not** admin. `create_membership/4` defaults to `member`; only `create_workspace_with_owner/2` (`owner`) and token-mint (`Auth.create_token`) grant higher. Seated members read the role names a seat may hold: `GET …/v1/workspace/roles` (`Auth.valid_role_names/1`).

**Role ceiling (ruling #5).** Via `Tenancy.Members` (`actor:`) only an `owner` grants, changes or removes `owner` (`403 owner_required`); a token seat holds an admin-authority role only if the token has `admin` (`403 role_exceeds_token`).

**Access requests** (`Tenancy.AccessRequests`). A user (session/owned token) asks: `POST /v1/auth/access-requests {workspace, note?, role?}` → `202`, alike if the slug exists (missing: NULL `workspace_id`, unseen by admins); a member: `409` unless `role` outranks theirs. 5/h/user, 1 pending/slug. Admins approve (`…/:id/approve {role}`, via `Members.add_user_member/4`/`update_role/4`, ceiling holds; a seat changed since, even gained, is `409 request_stale`) or deny; both audited (`membership`).

**Two role axes (GR46).** The roles above are the *only* team-role vocabulary; every settings gate reads it. `platform_operator` is **not** a team role but the *platform* principal: a fail-closed boolean off the `:platform_admin_emails` allowlist (`Notifications.platform_admin_emails/0`) gating the Operator entry, `/v1/operator/*` and `bp cloud rollout`. **Supporter** is a billing *plan*, never a role.

Action → permission: `:read` ← `read|admin|public-read`; `:write` ← `write|admin`; `:admin` ← `admin`. A nil `permissions` column **denies** (guarded `is_list`), never raises. `Tenancy.Auth`'s read predicates (`membership/2` … `authorize/3`) are **total**: a malformed or absent id **denies**, never raises (ruling + widening: `Tenancy.Auth` moduledoc).

## Data-layer scoping

Canonical scope helpers in `api/lib/barkpark/content/scope.ex`:

- **`scope_to_workspace/3`** — **fail-closed**: a `nil` workspace_id compiles to `where: false`, never an all-rows query. Binary id → `WHERE workspace_id = $1` (`AND project_id = $2` when given).
- **`scope_to_workspace_global/1`** — explicit, greppable cross-tenant opt-in; used by surfaces not yet path-scoped.
- **`scope_to_workspace_or_global/3`** — back-compat bridge for flat routes: nil → global, binary → the fail-closed form.
- **Shared schemas** — plugin schemas install with `workspace_id` NULL; `get_schema/3` falls back to one when the workspace owns none by that name.
- **`maybe_scope_to_grants/2`** — the one owner of grant (Layer-2) row-narrowing: a no-op unless `opts[:grant_scoped]`, else `scope_to_grants/3` over the caller's grants (undecidable → `where: false`). Serves every grant-aware read (`Content.Query`, `DocumentsRetriever`, Indx hydration, `Content.Graph` backlinks).

Multi-tenant installs project content edges with strict `scope_to_workspace/3`, never the `_or_global` bridge.

### The dataset string↔id duality (in-progress migration)

The plain `dataset` string (`"production"` default) is still authoritative; `dataset_id` rides alongside as the uniqueness key (`documents (doc_id, type, dataset_id)`). `dataset_id` is **nullable everywhere**; its FKs `CASCADE`, but a NULL row escapes, so delete a Dataset only via `delete_dataset/2` (`Tenancy.DatasetDelete`; refuses `production`).

`Barkpark.Content.WriteScope.scope_to_dataset/3` is the **never-worse** read scope (`content/write_scope.ex`; not on the `Content` facade):

```
resolve_read_dataset_id(dataset, opts) → id | nil
  id  → WHERE dataset_id = $id OR (dataset_id IS NULL AND dataset = $string)
  nil → WHERE dataset = $string
```

An un-backfilled NULL-`dataset_id` row stays visible to dataset scoping (string path), not to strict `scope_to_workspace/3` with a nil workspace_id.

**Known asymmetry:** `resolve_read_dataset_id/2` returns `nil` when scoped by workspace **without** a project (string-path fallback, no cross-tenant bleed into the Default project); id-precise scoping needs `project_id`.

## Tables & constraints

`UNIQUE`: `workspaces(slug)` · `projects(workspace_id, slug)` · `workspace_memberships(workspace_id, principal_type, principal_id)` · `datasets(project_id, slug)`. Parent FKs (project/membership/dataset) are `ON DELETE CASCADE`, and so are content/scope tables' nullable `workspace_id`/`project_id`/`dataset_id` FKs; only `audit_events` + `audit_export_sinks` carry `workspace_id` with no FK. The column is `dataset` on content tables (`documents`, `revisions`, `media_files`, `schema_definitions`, `webhooks`, `api_tokens`, `mutation_events`), `scope` on search-intel tables. Imports never carry `workspace_access_requests`; people ask again.

## Canonical homes (link, don't duplicate)

| Fact | Canonical owner |
|---|---|
| Auth enforcement: token↔workspace binding, plug chain (`OptionalToken → ResolveWorkspace → ResolveProject`), 404/403 table, write gate | `docs/auth.md` |
| HTTP API: scoped/flat URL shapes, hierarchy summary | `docs/api-v1.md` §1a |

> No workspace/project delete **verb** (API/CLI) yet: `docs/decisions/deferred.md`.
