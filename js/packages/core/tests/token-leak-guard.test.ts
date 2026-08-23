// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Permanent four-vector token-leak regression guard for @barkpark/core
// (arpss-js-core-token-serialize-redact, epic api-read-path-security-sweep).
//
// The auth token rides every request. This guard asserts that a token set on a
// client NEVER surfaces through the four leak vectors the JS-SDK secret-handling
// audit enumerated:
//   V1 TOKEN IN ERROR      — a thrown/rejected error's serialization + .cause chain
//   V2 TOKEN IN LOG        — util.inspect(client) (what console.log/inspectors emit)
//   V3 TOKEN IN STATE      — JSON.stringify(client) (the RSC/SSR/devtools path)
//   V4 TOKEN IN URL        — the request URL (proxies/servers log query+path)
// and that the redaction does NOT break auth: token stays ENUMERABLE, direct
// config.token access returns the real value, and a withConfig-derived client
// keeps a working token while still redacting its serialization.
//
// V3 is the confirmed live leak this guard was cut for: createClient exposes the
// frozen config as client.config with token a plain enumerable string, so
// JSON.stringify(client) emitted the raw token until the redacting toJSON hook
// (client.ts freeze site) landed. The guard is RED without that hook.

import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { inspect } from 'node:util'
import { http, HttpResponse } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, resetFixtures } from './fixtures/handlers'
import { createClient } from '../src/client'
import type { BarkparkClientConfig } from '../src/types'

// A distinctive sentinel so an accidental substring match is unambiguous.
const SENTINEL = 'sk_secret_SENTINEL_2f9a7c'

const baseConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
  token: SENTINEL,
}

// Fully serialize a thrown error the way a consumer's logger / Sentry would:
// message, name, stack, every enumerable own field, and the whole .cause chain.
function serializeError(err: unknown): string {
  const parts: string[] = []
  let cur: unknown = err
  let guard = 0
  while (cur !== undefined && cur !== null && guard < 20) {
    guard += 1
    if (cur instanceof Error) {
      parts.push(String(cur.message), String(cur.name), String(cur.stack ?? ''))
      // enumerable own fields (e.g. url, status, body, requestId)
      parts.push(JSON.stringify(cur, Object.getOwnPropertyNames(cur)))
      cur = (cur as { cause?: unknown }).cause
    } else {
      parts.push(String(cur))
      try {
        parts.push(JSON.stringify(cur))
      } catch {
        /* circular / non-serializable — the String() above already captured it */
      }
      break
    }
  }
  return parts.join('\n')
}

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('token-leak guard — V3 token in serialized state', () => {
  it('JSON.stringify(client) never contains the token, and redacts it to [REDACTED]', () => {
    const client = createClient(baseConfig)
    const json = JSON.stringify(client)
    expect(json).not.toContain(SENTINEL)
    expect(json).toContain('[REDACTED]')
  })

  it('JSON.stringify(client.config) never contains the token', () => {
    const client = createClient(baseConfig)
    expect(JSON.stringify(client.config)).not.toContain(SENTINEL)
  })
})

describe('token-leak guard — V2 token in log (inspect)', () => {
  it('util.inspect(client) never contains the token', () => {
    const client = createClient(baseConfig)
    // depth null so inspect fully descends into client.config
    expect(inspect(client, { depth: null })).not.toContain(SENTINEL)
  })

  it('util.inspect(client.config) never contains the token', () => {
    const client = createClient(baseConfig)
    expect(inspect(client.config, { depth: null })).not.toContain(SENTINEL)
  })
})

describe('token-leak guard — V1 token in error', () => {
  it('a thrown error from a failed request never carries the token in its serialization or cause chain', async () => {
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/doc/:dataset/:type/:doc_id`, () =>
        HttpResponse.json(
          { error: { code: 'invalid_token', message: 'token invalid' } },
          { status: 401, headers: { 'x-request-id': 'req_leak_401' } },
        ),
      ),
    )
    const client = createClient(baseConfig)
    let thrown: unknown
    try {
      await client.doc('post', 'p1')
    } catch (e) {
      thrown = e
    }
    expect(thrown).toBeDefined()
    expect(serializeError(thrown)).not.toContain(SENTINEL)
  })
})

describe('token-leak guard — V4 token in URL', () => {
  it('the token rides the Authorization header, never the request URL', async () => {
    let seenAuth: string | null = null
    let seenUrl = ''
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/doc/:dataset/:type/:doc_id`, ({ request }) => {
        seenAuth = request.headers.get('authorization')
        seenUrl = request.url
        return HttpResponse.json(
          { result: { _id: 'p1', _type: 'post', _rev: '1111111111111111111111111111aaaa' } },
          { status: 200, headers: { 'x-request-id': 'req_leak_url' } },
        )
      }),
    )
    const client = createClient(baseConfig)
    await client.doc('post', 'p1')
    expect(seenAuth).toBe(`Bearer ${SENTINEL}`)
    expect(seenUrl).not.toContain(SENTINEL)
  })
})

describe('token-leak guard — redaction does not break auth', () => {
  it('token stays enumerable and config.token returns the real value', () => {
    const client = createClient(baseConfig)
    expect(client.config.token).toBe(SENTINEL)
    // token must be an ENUMERABLE own property — withConfig()'s object spread
    // would silently drop a non-enumerable token and build a token-less client.
    expect(Object.keys(client.config)).toContain('token')
    expect(Object.prototype.propertyIsEnumerable.call(client.config, 'token')).toBe(true)
  })

  it('a withConfig-derived client keeps a working token AND redacts JSON.stringify', () => {
    const derived = createClient(baseConfig).withConfig({ apiVersion: '2026-05-01' })
    // auth intact through the spread
    expect(derived.config.token).toBe(SENTINEL)
    expect(derived.config.apiVersion).toBe('2026-05-01')
    // still redacted
    const json = JSON.stringify(derived)
    expect(json).not.toContain(SENTINEL)
    expect(json).toContain('[REDACTED]')
  })

  it('a withConfig-derived client sends the real token on the wire', async () => {
    let seenAuth: string | null = null
    server.use(
      http.get(`${TEST_BASE_URL}/v1/data/doc/:dataset/:type/:doc_id`, ({ request }) => {
        seenAuth = request.headers.get('authorization')
        return HttpResponse.json(
          { result: { _id: 'p1', _type: 'post', _rev: '1111111111111111111111111111aaaa' } },
          { status: 200, headers: { 'x-request-id': 'req_leak_derived' } },
        )
      }),
    )
    const derived = createClient(baseConfig).withConfig({ apiVersion: '2026-05-01' })
    await derived.doc('post', 'p1')
    expect(seenAuth).toBe(`Bearer ${SENTINEL}`)
  })
})

// The KNOWN edge of the V3 cover, pinned as an HONEST CANARY
// (arpss-js-structuredclone-residual-path): structuredClone ignores toJSON by
// spec, so a structured clone of the config carries the RAW token. This test
// asserts the limitation ON PURPOSE — it is documentation with teeth, not a
// wish. If it ever fails, either the platform changed or someone landed the
// non-enumerable-token redesign: in both cases the SDK SECURITY NOTES block in
// client.ts (and this test) must be updated in the same change. No repo
// consumer structured-clones the client or its config today (grep-confirmed);
// standard Next App Router prop serialization is Flight, which honors toJSON.
describe('structuredClone — the documented uncovered path (canary)', () => {
  it('structuredClone(client.config) exposes the raw token (KNOWN, monitored)', () => {
    const bp = createClient(baseConfig)
    // The covered surfaces stay covered…
    expect(JSON.stringify(bp.config)).not.toContain(SENTINEL)
    // …and the uncovered one is exactly this wide, no wider.
    expect(structuredClone(bp.config).token).toBe(SENTINEL)
  })
})
