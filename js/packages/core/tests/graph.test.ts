import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createClient } from '../src/client'
import type { BarkparkClientConfig } from '../src/types'

const baseConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
  token: 'tok',
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('getGraph / getOrphans / getDangling', () => {
  it('getGraph GETs /v1/graph/:id (global, no scope) with dataset + traversal opts', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/graph/:id`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({
          ok: true,
          root: 'p1',
          nodes: [{ _id: 'p1', _type: 'post' }],
          edges: [{ from_id: 'p1', to_id: 'a1', kind: 'references' }],
          dependents: [],
          truncated: false,
          truncation_reason: null,
        })
      }),
    )
    const g = await createClient(baseConfig).getGraph('p1', {
      depth: 3,
      direction: 'out',
      kinds: ['references', 'embeds'],
      perspective: 'drafts',
    })
    expect(g.root).toBe('p1')
    expect(g.edges[0]!.kind).toBe('references')
    const url = new URL(seenUrl)
    expect(url.pathname).toBe('/v1/graph/p1')
    expect(url.searchParams.get('dataset')).toBe(TEST_DATASET)
    expect(url.searchParams.get('depth')).toBe('3')
    expect(url.searchParams.get('direction')).toBe('out')
    expect(url.searchParams.get('kinds')).toBe('references,embeds')
    expect(url.searchParams.get('perspective')).toBe('drafts')
  })

  it('getGraph inherits the client perspective (drafts), and an explicit opt overrides it', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/graph/:id`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({
          ok: true,
          root: 'p1',
          nodes: [{ _id: 'p1', _type: 'post' }],
          edges: [],
          dependents: [],
          truncated: false,
          truncation_reason: null,
        })
      }),
    )
    // A client configured for drafts traverses drafts without a per-call opt.
    const drafts = createClient(baseConfig).withConfig({ perspective: 'drafts' })
    await drafts.getGraph('p1')
    expect(new URL(seenUrl).searchParams.get('perspective')).toBe('drafts')

    // Config 'published' (the server default) is not forwarded.
    const published = createClient(baseConfig).withConfig({ perspective: 'published' })
    await published.getGraph('p1')
    expect(new URL(seenUrl).searchParams.get('perspective')).toBe(null)

    // A client 'raw' perspective is NOT forwarded (graph only supports published/drafts).
    const raw = createClient(baseConfig).withConfig({ perspective: 'raw' })
    await raw.getGraph('p1')
    expect(new URL(seenUrl).searchParams.get('perspective')).toBe(null)

    // An explicit per-call opt wins over the client config.
    await drafts.getGraph('p1', { perspective: 'published' })
    expect(new URL(seenUrl).searchParams.get('perspective')).toBe('published')
  })

  it('getGraph throws BarkparkValidationError for an out-of-range/non-integer depth', async () => {
    const client = createClient(baseConfig)
    for (const bad of [0, 6, 2.5, NaN]) {
      await expect(client.getGraph('p1', { depth: bad })).rejects.toMatchObject({
        code: 'BarkparkValidationError',
        field: 'depth',
      })
    }
  })

  it('getGraph does not throw for depth 1 and 5', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/graph/:id`, () =>
        HttpResponse.json({
          ok: true,
          root: 'p1',
          nodes: [{ _id: 'p1', _type: 'post' }],
          edges: [],
          dependents: [],
          truncated: false,
          truncation_reason: null,
        }),
      ),
    )
    const client = createClient(baseConfig)
    for (const good of [1, 5]) {
      const g = await client.getGraph('p1', { depth: good })
      expect(g.root).toBe('p1')
    }
  })

  it('getOrphans GETs /v1/graph/orphans?dataset and unwraps the array', async () => {
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/graph/orphans`, ({ request }) => {
        seenUrl = request.url
        return HttpResponse.json({ ok: true, orphans: [{ _id: 'lonely', _type: 'post' }] })
      }),
    )
    const orphans = await createClient(baseConfig).getOrphans()
    expect(orphans).toHaveLength(1)
    expect(orphans[0]!._id).toBe('lonely')
    expect(new URL(seenUrl).searchParams.get('dataset')).toBe(TEST_DATASET)
  })

  it('getDangling GETs /v1/graph/dangling?dataset and unwraps the array', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/graph/dangling`, () =>
        HttpResponse.json({
          ok: true,
          dangling: [{ from_id: 'p1', to_id: 'gone', kind: 'references' }],
        }),
      ),
    )
    const dangling = await createClient(baseConfig).getDangling()
    expect(dangling[0]!.to_id).toBe('gone')
  })

  it('getOrphans returns [] when the key is absent', async () => {
    server.use(http.get(`${TEST_BASE_URL}/v1/graph/orphans`, () => HttpResponse.json({ ok: true })))
    expect(await createClient(baseConfig).getOrphans()).toEqual([])
  })
})
