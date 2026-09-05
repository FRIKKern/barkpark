import { describe, it, expect, vi } from 'vitest'
import { request } from '../src/transport'
import { BarkparkError, BarkparkNetworkError } from '../src/errors'
import { defaultShouldRetry } from '../src/retry'

function cfg(fetch: unknown) {
  return {
    projectUrl: 'https://api.test',
    dataset: 'production',
    apiVersion: '2026-04-01',
    fetch,
  } as never
}

// Build a fake ok Response whose `.text()` rejects mid-stream — the shape of a
// TCP reset while the body is still arriving. The status/ok/headers are the only
// fields the transport touches before reading the body.
function bodyResetResponse(rejectWith: unknown): Response {
  return {
    status: 200,
    ok: true,
    headers: { get: () => null },
    text: () => Promise.reject(rejectWith),
  } as unknown as Response
}

describe('transport — mid-body reset on response.text()', () => {
  // A `response.text()` that rejects with a raw TypeError (mid-body TCP reset)
  // sits outside the fetch try/catch and after the timeout timer is cleared, so
  // before the fix it escaped the error taxonomy entirely. After the fix it is a
  // classified BarkparkNetworkError.
  //
  // WHAT CHANGED, and this test moved with it: the classification is the durable
  // half of that fix and it still holds. The automatic re-attempt is gone — a
  // mid-body reset is a TRANSPORT fault, and the default (read) policy no longer
  // repeats one, matching the Go client's refusal to conflate a dropped
  // connection with a served fault. The taxonomy already said so
  // ("Retried only for idempotent writes", errors.ts); the wide default
  // contradicted it. See the contract at the top of src/retry.ts.
  it('wraps a mid-body TypeError as a classified BarkparkNetworkError', async () => {
    const fetchSpy = vi.fn(() => Promise.resolve(bodyResetResponse(new TypeError('terminated'))))

    let caught: unknown
    await request(cfg(fetchSpy), '/v1/data/query/production/post', {
      method: 'GET',
      kind: 'read',
    }).catch((e) => {
      caught = e
    })

    // After-fix: a Barkpark network error, inside the taxonomy.
    expect(caught).toBeInstanceOf(BarkparkNetworkError)
    // ...and NOT retried under the default read policy: it is a transport fault,
    // not a served one.
    expect(defaultShouldRetry(caught)).toBe(false)
    // Regression guard against the before-fix shape: a raw TypeError that is NOT
    // a BarkparkError and that defaultShouldRetry would refuse to retry.
    expect(caught).not.toBeInstanceOf(TypeError)
    expect(caught instanceof BarkparkError).toBe(true)
    expect((caught as BarkparkNetworkError).message).toBe('terminated')
    expect((caught as BarkparkNetworkError).cause).toBeInstanceOf(TypeError)
    // read policy allows 3 attempts, but a transport fault is not one of the
    // faults it repeats — one request, one honest error.
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  // A caller aborting mid-body (React unmount, navigation) is a cancellation,
  // NOT a network failure: re-throw the AbortError untouched so callers detect
  // it via `err.name === 'AbortError'` and it fails fast (never retried).
  it('re-throws AbortError untouched when the caller aborts mid-body', async () => {
    const fetchSpy = vi.fn(() =>
      Promise.resolve(bodyResetResponse(new DOMException('The operation was aborted.', 'AbortError'))),
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
    expect(defaultShouldRetry(caught)).toBe(false)
    // Fails fast — the cancellation is not retried.
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })
})
