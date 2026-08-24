import { describe, it, expect, vi, afterEach } from 'vitest'
import { createClient } from '../src/client'
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

function client(fetch: unknown) {
  return createClient({
    projectUrl: 'https://api.test',
    dataset: 'production',
    apiVersion: '2026-04-01',
    token: 't',
    fetch,
  } as never)
}

// Without the forward, commit ignores `timeoutMs` and the 60s write default
// applies — advancing 100ms would NOT fire it and the test would hang.
describe('CommitOptions.timeoutMs is forwarded to the request', () => {
  it('transaction.commit({ timeoutMs }) overrides the write default', async () => {
    vi.useFakeTimers()
    const bp = client(hangingFetch())
    const p = bp.transaction().create({ _type: 'post', title: 'x' }).commit({ timeoutMs: 100 })
    const expectation = expect(p).rejects.toBeInstanceOf(BarkparkTimeoutError)
    await vi.advanceTimersByTimeAsync(100)
    await expectation
  })

  it('patch.commit({ timeoutMs }) overrides the write default', async () => {
    vi.useFakeTimers()
    const bp = client(hangingFetch())
    const p = bp.patch('p1', 'post').set({ title: 'x' }).commit({ timeoutMs: 100 })
    const expectation = expect(p).rejects.toBeInstanceOf(BarkparkTimeoutError)
    await vi.advanceTimersByTimeAsync(100)
    await expectation
  })

  // The single-doc shortcuts now accept CommitOptions and forward them to the
  // underlying commit — proven here via the timeout (the shortcut had no opts
  // arg before, so this would not even type-check, let alone time out).
  it('client.create(doc, { timeoutMs }) forwards through the shortcut', async () => {
    vi.useFakeTimers()
    const bp = client(hangingFetch())
    const p = bp.create({ _type: 'post', title: 'x' }, { timeoutMs: 100 })
    const expectation = expect(p).rejects.toBeInstanceOf(BarkparkTimeoutError)
    await vi.advanceTimersByTimeAsync(100)
    await expectation
  })

  it('client.delete(id, type, { timeoutMs }) forwards through the shortcut', async () => {
    vi.useFakeTimers()
    const bp = client(hangingFetch())
    const p = bp.delete('p1', 'post', { timeoutMs: 100 })
    const expectation = expect(p).rejects.toBeInstanceOf(BarkparkTimeoutError)
    await vi.advanceTimersByTimeAsync(100)
    await expectation
  })
})
