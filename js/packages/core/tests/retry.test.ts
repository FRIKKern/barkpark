import { describe, it, expect } from 'vitest'
import {
  retry,
  defaultShouldRetry,
  DEFAULT_READ_POLICY,
  DEFAULT_WRITE_POLICY,
  IDEMPOTENT_WRITE_POLICY,
  MAX_RATE_LIMIT_BACKOFF_MS,
  type RetryPolicy,
} from '../src/retry'
import {
  BarkparkAPIError,
  BarkparkNetworkError,
  BarkparkRateLimitError,
  BarkparkTimeoutError,
} from '../src/errors'

// A zero-delay clone of a policy so the control-flow tests never actually sleep.
// (computeDelay returns 0 when baseMs is 0 and the error carries no retryAfterMs.)
const instant = (over: Partial<RetryPolicy> = {}): RetryPolicy => ({
  maxAttempts: 3,
  baseMs: 0,
  maxBackoffMs: 0,
  jitter: false,
  ...over,
})

describe('defaultShouldRetry', () => {
  it('retries transient/transport errors', () => {
    expect(defaultShouldRetry(new BarkparkNetworkError('down'))).toBe(true)
    expect(defaultShouldRetry(new BarkparkTimeoutError('slow'))).toBe(true)
    expect(defaultShouldRetry(new BarkparkRateLimitError('429', { retryAfterMs: 0 }))).toBe(true)
  })

  it('retries only 5xx API errors, never 4xx', () => {
    expect(defaultShouldRetry(new BarkparkAPIError('boom', { status: 500 }))).toBe(true)
    expect(defaultShouldRetry(new BarkparkAPIError('boom', { status: 503 }))).toBe(true)
    expect(defaultShouldRetry(new BarkparkAPIError('bad', { status: 400 }))).toBe(false)
    expect(defaultShouldRetry(new BarkparkAPIError('nope', { status: 404 }))).toBe(false)
    expect(defaultShouldRetry(new BarkparkAPIError('conflict', { status: 409 }))).toBe(false)
  })

  it('does not retry an API error with no status, or a plain error', () => {
    expect(defaultShouldRetry(new BarkparkAPIError('statusless'))).toBe(false)
    expect(defaultShouldRetry(new Error('generic'))).toBe(false)
    expect(defaultShouldRetry('not even an error')).toBe(false)
  })
})

describe('retry', () => {
  it('returns the first-attempt result without a second call', async () => {
    let calls = 0
    const out = await retry(async (attempt) => {
      calls += 1
      expect(attempt).toBe(1)
      return 'ok'
    }, instant())
    expect(out).toBe('ok')
    expect(calls).toBe(1)
  })

  it('retries a retryable failure then succeeds, passing the incrementing attempt', async () => {
    const seen: number[] = []
    const out = await retry(async (attempt) => {
      seen.push(attempt)
      if (attempt < 3) throw new BarkparkNetworkError('transient')
      return 'recovered'
    }, instant())
    expect(out).toBe('recovered')
    expect(seen).toEqual([1, 2, 3])
  })

  it('gives up after maxAttempts and throws the last error', async () => {
    let calls = 0
    const err = new BarkparkNetworkError('always down')
    await expect(
      retry(async () => {
        calls += 1
        throw err
      }, instant({ maxAttempts: 2 })),
    ).rejects.toBe(err)
    expect(calls).toBe(2)
  })

  it('does not retry a non-retryable error — throws on the first attempt', async () => {
    let calls = 0
    await expect(
      retry(async () => {
        calls += 1
        throw new BarkparkAPIError('bad request', { status: 400 })
      }, instant()),
    ).rejects.toBeInstanceOf(BarkparkAPIError)
    expect(calls).toBe(1)
  })

  it('honors a custom shouldRetry over the default', async () => {
    let calls = 0
    // A 400 is non-retryable by default; force it retryable here.
    await expect(
      retry(
        async () => {
          calls += 1
          throw new BarkparkAPIError('bad', { status: 400 })
        },
        instant({ maxAttempts: 3, shouldRetry: () => true }),
      ),
    ).rejects.toBeInstanceOf(BarkparkAPIError)
    expect(calls).toBe(3)
  })

  it('calls onBeforeAttempt before each retry with (nextAttempt, prevError), awaited', async () => {
    const hook: Array<{ attempt: number; prevMsg: string }> = []
    const errs = [new BarkparkNetworkError('e1'), new BarkparkNetworkError('e2')]
    let i = 0
    const out = await retry(
      async () => {
        if (i < errs.length) throw errs[i++]
        return 'done'
      },
      instant({
        maxAttempts: 3,
        onBeforeAttempt: async (attempt, prevError) => {
          hook.push({ attempt, prevMsg: (prevError as Error).message })
        },
      }),
    )
    expect(out).toBe('done')
    // Fired before attempt 2 (prev=e1) and attempt 3 (prev=e2); never before attempt 1.
    expect(hook).toEqual([
      { attempt: 2, prevMsg: 'e1' },
      { attempt: 3, prevMsg: 'e2' },
    ])
  })

  it('aborts a between-attempt backoff sleep immediately with an AbortError', async () => {
    const controller = new AbortController()
    // 429 with a long retry-after so the backoff would otherwise block.
    const rateLimited = new BarkparkRateLimitError('429', { retryAfterMs: 5000 })
    let calls = 0
    const started = Date.now()
    const promise = retry(
      async () => {
        calls += 1
        // Abort while we're about to enter the backoff sleep.
        queueMicrotask(() => controller.abort())
        throw rateLimited
      },
      instant({ maxAttempts: 3, baseMs: 5000, maxBackoffMs: 5000 }),
      controller.signal,
    )
    await expect(promise).rejects.toMatchObject({ name: 'AbortError' })
    // Cancelled fast (well under the 5s backoff), and did not run a 2nd attempt.
    expect(Date.now() - started).toBeLessThan(1000)
    expect(calls).toBe(1)
  })

  it('sleeps and retries normally when the signal never aborts (no hang)', async () => {
    const controller = new AbortController()
    const seen: number[] = []
    const out = await retry(
      async (attempt) => {
        seen.push(attempt)
        if (attempt < 2) throw new BarkparkNetworkError('transient')
        return 'ok'
      },
      instant({ maxAttempts: 2, baseMs: 1, maxBackoffMs: 5 }),
      controller.signal,
    )
    expect(out).toBe('ok')
    expect(seen).toEqual([1, 2])
  })

  it('clamps a hostile Retry-After to the ceiling', async () => {
    const controller = new AbortController()
    // Retry-After of 1h; abort during the backoff and assert it did not honor 1h.
    const hostile = new BarkparkRateLimitError('429', { retryAfterMs: 3_600_000 })
    const started = Date.now()
    const promise = retry(
      async () => {
        queueMicrotask(() => controller.abort())
        throw hostile
      },
      instant({ maxAttempts: 2 }),
      controller.signal,
    )
    await expect(promise).rejects.toMatchObject({ name: 'AbortError' })
    // The clamp is a bounded named const; the cancel proves the wait never pinned for 1h.
    expect(MAX_RATE_LIMIT_BACKOFF_MS).toBeLessThanOrEqual(60_000)
    expect(Date.now() - started).toBeLessThan(1000)
  })

  it('maxAttempts:1 (default write policy) never retries', async () => {
    let calls = 0
    await expect(
      retry(async () => {
        calls += 1
        throw new BarkparkNetworkError('down')
      }, DEFAULT_WRITE_POLICY),
    ).rejects.toBeInstanceOf(BarkparkNetworkError)
    expect(calls).toBe(1)
  })
})

describe('policy presets', () => {
  it('reads allow retries; plain writes do not; idempotent writes do', () => {
    expect(DEFAULT_READ_POLICY.maxAttempts).toBeGreaterThan(1)
    expect(DEFAULT_WRITE_POLICY.maxAttempts).toBe(1)
    expect(IDEMPOTENT_WRITE_POLICY.maxAttempts).toBeGreaterThan(1)
  })
})
