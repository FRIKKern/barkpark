import { describe, it, expect, vi } from 'vitest'
import { getEventListeners } from 'node:events'
import { request } from '../src/transport'

// [signal-listener-leak] transport.ts wires the caller's AbortSignal into each
// attempt's AbortController with `{ once: true }`. `once` only self-removes if
// the signal actually FIRES — on a long-lived signal reused across many requests
// (the common case: one AbortController held by a component/job across its whole
// lifetime) every attempt left a dead listener behind. Node's EventTarget warns
// past 10 listeners; the growth is bounded per signal but unbounded in count.
//
// listen.ts already solves exactly this (see its [signal-listener-leak] block):
// capture the remover, run it on teardown. These tests observe the REAL listener
// count on the caller's signal via node:events getEventListeners.

function cfg(fetch: unknown) {
  return {
    projectUrl: 'https://api.test',
    dataset: 'production',
    apiVersion: '2026-04-01',
    fetch,
  } as never
}

const PATH = '/v1/data/query/production/post'

function abortListeners(signal: AbortSignal): number {
  return getEventListeners(signal, 'abort').length
}

function okJson(): Response {
  return new Response(JSON.stringify({ result: [] }), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  })
}

describe('transport — caller AbortSignal listener hygiene', () => {
  // Presence + removal in one test: a pass must NOT be obtainable by the
  // listener never being registered at all (which would silently break abort
  // propagation). `duringAttempt` proves the wiring IS there mid-flight.
  it('registers exactly one abort listener during an attempt and removes it after success', async () => {
    const ac = new AbortController()
    let duringAttempt = -1

    const fetchSpy = vi.fn(() => {
      duringAttempt = abortListeners(ac.signal)
      return Promise.resolve(okJson())
    })

    await request(cfg(fetchSpy), PATH, { method: 'GET', kind: 'read', signal: ac.signal })

    expect(fetchSpy).toHaveBeenCalledTimes(1)
    expect(duringAttempt).toBe(1) // the subject is present — not vacuously passing
    expect(abortListeners(ac.signal)).toBe(0) // ...and cleaned up on the success path
  })

  // The leak's actual shape: one client, one signal, many requests.
  it('does not accumulate listeners across many requests on a reused signal', async () => {
    const ac = new AbortController()
    const fetchSpy = vi.fn(() => Promise.resolve(okJson()))

    for (let i = 0; i < 12; i += 1) {
      await request(cfg(fetchSpy), PATH, { method: 'GET', kind: 'read', signal: ac.signal })
    }

    expect(fetchSpy).toHaveBeenCalledTimes(12)
    // Unfixed: 12 (past Node's 10-listener warning threshold).
    expect(abortListeners(ac.signal)).toBe(0)
  })

  // Each RETRY is a fresh attempt with a fresh AbortController — so the leak
  // also grows within a single request() call.
  it('does not accumulate listeners across retries within one request', async () => {
    const ac = new AbortController()
    // A retryable SERVED fault (500 + `internal_error`) — the one thing the
    // default read policy repeats. It used to be a rejected fetch, but a
    // transport fault is no longer retried (see src/retry.ts), and a test that
    // makes one attempt cannot prove anything about listeners across retries.
    const fetchSpy = vi.fn(() =>
      Promise.resolve(
        new Response(JSON.stringify({ error: { code: 'internal_error', message: 'transient' } }), {
          status: 500,
          headers: { 'content-type': 'application/json' },
        }),
      ),
    )

    await request(cfg(fetchSpy), PATH, {
      method: 'GET',
      kind: 'read',
      signal: ac.signal,
    }).catch(() => undefined)

    expect(fetchSpy).toHaveBeenCalledTimes(3) // read policy = 3 attempts
    // Unfixed: 3.
    expect(abortListeners(ac.signal)).toBe(0)
  })

  // A throw out of onBeforeRequest exits the attempt BEFORE the fetch and before
  // the body-handling try/finally — the removal must cover that path too.
  it('removes the listener when onBeforeRequest throws', async () => {
    const ac = new AbortController()
    const fetchSpy = vi.fn(() => Promise.resolve(okJson()))
    const config = {
      ...(cfg(fetchSpy) as unknown as Record<string, unknown>),
      onBeforeRequest: () => {
        throw new Error('hook exploded')
      },
    } as never

    await request(config, PATH, { method: 'GET', kind: 'read', signal: ac.signal }).catch(
      () => undefined,
    )

    expect(fetchSpy).not.toHaveBeenCalled()
    expect(abortListeners(ac.signal)).toBe(0)
  })

  // Guard against the fix over-reaching: the listener must still DO its job —
  // a caller abort has to reach the per-attempt signal handed to fetch.
  it('still forwards a caller abort to the per-attempt signal', async () => {
    const ac = new AbortController()
    let attemptSignalAborted = false

    const fetchSpy = vi.fn(
      (_url: string, init: RequestInit) =>
        new Promise<Response>((_resolve, reject) => {
          init.signal?.addEventListener('abort', () => {
            attemptSignalAborted = true
            reject(new DOMException('The operation was aborted.', 'AbortError'))
          })
        }),
    )

    const pending = request(cfg(fetchSpy), PATH, {
      method: 'GET',
      kind: 'read',
      signal: ac.signal,
    }).catch((e: unknown) => e)

    // Let the attempt reach fetch before aborting.
    await Promise.resolve()
    await Promise.resolve()
    ac.abort()

    const caught = await pending
    expect(attemptSignalAborted).toBe(true)
    expect((caught as { name?: string })?.name).toBe('AbortError')
    expect(abortListeners(ac.signal)).toBe(0)
  })
})
