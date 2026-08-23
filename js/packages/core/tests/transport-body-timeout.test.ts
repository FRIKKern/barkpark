// timeoutMs must bound the WHOLE request, body included. The per-attempt
// deadline timer used to be cleared the moment fetch resolved (= response
// HEADERS arrived), so a server that streamed headers and then stalled the
// body (slow-loris) hung `request()` forever — the documented timeout never
// fired, and the caller had no recourse short of wiring their own signal.
// The deadline now stays armed through the body read: a stalled body aborts
// at timeoutMs and surfaces as the same BarkparkTimeoutError a stalled
// connection does. rawResponse hands the body to the caller, so there the
// deadline still ends at headers (pinned below).
import { describe, it, expect, vi, afterEach } from 'vitest'
import { request } from '../src/transport'
import { BarkparkTimeoutError } from '../src/errors'

afterEach(() => {
  vi.useRealTimers()
})

// Headers arrive instantly; the BODY stalls until the attempt signal aborts.
function stalledBodyFetch(status = 200) {
  return vi.fn((_url: string, init: { signal?: AbortSignal }) => {
    const response = {
      ok: status >= 200 && status < 300,
      status,
      headers: new Headers(),
      text: () =>
        new Promise<string>((_resolve, reject) => {
          if (init.signal?.aborted) {
            reject(new DOMException('aborted', 'AbortError'))
            return
          }
          init.signal?.addEventListener('abort', () =>
            reject(new DOMException('aborted', 'AbortError')),
          )
        }),
    } as unknown as Response
    return Promise.resolve(response)
  })
}

function cfg(fetch: unknown) {
  return {
    projectUrl: 'https://api.test',
    dataset: 'production',
    apiVersion: '2026-04-01',
    fetch,
  } as never
}

describe('transport — timeoutMs bounds the body read, not just the headers', () => {
  it('a stalled 200 body rejects with BarkparkTimeoutError at the deadline (write, no retry)', async () => {
    vi.useFakeTimers()
    const p = request(cfg(stalledBodyFetch()), '/v1/data/mutate/production', {
      method: 'POST',
      kind: 'write',
      timeoutMs: 500,
    })
    const expectation = expect(p).rejects.toBeInstanceOf(BarkparkTimeoutError)
    await vi.advanceTimersByTimeAsync(500)
    await expectation
  })

  it('a stalled ERROR body also rejects at the deadline instead of hanging the decode', async () => {
    vi.useFakeTimers()
    const p = request(cfg(stalledBodyFetch(500)), '/v1/data/mutate/production', {
      method: 'POST',
      kind: 'write',
      timeoutMs: 500,
    })
    const expectation = expect(p).rejects.toBeInstanceOf(BarkparkTimeoutError)
    await vi.advanceTimersByTimeAsync(500)
    await expectation
  })

  it('a caller abort mid-body still surfaces as AbortError, never a timeout', async () => {
    vi.useFakeTimers()
    const ac = new AbortController()
    const p = request(cfg(stalledBodyFetch()), '/v1/data/query/production/post', {
      timeoutMs: 5_000,
      signal: ac.signal,
    })
    const settled = p.then(
      () => {
        throw new Error('unexpectedly resolved')
      },
      (e: unknown) => e,
    )
    await vi.advanceTimersByTimeAsync(10)
    ac.abort()
    const err = await settled
    expect((err as Error).name).toBe('AbortError')
    expect(err).not.toBeInstanceOf(BarkparkTimeoutError)
  })

  it('rawResponse hands the body to the caller — the deadline ends at headers', async () => {
    vi.useFakeTimers()
    const fetchFn = stalledBodyFetch()
    const p = request(cfg(fetchFn), '/v1/data/export/production', {
      rawResponse: true,
      timeoutMs: 500,
    })
    const { response } = await p
    // Past the deadline, the caller can still stream the body: the attempt
    // signal must NOT have been aborted by the (cleared) deadline timer.
    await vi.advanceTimersByTimeAsync(5_000)
    const call = fetchFn.mock.calls[0] as unknown as [string, { signal?: AbortSignal }]
    expect(call[1].signal?.aborted).toBe(false)
    expect(response.status).toBe(200)
  })
})
