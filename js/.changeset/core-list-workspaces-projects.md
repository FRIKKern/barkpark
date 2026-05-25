---
"@barkpark/core": minor
---

Add workspace/project scope config + scopePrefix + listWorkspaces/listProjects to @barkpark/core.

`createClient` now accepts optional `workspace` / `project` slugs; when both are
set, every operation is prefixed with `/w/<workspace>/p/<project>` via the new
`scopePrefix` helper (flat `/v1/...` paths remain the back-compat default).

Two new top-level tenancy methods round out the client:

- `client.listWorkspaces()` → `GET /api/workspaces`, returns the workspaces the
  token can reach.
- `client.listProjects(workspaceSlug)` → `GET /api/workspaces/:slug/projects`,
  returns that workspace's projects.

Both endpoints are top-level (not dataset-scoped, not `scopePrefix`-prefixed) and
share the existing auth/baseURL/transport plumbing. New `Workspace` / `Project`
types are exported.
