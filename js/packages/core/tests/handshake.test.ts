// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// createHandshakeCache keys entries on projectUrl+workspace+project+dataset —
// the full scope the /v1/meta request URL is built from. Two configs sharing
// projectUrl+dataset but differing in workspace/project hit DIFFERENT endpoints
// (distinct schema hashes) and must NOT collide on one cache entry; otherwise
// the second caller silently gets the first scope's meta, corrupting
// schema-drift detection.

import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createHandshakeCache } from '../src/handshake'
import type { BarkparkClientConfig } from '../src/types'

const flatConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
  token: 'test-token',
}

// Two scopes that share projectUrl + dataset but differ ONLY in workspace/project.
const scopeA: BarkparkClientConfig = { ...flatConfig, workspace: 'acme', project: 'blog' }
const scopeB: BarkparkClientConfig = { ...flatConfig, workspace: 'globex', project: 'site' }

function metaHandler(prefix: string, hash: string, seen: string[]) {
  return http.get(`${TEST_BASE_URL}${prefix}/v1/meta`, ({ request }) => {
    seen.push(new URL(request.url).pathname)
    return HttpResponse.json(
      {
        minApiVersion: '2026-04-01',
        maxApiVersion: '2026-04-17',
        serverTime: '2026-04-18T00:00:00.000Z',
        currentDatasetSchemaHash: hash,
      },
      { status: 200, headers: { 'x-request-id': `req_meta_${hash}` } },
    )
  })
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('createHandshakeCache — scope-aware cache key', () => {
  it('does NOT collide two configs that differ only in workspace/project', async () => {
    const seen: string[] = []
    server.use(
      metaHandler('/w/acme/p/blog', 'aaaaaaaaaaaaaaaa', seen),
      metaHandler('/w/globex/p/site', 'bbbbbbbbbbbbbbbb', seen),
    )

    const cache = createHandshakeCache()
    const metaA = await cache.get(scopeA)
    const metaB = await cache.get(scopeB)

    // Each scope hits its OWN /v1/meta endpoint (two distinct requests) and gets
    // its OWN schema hash back — no cross-scope cache leak.
    expect(seen).toEqual(['/w/acme/p/blog/v1/meta', '/w/globex/p/site/v1/meta'])
    expect(metaA.currentDatasetSchemaHash).toBe('aaaaaaaaaaaaaaaa')
    expect(metaB.currentDatasetSchemaHash).toBe('bbbbbbbbbbbbbbbb')
  })

  it('still dedupes repeat gets within the SAME scope (one request, cached)', async () => {
    const seen: string[] = []
    server.use(metaHandler('/w/acme/p/blog', 'aaaaaaaaaaaaaaaa', seen))

    const cache = createHandshakeCache()
    const first = await cache.get(scopeA)
    const second = await cache.get(scopeA)

    expect(seen).toEqual(['/w/acme/p/blog/v1/meta'])
    expect(second).toBe(first) // resolved value is reused
  })

  it('invalidate() drops only the targeted scope, not a sibling scope', async () => {
    const seen: string[] = []
    server.use(
      metaHandler('/w/acme/p/blog', 'aaaaaaaaaaaaaaaa', seen),
      metaHandler('/w/globex/p/site', 'bbbbbbbbbbbbbbbb', seen),
    )

    const cache = createHandshakeCache()
    await cache.get(scopeA)
    await cache.get(scopeB)
    cache.invalidate(scopeA)

    // Re-getting scopeA refetches; scopeB stays cached (no third refetch of it).
    await cache.get(scopeA)
    await cache.get(scopeB)

    expect(seen).toEqual([
      '/w/acme/p/blog/v1/meta',
      '/w/globex/p/site/v1/meta',
      '/w/acme/p/blog/v1/meta',
    ])
  })
})
