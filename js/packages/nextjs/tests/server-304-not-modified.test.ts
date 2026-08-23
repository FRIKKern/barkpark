// jscc-backlog-nextjs-304-notmodified: a 304 Not Modified is `resp.ok === false`
// with an EMPTY body (query_controller.ex emits send_resp(304, "")), so it fell
// into decodeAndThrow and surfaced as a generic BarkparkAPIError ("barkparkFetch:
// 304 <url>", body '') — an error thrown at the one caller who explicitly asked
// for conditional semantics. Derivation: the SDK itself never sends If-None-Match
// / If-Modified-Since (defaultHeaders is Accept/Content-Type/Api-Version [+
// Authorization]), and Next's data cache revalidates by refetching, not by
// conditional requests — so a 304 is reachable ONLY when the consumer injects a
// conditional header through cfg.fetchOptions.headers (a supported passthrough).
// Contract: not-modified is a SUCCESS ("your copy is still current"), and the
// no-body success family already resolves undefined (204 / empty body on the ok
// path) — a 304 joins it. The caller who sent If-None-Match holds the copy the
// 304 tells them to keep; nobody else can receive one.
import { describe, it, expect, beforeEach, vi } from 'vitest'

const { draftModeMock } = vi.hoisted(() => ({
  draftModeMock: vi.fn(async () => ({ isEnabled: false })),
}))
vi.mock('next/headers', () => ({
  draftMode: draftModeMock,
}))

import { BarkparkAPIError } from '@barkpark/core'
import { barkparkFetch } from '../src/server/index'
import type { BarkparkServerConfig } from '../src/server/index'

function makeCfg(extra?: Partial<BarkparkServerConfig>): BarkparkServerConfig {
  return {
    client: {
      config: {
        projectUrl: 'http://localhost:4000',
        dataset: 'production',
        apiVersion: '2026-01-01',
      },
    } as unknown as BarkparkServerConfig['client'],
    serverToken: 's-tok-123',
    ...extra,
  }
}

beforeEach(() => {
  draftModeMock.mockReset()
  draftModeMock.mockResolvedValue({ isEnabled: false })
  vi.restoreAllMocks()
})

describe('barkparkFetch — 304 Not Modified', () => {
  it('an empty-body 304 resolves undefined (not-modified is success), never a generic error', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(null, { status: 304 }))
    const out = await barkparkFetch(
      makeCfg({ fetchOptions: { headers: { 'If-None-Match': '"abc123"' } } }),
      { type: 'post' },
    )
    expect(out).toBeUndefined()
  })

  it('a 304 in draft mode resolves undefined the same way', async () => {
    draftModeMock.mockResolvedValue({ isEnabled: true })
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(null, { status: 304 }))
    await expect(
      barkparkFetch(makeCfg({ fetchOptions: { headers: { 'If-None-Match': '"abc123"' } } }), {
        type: 'post',
      }),
    ).resolves.toBeUndefined()
  })

  it('other non-ok statuses still throw through the taxonomy (the 304 carve-out is narrow)', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ error: { code: 'boom', message: 'kaput' } }), { status: 500 }),
    )
    await expect(barkparkFetch(makeCfg(), { type: 'post' })).rejects.toBeInstanceOf(
      BarkparkAPIError,
    )
  })
})
