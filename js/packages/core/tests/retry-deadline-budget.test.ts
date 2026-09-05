import { describe, it, expect, vi } from 'vitest'
import { request } from '../src/transport'
import { BarkparkAPIError } from '../src/errors'

// END-TO-END for the two halves of the narrowing, exercised through the real
// transport rather than the retry loop in isolation — a policy narrowed in
// retry.ts but never reached from `request` would be a guard nobody rides.
//
// The reference contract is internal/apiclient/retry.go: `hasBudgetFor` at its
// budget check, `isRetryableServerFault` at its code allowlist. Its measurement
// is the reason: an interleaved A/B of 40 command pairs against the live box had
// the retrying binary at 19/40 against the non-retrying one at 24/40 until the
// budget check existed. More attempts, worse outcomes.

function cfg(fetch: unknown, extra: Record<string, unknown> = {}) {
  return {
    projectUrl: 'https://api.test',
    dataset: 'production',
    apiVersion: '2026-04-01',
    fetch,
    ...extra,
  } as never
}

const PATH = '/v1/data/query/production/post'

function envelope(code: string, status: number): Response {
  return new Response(JSON.stringify({ error: { code, message: 'server said so' } }), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

describe('transport — the narrowed 5xx rule', () => {
  it('retries a 500 internal_error to the attempt cap', async () => {
    const fetchSpy = vi.fn(() => Promise.resolve(envelope('internal_error', 500)))
    await request(cfg(fetchSpy), PATH, { method: 'GET', kind: 'read' }).catch(() => undefined)
    expect(fetchSpy).toHaveBeenCalledTimes(3)
  })

  it('does NOT retry a 503 the server named — one request, honest error', async () => {
    const fetchSpy = vi.fn(() => Promise.resolve(envelope('storage_unavailable', 503)))
    let caught: unknown
    await request(cfg(fetchSpy), PATH, { method: 'GET', kind: 'read' }).catch((e) => {
      caught = e
    })
    expect(fetchSpy).toHaveBeenCalledTimes(1)
    expect(caught).toBeInstanceOf(BarkparkAPIError)
    expect((caught as BarkparkAPIError).status).toBe(503)
  })

  it('does NOT retry a 500 that names a real defect', async () => {
    const fetchSpy = vi.fn(() => Promise.resolve(envelope('export_failed', 500)))
    await request(cfg(fetchSpy), PATH, { method: 'GET', kind: 'read' }).catch(() => undefined)
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })
})

describe('transport — the whole-call deadline budget', () => {
  it('SKIPS the retry when deadlineMs leaves no room for the wait plus an attempt', async () => {
    const fetchSpy = vi.fn(() => Promise.resolve(envelope('internal_error', 500)))
    const started = Date.now()
    await request(cfg(fetchSpy), PATH, {
      method: 'GET',
      kind: 'read',
      // 300ms base backoff + 1000ms min-attempt allowance needs >1.3s of room.
      deadlineMs: 200,
    }).catch(() => undefined)
    // Retryable fault, attempts remaining — and still exactly one request,
    // because the second one provably could not have finished.
    expect(fetchSpy).toHaveBeenCalledTimes(1)
    // Nothing was slept: the caller gets the 500 now, not an abort later.
    expect(Date.now() - started).toBeLessThan(300)
  })

  it('a generous deadlineMs does not suppress the retry', async () => {
    const fetchSpy = vi.fn(() => Promise.resolve(envelope('internal_error', 500)))
    await request(cfg(fetchSpy), PATH, {
      method: 'GET',
      kind: 'read',
      deadlineMs: 60_000,
    }).catch(() => undefined)
    expect(fetchSpy).toHaveBeenCalledTimes(3)
  })

  it('no deadlineMs anywhere means unbounded — an unbounded caller is not hurried', async () => {
    const fetchSpy = vi.fn(() => Promise.resolve(envelope('internal_error', 500)))
    await request(cfg(fetchSpy), PATH, { method: 'GET', kind: 'read' }).catch(() => undefined)
    expect(fetchSpy).toHaveBeenCalledTimes(3)
  })

  it('the client-level deadlineMs applies when the call does not override it', async () => {
    const fetchSpy = vi.fn(() => Promise.resolve(envelope('internal_error', 500)))
    await request(cfg(fetchSpy, { deadlineMs: 200 }), PATH, {
      method: 'GET',
      kind: 'read',
    }).catch(() => undefined)
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })
})
