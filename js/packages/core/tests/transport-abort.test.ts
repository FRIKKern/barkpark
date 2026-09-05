import { describe, it, expect, vi } from 'vitest'
import { request } from '../src/transport'
import { BarkparkNetworkError } from '../src/errors'

function cfg(fetch: unknown) {
  return {
    projectUrl: 'https://api.test',
    dataset: 'production',
    apiVersion: '2026-04-01',
    fetch,
  } as never
}

describe('transport — user-initiated abort', () => {
  // A user aborting a read (React unmount, Next.js navigation) is NOT a network
  // failure: it must surface the standard AbortError and fail fast, never be
  // retried. Before the fix it was wrapped as a retryable BarkparkNetworkError
  // and re-tried up to 3× (~900ms of backoff) before finally rejecting.
  it('surfaces AbortError and does NOT retry when the caller aborts', async () => {
    const fetchSpy = vi.fn(
      () => Promise.reject(new DOMException('The operation was aborted.', 'AbortError')),
    )
    const ac = new AbortController()
    ac.abort()

    let caught: unknown
    await request(cfg(fetchSpy), '/v1/data/query/production/post', {
      method: 'GET',
      kind: 'read',
      signal: ac.signal,
    }).catch((e) => {
      caught = e
    })

    expect((caught as { name?: string })?.name).toBe('AbortError')
    expect(caught).not.toBeInstanceOf(BarkparkNetworkError)
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  // A genuine fetch-level failure (DNS/offline/TLS) still gets CLASSIFIED as a
  // BarkparkNetworkError — guard against the abort fix over-reaching. It is no
  // longer re-attempted: a transport fault is not a served fault, and the
  // default read policy refuses it (src/retry.ts). The classification is what
  // this test guards; the attempt count moved with the narrowing.
  it('still wraps a real network failure as a classified BarkparkNetworkError', async () => {
    const fetchSpy = vi.fn(() => Promise.reject(new TypeError('Failed to fetch')))

    let caught: unknown
    await request(cfg(fetchSpy), '/v1/data/query/production/post', {
      method: 'GET',
      kind: 'read',
    }).catch((e) => {
      caught = e
    })

    expect(caught).toBeInstanceOf(BarkparkNetworkError)
    // One request: a transport fault is handed straight back, unrepeated.
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })
})
