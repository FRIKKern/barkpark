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

/** Envelope returned by GET /api/workspaces. */
export interface ListWorkspacesEnvelope {
  workspaces: Workspace[]
}

/** Envelope returned by GET /api/workspaces/:slug/projects. */
export interface ListProjectsEnvelope {
  workspace: Workspace
  projects: Project[]
}

/**
 * List the workspaces the configured token can reach.
 *
 * Calls `GET /api/workspaces` — a top-level tenancy endpoint, so the path is
 * neither dataset-scoped nor `scopePrefix`-prefixed. Returns the typed
 * `workspaces` array unwrapped from the `{ workspaces }` envelope.
 * Prefer `client.listWorkspaces()`.
 */
export async function listWorkspaces(config: BarkparkClientConfig): Promise<Workspace[]> {
  const { data } = await request<ListWorkspacesEnvelope>(config, '/api/workspaces', {
    kind: 'read',
  })
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
): Promise<Project[]> {
  if (typeof workspaceSlug !== 'string' || workspaceSlug.length === 0) {
    throw new BarkparkValidationError('listProjects requires a workspace slug', {
      field: 'workspaceSlug',
    })
  }
  const { data } = await request<ListProjectsEnvelope>(
    config,
    `/api/workspaces/${encodeURIComponent(workspaceSlug)}/projects`,
    { kind: 'read' },
  )
  return data?.projects ?? []
}
