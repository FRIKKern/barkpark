// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// w1: verify listWorkspaces()/listProjects() hit the top-level tenancy
// endpoints (GET /api/workspaces, GET /api/workspaces/:slug/projects) — NOT
// dataset-scoped, NOT scopePrefix-prefixed even when workspace/project are set —
// send the Bearer token, and unwrap the `{ workspaces }` / `{ projects }` envelope.

import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { listWorkspaces, listProjects, createWorkspace, createProject } from '../src/tenancy'
import { BarkparkValidationError } from '../src/errors'
import type { BarkparkClientConfig } from '../src/types'

const baseConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
  token: 'test-token',
}

const scopedConfig: BarkparkClientConfig = {
  ...baseConfig,
  workspace: 'acme',
  project: 'blog',
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('listWorkspaces', () => {
  it('GETs /api/workspaces (top-level, never scoped) and returns the workspaces array', async () => {
    let seenPath = ''
    let seenAuth: string | null = null
    server.use(
      http.get(`${TEST_BASE_URL}/api/workspaces`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        seenAuth = request.headers.get('authorization')
        return HttpResponse.json(
          {
            workspaces: [
              { id: 'w1', slug: 'acme', name: 'Acme' },
              { id: 'w2', slug: 'globex', name: 'Globex' },
            ],
          },
          { status: 200, headers: { 'x-request-id': 'req_ws_1' } },
        )
      }),
    )
    const out = await listWorkspaces(baseConfig)
    expect(seenPath).toBe('/api/workspaces')
    expect(seenAuth).toBe('Bearer test-token')
    expect(out).toEqual([
      { id: 'w1', slug: 'acme', name: 'Acme' },
      { id: 'w2', slug: 'globex', name: 'Globex' },
    ])
  })

  it('stays at /api/workspaces even when workspace + project are configured (not scopePrefix-prefixed)', async () => {
    let seenPath = ''
    server.use(
      http.get(`${TEST_BASE_URL}/api/workspaces`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json({ workspaces: [] }, { status: 200 })
      }),
    )
    await listWorkspaces(scopedConfig)
    expect(seenPath).toBe('/api/workspaces')
  })

  it('returns [] when the envelope omits workspaces', async () => {
    server.use(http.get(`${TEST_BASE_URL}/api/workspaces`, () => HttpResponse.json({}, { status: 200 })))
    expect(await listWorkspaces(baseConfig)).toEqual([])
  })
})

describe('listProjects', () => {
  it('GETs /api/workspaces/:slug/projects and returns the projects array', async () => {
    let seenPath = ''
    server.use(
      http.get(`${TEST_BASE_URL}/api/workspaces/:slug/projects`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json(
          {
            workspace: { id: 'w1', slug: 'acme', name: 'Acme' },
            projects: [
              { id: 'p1', slug: 'blog', name: 'Blog' },
              { id: 'p2', slug: 'docs', name: 'Docs' },
            ],
          },
          { status: 200, headers: { 'x-request-id': 'req_proj_1' } },
        )
      }),
    )
    const out = await listProjects(baseConfig, 'acme')
    expect(seenPath).toBe('/api/workspaces/acme/projects')
    expect(out).toEqual([
      { id: 'p1', slug: 'blog', name: 'Blog' },
      { id: 'p2', slug: 'docs', name: 'Docs' },
    ])
  })

  it('stays top-level even when the client config carries a different scope', async () => {
    let seenPath = ''
    server.use(
      http.get(`${TEST_BASE_URL}/api/workspaces/:slug/projects`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json({ workspace: {}, projects: [] }, { status: 200 })
      }),
    )
    await listProjects(scopedConfig, 'globex')
    expect(seenPath).toBe('/api/workspaces/globex/projects')
  })

  it('throws BarkparkValidationError on an empty workspace slug', async () => {
    await expect(listProjects(baseConfig, '')).rejects.toBeInstanceOf(BarkparkValidationError)
  })

  it('returns [] when the envelope omits projects', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/api/workspaces/:slug/projects`, () =>
        HttpResponse.json({ workspace: { id: 'w1', slug: 'acme', name: 'Acme' } }, { status: 200 }),
      ),
    )
    expect(await listProjects(baseConfig, 'acme')).toEqual([])
  })
})

describe('createWorkspace', () => {
  it('POSTs /api/workspaces with the body and unwraps { workspace }', async () => {
    let seenPath = ''
    let seenMethod = ''
    let seenAuth: string | null = null
    let seenBody: unknown = undefined
    server.use(
      http.post(`${TEST_BASE_URL}/api/workspaces`, async ({ request }) => {
        seenPath = new URL(request.url).pathname
        seenMethod = request.method
        seenAuth = request.headers.get('authorization')
        seenBody = await request.json()
        return HttpResponse.json(
          { workspace: { id: 'w9', slug: 'acme', name: 'Acme' } },
          { status: 201, headers: { 'x-request-id': 'req_ws_create_1' } },
        )
      }),
    )
    const out = await createWorkspace(baseConfig, { name: 'Acme', slug: 'acme' })
    expect(seenPath).toBe('/api/workspaces')
    expect(seenMethod).toBe('POST')
    expect(seenAuth).toBe('Bearer test-token')
    expect(seenBody).toEqual({ name: 'Acme', slug: 'acme' })
    expect(out).toEqual({ id: 'w9', slug: 'acme', name: 'Acme' })
  })

  it('stays at /api/workspaces even when workspace + project are configured', async () => {
    let seenPath = ''
    server.use(
      http.post(`${TEST_BASE_URL}/api/workspaces`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json({ workspace: { id: 'w9', slug: 'new', name: 'New' } }, { status: 201 })
      }),
    )
    await createWorkspace(scopedConfig, { name: 'New' })
    expect(seenPath).toBe('/api/workspaces')
  })
})

describe('createProject', () => {
  it('POSTs /api/workspaces/:slug/projects with the body and unwraps { project }', async () => {
    let seenPath = ''
    let seenMethod = ''
    let seenAuth: string | null = null
    let seenBody: unknown = undefined
    server.use(
      http.post(`${TEST_BASE_URL}/api/workspaces/:slug/projects`, async ({ request }) => {
        seenPath = new URL(request.url).pathname
        seenMethod = request.method
        seenAuth = request.headers.get('authorization')
        seenBody = await request.json()
        return HttpResponse.json(
          { project: { id: 'p9', slug: 'blog', name: 'Blog' } },
          { status: 201, headers: { 'x-request-id': 'req_proj_create_1' } },
        )
      }),
    )
    const out = await createProject(baseConfig, 'acme', { name: 'Blog', slug: 'blog' })
    expect(seenPath).toBe('/api/workspaces/acme/projects')
    expect(seenMethod).toBe('POST')
    expect(seenAuth).toBe('Bearer test-token')
    expect(seenBody).toEqual({ name: 'Blog', slug: 'blog' })
    expect(out).toEqual({ id: 'p9', slug: 'blog', name: 'Blog' })
  })

  it('encodes the workspace slug into the path', async () => {
    let seenPath = ''
    server.use(
      http.post(`${TEST_BASE_URL}/api/workspaces/:slug/projects`, ({ request }) => {
        seenPath = new URL(request.url).pathname
        return HttpResponse.json({ project: { id: 'p9', slug: 'docs', name: 'Docs' } }, { status: 201 })
      }),
    )
    await createProject(scopedConfig, 'glo bex', { name: 'Docs' })
    expect(seenPath).toBe('/api/workspaces/glo%20bex/projects')
  })

  it('throws BarkparkValidationError on an empty workspace slug', async () => {
    await expect(createProject(baseConfig, '', { name: 'X' })).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
  })
})
