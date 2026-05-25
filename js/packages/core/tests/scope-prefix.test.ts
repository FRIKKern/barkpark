// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// w1-s12: verify listen() + handshake() prepend scopePrefix(config) to their
// /v1/... paths when workspace + project are both set, and stay flat otherwise
// (back-compat). The prefix is computed via the exported scopePrefix.

import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest'
import { http, HttpResponse, delay } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createListenHandle } from '../src/listen'
import { createHandshakeCache } from '../src/handshake'
import type { BarkparkClientConfig, ListenEvent } from '../src/types'

const flatConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
  token: 'test-token',
}

const scopedConfig: BarkparkClientConfig = {
  ...flatConfig,
  workspace: 'acme',
  project: 'blog',
}

const SCOPE = '/w/acme/p/blog'

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

function sseHandler(seen: { path: string | null }) {
  return ({ request }: { request: Request }) => {
    seen.path = new URL(request.url).pathname
    const stream = new ReadableStream<Uint8Array>({
      async start(controller) {
        const enc = new TextEncoder()
        controller.enqueue(enc.encode(`event: welcome\ndata: ${JSON.stringify({ type: 'welcome' })}\n\n`))
        await delay(2)
        controller.close()
      },
    })
    return new HttpResponse(stream, {
      status: 200,
      headers: { 'content-type': 'text/event-stream' },
    })
  }
}

describe('scopePrefix wiring — listen', () => {
  it('scopes the SSE listen URL when workspace + project are set', async () => {
    const seen: { path: string | null } = { path: null }
    server.use(http.get(`${TEST_BASE_URL}${SCOPE}/v1/data/listen/:dataset`, sseHandler(seen)))

    const events: ListenEvent[] = []
    const handle = createListenHandle(scopedConfig, 'post', undefined, { maxReconnects: 0 })
    for await (const evt of handle) {
      events.push(evt)
      break
    }
    handle.unsubscribe()

    expect(seen.path).toBe(`${SCOPE}/v1/data/listen/${TEST_DATASET}`)
  })

  it('keeps the SSE listen URL flat when workspace/project are absent (back-compat)', async () => {
    const seen: { path: string | null } = { path: null }
    server.use(http.get(`${TEST_BASE_URL}/v1/data/listen/:dataset`, sseHandler(seen)))

    const events: ListenEvent[] = []
    const handle = createListenHandle(flatConfig, 'post', undefined, { maxReconnects: 0 })
    for await (const evt of handle) {
      events.push(evt)
      break
    }
    handle.unsubscribe()

    expect(seen.path).toBe(`/v1/data/listen/${TEST_DATASET}`)
  })
})

describe('scopePrefix wiring — handshake', () => {
  it('scopes the /v1/meta handshake URL when workspace + project are set', async () => {
    const seen: { path: string | null } = { path: null }
    server.use(
      http.get(`${TEST_BASE_URL}${SCOPE}/v1/meta`, ({ request }) => {
        seen.path = new URL(request.url).pathname
        return HttpResponse.json(
          {
            minApiVersion: '2026-04-01',
            maxApiVersion: '2026-04-17',
            serverTime: '2026-04-18T00:00:00.000Z',
            currentDatasetSchemaHash: '0123456789abcdef',
          },
          { status: 200, headers: { 'x-request-id': 'req_meta_scoped' } },
        )
      }),
    )

    const cache = createHandshakeCache()
    await cache.get(scopedConfig)

    expect(seen.path).toBe(`${SCOPE}/v1/meta`)
  })

  it('keeps the /v1/meta handshake URL flat when workspace/project are absent (back-compat)', async () => {
    const seen: { path: string | null } = { path: null }
    server.use(
      http.get(`${TEST_BASE_URL}/v1/meta`, ({ request }) => {
        seen.path = new URL(request.url).pathname
        return HttpResponse.json(
          {
            minApiVersion: '2026-04-01',
            maxApiVersion: '2026-04-17',
            serverTime: '2026-04-18T00:00:00.000Z',
            currentDatasetSchemaHash: '0123456789abcdef',
          },
          { status: 200, headers: { 'x-request-id': 'req_meta_flat' } },
        )
      }),
    )

    const cache = createHandshakeCache()
    await cache.get(flatConfig)

    expect(seen.path).toBe('/v1/meta')
  })
})
