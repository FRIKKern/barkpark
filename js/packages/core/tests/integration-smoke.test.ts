// SPDX-License-Identifier: Apache-2.0
// End-to-end smoke: drive the full public barrel through one lifecycle.
// Intentionally imports from '../src' (the barrel), NOT '../src/client',
// so the test fails if index.ts forgets to re-export something.

import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import {
  TEST_BASE_URL,
  TEST_DATASET,
  TEST_TX_ID,
  resetFixtures,
} from './fixtures/handlers'
import * as Barkpark from '../src'
import type { ApiVersion, BarkparkClientConfig, MutateEnvelope } from '../src'

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

const BASE_CONFIG: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-01' as ApiVersion,
  token: 'integration-smoke-token',
}

describe('integration smoke (public barrel)', () => {
  it('full lifecycle via createClient: doc → docs → patch → publish', async () => {
    // Override `patch` mutation handler — client.patch(id) omits `type`, but the
    // shared default handler requires it. Override with a spy that just returns
    // an update MutateResult for whichever id the client sends.
    server.use(
      http.post(`${TEST_BASE_URL}/v1/data/mutate/:dataset`, async ({ request }) => {
        const body = (await request.json()) as {
          mutations: Array<Record<string, unknown>>
        }
        const m = body.mutations[0] as Record<string, unknown> | undefined
        if (m && 'patch' in m) {
          const p = m['patch'] as { id: string; set: Record<string, unknown> }
          const env: MutateEnvelope = {
            transactionId: TEST_TX_ID,
            results: [
              {
                id: p.id,
                operation: 'update',
                document: {
                  _id: p.id,
                  _type: 'post',
                  _rev: 'deadbeefdeadbeefdeadbeefdeadbeef',
                  _draft: false,
                  _publishedId: p.id,
                  _createdAt: '2026-04-18T00:00:00Z',
                  _updatedAt: '2026-04-18T00:00:00Z',
                  ...p.set,
                },
              },
            ],
          }
          return HttpResponse.json(env, { status: 200 })
        }
        if (m && 'publish' in m) {
          const pub = m['publish'] as { id: string; type: string }
          const env: MutateEnvelope = {
            transactionId: TEST_TX_ID,
            results: [
              {
                id: pub.id,
                operation: 'publish',
                document: {
                  _id: pub.id,
                  _type: pub.type,
                  _rev: 'aaaabbbbccccddddeeeeffff00001111',
                  _draft: false,
                  _publishedId: pub.id,
                  _createdAt: '2026-04-18T00:00:00Z',
                  _updatedAt: '2026-04-18T00:00:00Z',
                },
              },
            ],
          }
          return HttpResponse.json(env, { status: 200 })
        }
        return HttpResponse.json(
          { error: { code: 'malformed', message: 'smoke-override: unexpected op' } },
          { status: 400 },
        )
      }),
    )

    const client = Barkpark.createClient(BASE_CONFIG)
    expect(client.config.dataset).toBe(TEST_DATASET)

    // doc (seeded as p1 / type post in default handlers)
    const post = await client.doc('post', 'p1')
    expect(post).toMatchObject({ _id: 'p1', _type: 'post' })

    // docs (list query)
    const docs = await client.docs('post').limit(5).find()
    expect(Array.isArray(docs)).toBe(true)
    expect(docs.length).toBeGreaterThan(0)

    // patch (override spy returns update)
    const patchRes = await client.patch('p1').set({ title: 'barrel-smoke' }).commit()
    expect(patchRes.operation).toBe('update')
    expect(patchRes.id).toBe('p1')

    // publish (override spy returns publish)
    const pubRes = await client.publish('p2', 'post')
    expect(pubRes.operation).toBe('publish')
    expect(pubRes.id).toBe('p2')

    // withConfig returns a distinct client
    const client2 = client.withConfig({ perspective: 'drafts' })
    expect(client2).not.toBe(client)
    expect(client2.config.perspective).toBe('drafts')
  })

  it('barrel re-exports every error class + factory name', () => {
    // Value exports
    const expectedValues = [
      'createClient',
      'createHandshakeCache',
      'createPatch',
      'createTransaction',
      'createDocsOperation',
      'getDoc',
      'publishDoc',
      'unpublishDoc',
      'fetchRawDoc',
      'createListenHandle',
      'createDocsBuilder',
      'makeFilterExpression',
      'buildQueryString',
      'BarkparkError',
      'BarkparkAPIError',
      'BarkparkAuthError',
      'BarkparkConflictError',
      'BarkparkEdgeRuntimeError',
      'BarkparkHmacError',
      'BarkparkNetworkError',
      'BarkparkNotFoundError',
      'BarkparkRateLimitError',
      'BarkparkSchemaMismatchError',
      'BarkparkTimeoutError',
      'BarkparkValidationError',
    ] as const

    const mod = Barkpark as unknown as Record<string, unknown>
    for (const name of expectedValues) {
      expect(mod[name], `missing barrel export: ${name}`).toBeDefined()
    }
  })
})
