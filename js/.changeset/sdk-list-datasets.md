---
'@barkpark/core': minor
---

**Added:** `client.listDatasets(workspaceSlug, projectSlug)` — list the datasets under a project (`GET /api/workspaces/:ws/projects/:proj/datasets`). Completes the tenancy drill-down alongside `listWorkspaces()` / `listProjects()` (workspaces → projects → datasets); the endpoint + CLI `bp workspace dataset-ls` shipped in #728. New `Dataset` + `ListDatasetsEnvelope` types.
