// Ok-path body-decode guard for runFetch (js/packages/nextjs/src/server/core.ts).
//
// Red-first regression: before the guard, runFetch ended with a bare
// `return (await resp.json()) as T`, so a 204 or an empty/non-JSON 2xx body threw a
// raw SyntaxError that escaped the Barkpark error taxonomy (and crashed the 204 case
// that core treats as success). These tests assert the mirror of the core transport
// ok-path: 204 -> undefined, empty 200 -> undefined, non-JSON 200 -> BarkparkAPIError
// (NOT SyntaxError). They fail on origin/main and pass after the fix.
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

interface FakeClient {
  config: {
    projectUrl: string
    dataset: string
    apiVersion: string
    workspace?: string
    project?: string
  }
}

function makeCfg(): BarkparkServerConfig {
  const client: FakeClient = {
    config: {
      projectUrl: 'http://localhost:4000',
      dataset: 'production',
      apiVersion: '2026-01-01',
    },
  }
  return {
    client: client as unknown as BarkparkServerConfig['client'],
    serverToken: 's-tok-123',
  }
}

beforeEach(() => {
  draftModeMock.mockReset()
  draftModeMock.mockResolvedValue({ isEnabled: false })
  vi.restoreAllMocks()
})

describe('barkparkFetch — ok-path body-decode guard', () => {
  it('returns undefined on an empty-body 200 (no SyntaxError from resp.json())', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('', { status: 200 }))
    const out = await barkparkFetch(makeCfg(), { type: 'post' })
    expect(out).toBeUndefined()
  })

  it('returns undefined on a 204 No Content (null body, core treats it as success)', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(null, { status: 204 }))
    const out = await barkparkFetch(makeCfg(), { type: 'post' })
    expect(out).toBeUndefined()
  })

  it('throws BarkparkAPIError (not a raw SyntaxError) on a non-JSON 200 body', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('<html>', { status: 200 }))
    const err = await barkparkFetch(makeCfg(), { type: 'post' }).catch((e) => e)
    expect(err).toBeInstanceOf(BarkparkAPIError)
    expect(err).not.toBeInstanceOf(SyntaxError)
    expect((err as BarkparkAPIError).status).toBe(200)
    expect((err as BarkparkAPIError).body).toBe('<html>')
  })
})
