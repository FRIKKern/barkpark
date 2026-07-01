// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Tenancy listing — top-level workspace/project enumeration.
//
// These endpoints are NOT dataset-scoped and NOT prefixed with
// scopePrefix(config): they sit above the per-project surface and answer
// "which workspaces/projects can this token reach?". The server exposes:
//   GET /api/workspaces                       → { workspaces: [{id,slug,name}] }
//   GET /api/workspaces/:workspace_slug/projects → { workspace, projects: [...] }
// (committed to api/main, task sj6z). The Bearer token scopes the result to the
// caller's member workspaces; auth/baseURL plumbing is shared with every other
// read via transport.request().

import type { BarkparkClientConfig } from './types'
import { request } from './transport'
import { BarkparkValidationError } from './errors'

/** A workspace the token can reach (GET /api/workspaces). */
export interface Workspace {
  id: string
  slug: string
  name: string
}

/** A project under a workspace (GET /api/workspaces/:slug/projects). */
export interface Project {
  id: string
  slug: string
  name: string
}

/** A dataset under a project (GET /api/workspaces/:ws/projects/:proj/datasets). */
export interface Dataset {
  id: string
  slug: string
  name: string
}

/** Envelope returned by GET /api/workspaces. */
export interface ListWorkspacesEnvelope {
  workspaces: Workspace[]
}

/** Envelope returned by GET /api/workspaces/:slug/projects. */
export interface ListProjectsEnvelope {
  workspace: Workspace
  projects: Project[]
}

/** Envelope returned by GET /api/workspaces/:ws/projects/:proj/datasets. */
export interface ListDatasetsEnvelope {
  workspace: Workspace
  project: Project
  datasets: Dataset[]
}

/** Attributes accepted by POST /api/workspaces. */
export interface CreateWorkspaceInput {
  name: string
  slug?: string
}

/** Attributes accepted by POST /api/workspaces/:slug/projects. */
export interface CreateProjectInput {
  name: string
  slug?: string
}

/** Envelope returned by POST /api/workspaces. */
export interface CreateWorkspaceEnvelope {
  workspace: Workspace
}

/** Envelope returned by POST /api/workspaces/:slug/projects. */
export interface CreateProjectEnvelope {
  project: Project
}

/**
 * List the workspaces the configured token can reach.
 *
 * Calls `GET /api/workspaces` — a top-level tenancy endpoint, so the path is
 * neither dataset-scoped nor `scopePrefix`-prefixed. Returns the typed
 * `workspaces` array unwrapped from the `{ workspaces }` envelope.
 * Prefer `client.listWorkspaces()`.
 */
export async function listWorkspaces(
  config: BarkparkClientConfig,
  opts?: { signal?: AbortSignal },
): Promise<Workspace[]> {
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<ListWorkspacesEnvelope>(config, '/api/workspaces', reqOpts)
  return data?.workspaces ?? []
}

/**
 * List the projects under a workspace.
 *
 * Calls `GET /api/workspaces/:workspace_slug/projects` — top-level tenancy
 * endpoint (not dataset-scoped, not `scopePrefix`-prefixed). Returns the typed
 * `projects` array unwrapped from the `{ workspace, projects }` envelope.
 * Prefer `client.listProjects(workspaceSlug)`.
 */
export async function listProjects(
  config: BarkparkClientConfig,
  workspaceSlug: string,
  opts?: { signal?: AbortSignal },
): Promise<Project[]> {
  if (typeof workspaceSlug !== 'string' || workspaceSlug.length === 0) {
    throw new BarkparkValidationError('listProjects requires a workspace slug', {
      field: 'workspaceSlug',
    })
  }
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<ListProjectsEnvelope>(
    config,
    `/api/workspaces/${encodeURIComponent(workspaceSlug)}/projects`,
    reqOpts,
  )
  return data?.projects ?? []
}

/**
 * List the datasets under a project.
 *
 * Calls `GET /api/workspaces/:workspace_slug/projects/:project_slug/datasets` —
 * top-level tenancy endpoint (not dataset-scoped, not `scopePrefix`-prefixed).
 * Returns the typed `datasets` array unwrapped from the
 * `{ workspace, project, datasets }` envelope. Completes the tenancy drill-down
 * (workspaces → projects → datasets). Prefer `client.listDatasets(ws, proj)`.
 */
export async function listDatasets(
  config: BarkparkClientConfig,
  workspaceSlug: string,
  projectSlug: string,
  opts?: { signal?: AbortSignal },
): Promise<Dataset[]> {
  if (typeof workspaceSlug !== 'string' || workspaceSlug.length === 0) {
    throw new BarkparkValidationError('listDatasets requires a workspace slug', {
      field: 'workspaceSlug',
    })
  }
  if (typeof projectSlug !== 'string' || projectSlug.length === 0) {
    throw new BarkparkValidationError('listDatasets requires a project slug', {
      field: 'projectSlug',
    })
  }
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<ListDatasetsEnvelope>(
    config,
    `/api/workspaces/${encodeURIComponent(workspaceSlug)}/projects/${encodeURIComponent(projectSlug)}/datasets`,
    reqOpts,
  )
  return data?.datasets ?? []
}

/**
 * Create a workspace.
 *
 * Calls `POST /api/workspaces` with `{ name, slug? }` — a top-level tenancy
 * endpoint, so the path is neither dataset-scoped nor `scopePrefix`-prefixed.
 * Returns the created `Workspace` unwrapped from the `{ workspace }` envelope.
 * Token-authed via the shared Bearer plumbing. Prefer `client.createWorkspace(attrs)`.
 */
export async function createWorkspace(
  config: BarkparkClientConfig,
  attrs: CreateWorkspaceInput,
  opts?: { signal?: AbortSignal },
): Promise<Workspace> {
  if (typeof attrs?.name !== 'string' || attrs.name.length === 0) {
    throw new BarkparkValidationError('createWorkspace: name is required', { field: 'name' })
  }
  const reqOpts: { kind: 'write'; method: 'POST'; body: unknown; signal?: AbortSignal } = {
    kind: 'write',
    method: 'POST',
    body: attrs,
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<CreateWorkspaceEnvelope>(config, '/api/workspaces', reqOpts)
  if (!data?.workspace) {
    throw new BarkparkValidationError('createWorkspace: server returned no workspace', {
      field: 'workspace',
    })
  }
  return data.workspace
}

/**
 * Create a project under a workspace.
 *
 * Calls `POST /api/workspaces/:workspace_slug/projects` with `{ name, slug? }` —
 * top-level tenancy endpoint (not dataset-scoped, not `scopePrefix`-prefixed).
 * Returns the created `Project` unwrapped from the `{ project }` envelope.
 * Token-authed via the shared Bearer plumbing. Prefer `client.createProject(workspaceSlug, attrs)`.
 */
export async function createProject(
  config: BarkparkClientConfig,
  workspaceSlug: string,
  attrs: CreateProjectInput,
  opts?: { signal?: AbortSignal },
): Promise<Project> {
  if (typeof workspaceSlug !== 'string' || workspaceSlug.length === 0) {
    throw new BarkparkValidationError('createProject requires a workspace slug', {
      field: 'workspaceSlug',
    })
  }
  if (typeof attrs?.name !== 'string' || attrs.name.length === 0) {
    throw new BarkparkValidationError('createProject: name is required', { field: 'name' })
  }
  const reqOpts: { kind: 'write'; method: 'POST'; body: unknown; signal?: AbortSignal } = {
    kind: 'write',
    method: 'POST',
    body: attrs,
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<CreateProjectEnvelope>(
    config,
    `/api/workspaces/${encodeURIComponent(workspaceSlug)}/projects`,
    reqOpts,
  )
  if (!data?.project) {
    throw new BarkparkValidationError('createProject: server returned no project', {
      field: 'project',
    })
  }
  return data.project
}
