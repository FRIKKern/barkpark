import { describe, it, expect } from 'vitest'
import {
  retry,
  defaultShouldRetry,
  idempotentWriteShouldRetry,
  isRetryableServerFault,
  isTransportFault,
  hasBudgetFor,
  RETRYABLE_SERVER_CODE,
  MIN_ATTEMPT_BUDGET_MS,
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

// THE retryable fault, and the only one the default policy repeats: a >=5xx
// whose envelope code is `internal_error`. These control-flow tests used to use
// a BarkparkNetworkError as their generic "retryable" stand-in — it no longer is
// one (a transport fault is refused by default; see the contract in retry.ts),
// so they use this instead.
const servedFault = (msg = 'transient'): BarkparkAPIError =>
  new BarkparkAPIError(msg, { status: 500, serverCode: 'internal_error' })

describe('defaultShouldRetry — the narrowed served-fault rule', () => {
  it('retries a >=5xx ONLY when the envelope code is in the allowlist', () => {
    expect(defaultShouldRetry(servedFault())).toBe(true)
    expect(RETRYABLE_SERVER_CODE).toBe('internal_error')
    // Same status class, a code that names a real cause — handed straight back,
    // because retrying it papers over the defect that produced it.
    expect(
      defaultShouldRetry(
        new BarkparkAPIError('import blew up', { status: 500, serverCode: 'import_failed' }),
      ),
    ).toBe(false)
    expect(
      defaultShouldRetry(
        new BarkparkAPIError('no room', { status: 503, serverCode: 'runtime_capacity' }),
      ),
    ).toBe(false)
    expect(
      defaultShouldRetry(
        new BarkparkAPIError('gateway', { status: 502, serverCode: 'storage_unavailable' }),
      ),
    ).toBe(false)
    // A 5xx with NO code at all is not evidence of a transient fault.
    expect(defaultShouldRetry(new BarkparkAPIError('bare 500', { status: 500 }))).toBe(false)
  })

  it('still retries a 429 — backpressure is not a fault', () => {
    expect(defaultShouldRetry(new BarkparkRateLimitError('429', { retryAfterMs: 0 }))).toBe(true)
  })

  it('never retries a 4xx', () => {
    expect(defaultShouldRetry(new BarkparkAPIError('bad', { status: 400 }))).toBe(false)
    expect(defaultShouldRetry(new BarkparkAPIError('nope', { status: 404 }))).toBe(false)
    expect(defaultShouldRetry(new BarkparkAPIError('conflict', { status: 409 }))).toBe(false)
    // Even carrying the retryable code: the status class gates it out first.
    expect(
      defaultShouldRetry(
        new BarkparkAPIError('weird', { status: 400, serverCode: 'internal_error' }),
      ),
    ).toBe(false)
  })

  it('does not retry an API error with no status, or a plain error', () => {
    expect(defaultShouldRetry(new BarkparkAPIError('statusless'))).toBe(false)
    expect(defaultShouldRetry(new Error('generic'))).toBe(false)
    expect(defaultShouldRetry('not even an error')).toBe(false)
  })
})

// CRITERION [3]. The Go client refuses a transport-level error outright
// (internal/apiclient/retry.go: `if err != nil { return nil, err }`) because
// "conflating a dropped connection with a served fault would hide a different
// failure mode — the same host dropped SYNs on 2026-08-21". Ported here.
describe('a transport-level error is not retried as a served fault', () => {
  const dropped = new BarkparkNetworkError('connection reset')
  const timedOut = new BarkparkTimeoutError('per-attempt deadline elapsed', { timeoutMs: 30_000 })

  it('classifies it as a transport fault, never as a served fault', () => {
    expect(isTransportFault(dropped)).toBe(true)
    expect(isTransportFault(timedOut)).toBe(true)
    expect(isRetryableServerFault(dropped)).toBe(false)
    expect(isRetryableServerFault(timedOut)).toBe(false)
  })

  it('the default policy declines it', () => {
    expect(defaultShouldRetry(dropped)).toBe(false)
    expect(defaultShouldRetry(timedOut)).toBe(false)
  })

  it('and the loop makes exactly one attempt, rethrowing the transport error', async () => {
    let calls = 0
    await expect(
      retry(
        async () => {
          calls += 1
          throw dropped
        },
        instant({ maxAttempts: 3 }),
      ),
    ).rejects.toBe(dropped)
    expect(calls).toBe(1)
  })

  it('the ONE exception is an idempotent write, where a stable key makes the replay safe', async () => {
    expect(idempotentWriteShouldRetry(dropped)).toBe(true)
    expect(idempotentWriteShouldRetry(timedOut)).toBe(true)
    // ...and it is wired into the policy the transport actually picks.
    expect(IDEMPOTENT_WRITE_POLICY.shouldRetry).toBe(idempotentWriteShouldRetry)
    let calls = 0
    await expect(
      retry(
        async () => {
          calls += 1
          throw dropped
        },
        instant({ maxAttempts: 3, shouldRetry: idempotentWriteShouldRetry }),
      ),
    ).rejects.toBe(dropped)
    expect(calls).toBe(3)
    // The exception is scoped: it does NOT widen the served-fault rule.
    expect(
      idempotentWriteShouldRetry(
        new BarkparkAPIError('boom', { status: 503, serverCode: 'runtime_capacity' }),
      ),
    ).toBe(false)
  })
})

// CRITERION [1]. The port of `hasBudgetFor` (internal/apiclient/retry.go), the
// check whose absence was measured at 19/40 against 24/40.
describe('deadline budget', () => {
  it('a policy with no deadline always has budget', () => {
    expect(hasBudgetFor(instant(), 5_000)).toBe(true)
  })

  it('allows a retry that fits, refuses one that does not', () => {
    const now = () => 1_000_000
    // 5s left, 1s wait + 1s min attempt = fits.
    expect(hasBudgetFor(instant({ deadlineAt: 1_005_000, now }), 1_000)).toBe(true)
    // 1.5s left, 1s wait + 1s min attempt = does not fit.
    expect(hasBudgetFor(instant({ deadlineAt: 1_001_500, now }), 1_000)).toBe(false)
    // Exactly the allowance is NOT enough — the check is strict, like Go's `>`.
    expect(hasBudgetFor(instant({ deadlineAt: 1_000_000 + MIN_ATTEMPT_BUDGET_MS, now }), 0)).toBe(
      false,
    )
  })

  it('SKIPS the retry when the budget is exhausted, throwing the served fault at once', async () => {
    const fault = servedFault('still sick')
    let calls = 0
    const started = Date.now()
    await expect(
      retry(
        async () => {
          calls += 1
          throw fault
        },
        {
          maxAttempts: 3,
          baseMs: 2_000,
          maxBackoffMs: 2_000,
          jitter: false,
          // 500ms of headroom: nowhere near a 2s wait plus a 1s attempt.
          deadlineAt: Date.now() + 500,
        },
      ),
    ).rejects.toBe(fault)
    // One attempt only, and nothing was slept: the caller gets the honest 500
    // now instead of an abort two seconds from now.
    expect(calls).toBe(1)
    expect(Date.now() - started).toBeLessThan(500)
  })

  it('does not refuse a retry that comfortably fits the deadline', async () => {
    let calls = 0
    const out = await retry(
      async (attempt) => {
        calls += 1
        if (attempt < 2) throw servedFault()
        return 'recovered'
      },
      instant({ maxAttempts: 3, deadlineAt: Date.now() + 60_000 }),
    )
    expect(out).toBe('recovered')
    expect(calls).toBe(2)
  })

  it('bites mid-sequence: attempt 2 is allowed, attempt 3 is not', async () => {
    let clock = 0
    const fault = servedFault()
    let calls = 0
    await expect(
      retry(
        async () => {
          calls += 1
          // Each attempt burns 1.2s of the 4s budget.
          clock += 1_200
          throw fault
        },
        {
          maxAttempts: 3,
          baseMs: 500,
          maxBackoffMs: 5_000,
          jitter: false,
          deadlineAt: 4_000,
          now: () => clock,
        },
      ),
    ).rejects.toBe(fault)
    // After attempt 1 (clock 1200): 2800 left > 500 + 1000 → retry allowed.
    // After attempt 2 (clock 2400): 1600 left, wait is now 1000 → 1600 > 2000 is
    // false → declined. So two attempts, not three.
    expect(calls).toBe(2)
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
      if (attempt < 3) throw servedFault()
      return 'recovered'
    }, instant())
    expect(out).toBe('recovered')
    expect(seen).toEqual([1, 2, 3])
  })

  it('gives up after maxAttempts and throws the last error', async () => {
    let calls = 0
    const err = servedFault('always down')
    await expect(
      retry(
        async () => {
          calls += 1
          throw err
        },
        instant({ maxAttempts: 2 }),
      ),
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
    const errs = [servedFault('e1'), servedFault('e2')]
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
        if (attempt < 2) throw servedFault()
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
        throw servedFault('down')
      }, DEFAULT_WRITE_POLICY),
    ).rejects.toBeInstanceOf(BarkparkAPIError)
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
