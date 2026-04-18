import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import {
  TEST_BASE_URL,
  TEST_DATASET,
  TEST_API_VERSION,
  resetFixtures,
} from './fixtures/handlers'
import { createClient } from '../src/client'
import type { BarkparkClient, BarkparkClientConfig, BarkparkDocument, MetaResponse } from '../src/types'

const baseConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: TEST_API_VERSION,
  token: 'test-token',
}

// Runtime extension exposed by createClient but not in the public interface.
type ClientWithHandshake = BarkparkClient & {
  handshake(): Promise<MetaResponse>
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('BarkparkClient integration', () => {
  it('client.doc() returns a document from /v1/data/doc', async () => {
    const c = createClient(baseConfig)
    const d = await c.doc<BarkparkDocument>('post', 'p1')
    expect(d).toMatchObject({ _id: 'p1', _type: 'post', title: 'Hello World' })
  })

  it('client.doc() resolves to null on 404 (does not throw)', async () => {
    const c = createClient(baseConfig)
    const d = await c.doc('post', 'nonexistent')
    expect(d).toBeNull()
  })

  it('client.docs().where().find() returns filtered documents', async () => {
    const c = createClient(baseConfig)
    const docs = await c.docs<BarkparkDocument>('post').where('title', 'eq', 'Hello World').find()
    expect(docs.length).toBeGreaterThanOrEqual(1)
    expect(docs[0]).toMatchObject({ _type: 'post', title: 'Hello World' })
  })

  it('client.publish() promotes a draft and returns a publish MutateResult', async () => {
    const c = createClient(baseConfig)
    const result = await c.publish('p2', 'post')
    expect(result.operation).toBe('publish')
    expect(result.id).toBe('p2')
    expect(result.document._draft).toBe(false)
  })

  it('client.transaction() sends all mutations in one envelope and returns results', async () => {
    let seenBody: unknown = null
    server.use(
      http.post(`${TEST_BASE_URL}/v1/data/mutate/:ds`, async ({ request }) => {
        seenBody = await request.json()
        return HttpResponse.json(
          {
            transactionId: 'aabbccddeeff00112233445566778899',
            results: [
              {
                id: 'drafts.tx-new',
                operation: 'create',
                document: {
                  _id: 'drafts.tx-new',
                  _type: 'post',
                  _rev: 'r1',
                  _draft: true,
                  _publishedId: 'tx-new',
                  _createdAt: 'x',
                  _updatedAt: 'x',
                  title: 'Made by tx',
                },
              },
              {
                id: 'p1',
                operation: 'update',
                document: {
                  _id: 'p1',
                  _type: 'post',
                  _rev: 'r2',
                  _draft: false,
                  _publishedId: 'p1',
                  _createdAt: 'x',
                  _updatedAt: 'x',
                  title: 'Patched via tx',
                },
              },
            ],
          },
          { status: 200 },
        )
      }),
    )
    const c = createClient(baseConfig)
    const env = await c
      .transaction()
      .create({ _type: 'post', _id: 'drafts.tx-new', title: 'Made by tx' } as Partial<BarkparkDocument> & {
        _type: string
      })
      .patch('p1', (p) => p.set({ title: 'Patched via tx' }))
      .commit()
    expect((seenBody as { mutations: unknown[] }).mutations.length).toBe(2)
    expect(env.results.length).toBe(2)
    expect(env.results[0]!.operation).toBe('create')
    expect(env.results[1]!.operation).toBe('update')
  })

  it('client.patch().set().commit() sends an Idempotency-Key when retry=true', async () => {
    let seenIdempotency: string | null = null
    server.use(
      http.post(`${TEST_BASE_URL}/v1/data/mutate/:ds`, async ({ request }) => {
        seenIdempotency = request.headers.get('Idempotency-Key')
        return HttpResponse.json(
          {
            transactionId: 'aabbccddeeff00112233445566778899',
            results: [
              {
                id: 'p1',
                operation: 'update',
                document: {
                  _id: 'p1',
                  _type: 'post',
                  _rev: 'newrev',
                  _draft: false,
                  _publishedId: 'p1',
                  _createdAt: 'x',
                  _updatedAt: 'x',
                  title: 'patched',
                },
              },
            ],
          },
          { status: 200 },
        )
      }),
    )
    const c = createClient(baseConfig)
    const result = await c.patch('p1').set({ title: 'patched' }).commit({ retry: true, idempotencyKey: 'fixed-key-123' })
    expect(result.operation).toBe('update')
    expect(seenIdempotency).toBe('fixed-key-123')
  })

  it('client.listen() yields welcome then mutation events from SSE', async () => {
    const c = createClient(baseConfig)
    const handle = c.listen<BarkparkDocument>('post')
    const events: Array<{ type: string; documentId?: string }> = []
    const iter = handle[Symbol.asyncIterator]()
    try {
      for (let i = 0; i < 2; i++) {
        const { value, done } = await iter.next()
        if (done) break
        events.push({ type: value.type, ...(value.documentId ? { documentId: value.documentId } : {}) })
      }
    } finally {
      handle.unsubscribe()
    }
    expect(events[0]?.type).toBe('welcome')
    expect(events[1]?.type).toBe('mutation')
    expect(events[1]?.documentId).toBe('drafts.live-x1')
  })

  it('client.handshake() dedupes concurrent callers (single network hit)', async () => {
    let metaHits = 0
    server.use(
      http.get(`${TEST_BASE_URL}/v1/meta`, () => {
        metaHits++
        return HttpResponse.json(
          {
            minApiVersion: '2026-04-01',
            maxApiVersion: TEST_API_VERSION,
            serverTime: '2026-04-18T00:00:00.000Z',
            currentDatasetSchemaHash: 'abc1234567890def',
          } satisfies MetaResponse,
          { status: 200, headers: { 'x-request-id': 'req_meta_dedup' } },
        )
      }),
    )
    const c = createClient(baseConfig) as ClientWithHandshake
    const [m1, m2, m3] = await Promise.all([c.handshake(), c.handshake(), c.handshake()])
    expect(metaHits).toBe(1) // inflight dedup: 3 concurrent callers → 1 fetch
    expect(m1).toBe(m2)
    expect(m2).toBe(m3)
    // Subsequent resolved call is also served from cache (no new hit).
    const m4 = await c.handshake()
    expect(metaHits).toBe(1)
    expect(m4).toBe(m1)
  })
})
