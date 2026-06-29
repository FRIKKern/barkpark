import { describe, it, expect, vi, afterEach } from 'vitest'
import { request } from '../src/transport'
import { BarkparkTimeoutError } from '../src/errors'

afterEach(() => {
  vi.useRealTimers()
})

// A fetch that never resolves until its abort signal fires (a hung server).
function hangingFetch() {
  return vi.fn(
    (_url: string, init: { signal?: AbortSignal }) =>
      new Promise<Response>((_resolve, reject) => {
        init.signal?.addEventListener('abort', () =>
          reject(new DOMException('aborted', 'AbortError')),
        )
      }),
  )
}

function cfg(fetch: unknown) {
  return {
    projectUrl: 'https://api.test',
    dataset: 'production',
    apiVersion: '2026-04-01',
    fetch,
  } as never
}

describe('transport — default request timeout', () => {
  it('applies the documented write default (60s) when no timeout is configured', async () => {
    // Before the fix, an un-configured client applied NO timeout, so this
    // request would hang forever instead of rejecting.
    vi.useFakeTimers()
    const p = request(cfg(hangingFetch()), '/v1/data/mutate/production', {
      method: 'POST',
      kind: 'write',
    })
    const expectation = expect(p).rejects.toBeInstanceOf(BarkparkTimeoutError)
    await vi.advanceTimersByTimeAsync(60_000)
    await expectation
  })

  it('a per-call timeoutMs overrides the default', async () => {
    vi.useFakeTimers()
    const p = request(cfg(hangingFetch()), '/v1/data/mutate/production', {
      method: 'POST',
      kind: 'write',
      timeoutMs: 500,
    })
    const expectation = expect(p).rejects.toBeInstanceOf(BarkparkTimeoutError)
    await vi.advanceTimersByTimeAsync(500)
    await expectation
  })
})
