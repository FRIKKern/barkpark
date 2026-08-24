// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Regression pin for gh-8100: `@barkpark/core` patches never reached the server.
//
// `/v1/data/mutate` dispatches a patch on `%{"patch" => %{"id" => id, "type" => type}}`
// (api/lib/barkpark/content/mutations.ex) and falls through to `{:error, :malformed}`
// when `type` is absent — so a patch op without `type` is a guaranteed 400, for every
// caller, on every document. api-v1.md §6 documents `type` as part of the op.
//
// These tests read the bytes actually put on the wire rather than trusting a mocked
// result, so a handler that happily accepts a typeless body cannot make them pass.

import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import {
  TEST_API_VERSION,
  TEST_BASE_URL,
  TEST_DATASET,
  TEST_TX_ID,
  resetFixtures,
} from './fixtures/handlers'
import { createPatch } from '../src/patch'
import { createTransaction } from '../src/transaction'
import type { ApiVersion, BarkparkClientConfig, MutateEnvelope } from '../src/types'

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

const config: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: TEST_API_VERSION as ApiVersion,
  token: 'test-token',
}

/**
 * Capture the raw request body of the next mutate call. The handler replies with a
 * minimal-but-valid envelope so the SDK's own parsing does not mask what was sent.
 */
function captureMutateBody(): { body: () => Record<string, unknown> } {
  let captured: Record<string, unknown> | undefined
  server.use(
    http.post(`${TEST_BASE_URL}/v1/data/mutate/:dataset`, async ({ request }) => {
      captured = (await request.json()) as Record<string, unknown>
      const env: MutateEnvelope = {
        transactionId: TEST_TX_ID,
        results: [
          {
            id: 'p1',
            operation: 'update',
            document: {
              _id: 'p1',
              _type: 'post',
              _rev: 'ffffffffffffffffffffffffffffffff',
              _draft: false,
              _publishedId: 'p1',
              _createdAt: '2026-04-18T00:00:00.000Z',
              _updatedAt: '2026-04-18T00:00:00.000Z',
            },
          },
        ],
      }
      return HttpResponse.json(env, { status: 200 })
    }),
  )
  return {
    body: () => {
      if (captured === undefined) throw new Error('mutate endpoint was never called')
      return captured
    },
  }
}

function firstPatchOp(body: Record<string, unknown>): Record<string, unknown> {
  const mutations = body['mutations'] as Array<Record<string, unknown>> | undefined
  expect(Array.isArray(mutations)).toBe(true)
  const op = mutations![0]
  expect(op).toBeDefined()
  expect(Object.prototype.hasOwnProperty.call(op!, 'patch')).toBe(true)
  return op!['patch'] as Record<string, unknown>
}

describe('patch ops carry `type` on the wire (gh-8100)', () => {
  it('createPatch(...).commit() sends type alongside id', async () => {
    const cap = captureMutateBody()
    await createPatch(config, 'p1', 'post').set({ title: 'New' }).commit()

    const patch = firstPatchOp(cap.body())
    // The assertion the bug would fail: the key must be PRESENT, not merely undefined.
    expect(Object.prototype.hasOwnProperty.call(patch, 'type')).toBe(true)
    expect(patch['type']).toBe('post')
    expect(patch['id']).toBe('p1')
  })

  it('keeps type on a composed Phase-1B patch (setIfMissing/unset/inc/append)', async () => {
    const cap = captureMutateBody()
    await createPatch(config, 'p1', 'book')
      .set({ title: 'New' })
      .setIfMissing({ lang: 'en' })
      .unset(['draftNote'])
      .inc({ views: 1 })
      .append('tags', ['x'])
      .commit()

    const patch = firstPatchOp(cap.body())
    expect(patch['type']).toBe('book')
  })

  it('transaction().patch() sends type alongside id', async () => {
    const cap = captureMutateBody()
    await createTransaction(config)
      .patch('p1', 'post', (b) => b.set({ title: 'changed' }))
      .commit()

    const patch = firstPatchOp(cap.body())
    expect(Object.prototype.hasOwnProperty.call(patch, 'type')).toBe(true)
    expect(patch['type']).toBe('post')
  })

  it('a typed patch is accepted by the shared fixture handler, which matches on _type', async () => {
    // No override: the default handler in fixtures/handlers.ts looks the document up by
    // `_id` AND `_type`, exactly as the server does. Before the fix this 404'd, which is
    // why integration-smoke.test.ts had to install a workaround handler.
    const result = await createPatch(config, 'p1', 'post').set({ title: 'Typed' }).commit()
    expect(result.document._id).toBe('p1')
    expect(result.document._type).toBe('post')
    expect(result.document['title']).toBe('Typed')
  })
})
