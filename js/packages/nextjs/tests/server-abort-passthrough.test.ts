// A caller-initiated abort is a CANCELLATION, not a timeout. Core transport's
// scarred contract (js/packages/core/src/transport.ts) re-throws the caller's
// AbortError untouched so `err.name === 'AbortError'` detection works exactly
// as with a bare fetch. runFetch's catch used to map EVERY AbortError to
// BarkparkTimeoutError, so a component unmount cancelling a barkparkFetch read
// was reported as "barkparkFetch: timeout <url>" — a false alarm that callers
// (and error dashboards) cannot distinguish from a genuinely slow origin.
import { describe, it, expect, beforeEach, vi } from 'vitest'

const { draftModeMock } = vi.hoisted(() => ({
  draftModeMock: vi.fn(async () => ({ isEnabled: false })),
}))
vi.mock('next/headers', () => ({
  draftMode: draftModeMock,
}))

import { BarkparkTimeoutError } from '@barkpark/core'
import { barkparkFetch } from '../src/server/index'
import type { BarkparkServerConfig } from '../src/server/index'

function makeCfg(): BarkparkServerConfig {
  return {
    client: {
      config: {
        projectUrl: 'http://localhost:4000',
        dataset: 'production',
        apiVersion: '2026-01-01',
      },
    } as unknown as BarkparkServerConfig['client'],
    serverToken: 's-tok-123',
  }
}

beforeEach(() => {
  draftModeMock.mockReset()
  draftModeMock.mockResolvedValue({ isEnabled: false })
  vi.restoreAllMocks()
})

describe('barkparkFetch — caller abort passthrough', () => {
  it("a caller-aborted fetch re-throws AbortError untouched (name === 'AbortError'), not BarkparkTimeoutError", async () => {
    const ac = new AbortController()
    vi.spyOn(globalThis, 'fetch').mockImplementation(
      (_url, init) =>
        new Promise<Response>((_resolve, reject) => {
          const sig = (init as RequestInit).signal
          if (sig?.aborted) {
            reject(new DOMException('The operation was aborted.', 'AbortError'))
            return
          }
          sig?.addEventListener('abort', () =>
            reject(new DOMException('The operation was aborted.', 'AbortError')),
          )
        }),
    )

    const p = barkparkFetch(makeCfg(), { type: 'post', signal: ac.signal })
    const settled = p.then(
      () => {
        throw new Error('unexpectedly resolved')
      },
      (e: unknown) => e,
    )
    ac.abort()
    const err = await settled
    expect(err).toBeInstanceOf(Error)
    expect((err as Error).name).toBe('AbortError')
    expect(err).not.toBeInstanceOf(BarkparkTimeoutError)
  })

  it('an AbortSignal.timeout-style TimeoutError still maps to BarkparkTimeoutError', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(
      () => Promise.reject(new DOMException('The operation timed out.', 'TimeoutError')),
    )
    await expect(barkparkFetch(makeCfg(), { type: 'post' })).rejects.toBeInstanceOf(
      BarkparkTimeoutError,
    )
  })
})
