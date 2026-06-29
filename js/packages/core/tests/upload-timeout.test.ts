import { describe, it, expect, vi, afterEach } from 'vitest'
import { createClient } from '../src/client'
import { BarkparkTimeoutError } from '../src/errors'

afterEach(() => {
  vi.useRealTimers()
})

// A fetch that never resolves until its abort signal fires (a hung/slow upload).
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

function blob() {
  return new Blob([new Uint8Array([1, 2, 3])], { type: 'image/png' })
}

describe('uploadAsset timeout', () => {
  it('honors a per-call timeoutMs override', async () => {
    vi.useFakeTimers()
    const bp = client(hangingFetch())
    const p = bp.uploadAsset(blob(), { filename: 'pic.png', timeoutMs: 100 })
    const expectation = expect(p).rejects.toBeInstanceOf(BarkparkTimeoutError)
    await vi.advanceTimersByTimeAsync(100)
    await expectation
  })

  it('applies the 120s upload default, not the 60s write default', async () => {
    vi.useFakeTimers()
    const bp = client(hangingFetch())
    const p = bp.uploadAsset(blob())
    let settled = false
    void p.catch(() => {
      settled = true
    })
    // Past the 60s write default — still pending proves uploads use the longer default.
    await vi.advanceTimersByTimeAsync(90_000)
    expect(settled).toBe(false)
    // Reaches 120s — now it fires.
    await vi.advanceTimersByTimeAsync(30_000)
    await expect(p).rejects.toBeInstanceOf(BarkparkTimeoutError)
  })
})
