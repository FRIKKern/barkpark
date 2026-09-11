// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// CAPABILITY: a Barkpark 429 is a TIMED refusal, and the server-side
// `barkparkFetch` now waits it out instead of rendering an error page.
//
// The finding this file discharges (task-b4b421aac4e9d55d, criterion 3): the
// 429 arm of `decodeAndThrow` parsed the `Retry-After` header into
// `rlOpts.retryAfterMs` and threw — nothing in `runRequest` ever read it back,
// so the parsed number had NO CONSUMER and every throttle was a hard failure
// for a Server Component render. The parse looked like a retry; it was a label.
//
// The invariant, matching web/lib/bp-fetch.ts as fixed in #17171: the wait comes
// FROM THE RESPONSE (body `error.details.retry_after` first, `Retry-After`
// header second) and is never invented; it is bounded by a per-wait clamp, a
// total-sleep budget, and an attempt cap; and a NON-429 failure is not retried
// even once. Both directions are proved in this one file.

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'

const { draftModeMock } = vi.hoisted(() => ({
  draftModeMock: vi.fn(async () => ({ isEnabled: false })),
}))
vi.mock('next/headers', () => ({
  draftMode: draftModeMock,
}))

import {
  BarkparkAPIError,
  BarkparkAuthError,
  BarkparkRateLimitError,
  BarkparkTimeoutError,
} from '@barkpark/core'
import { barkparkFetch } from '../src/server/index'
import type { BarkparkServerConfig } from '../src/server/index'
import {
  MAX_RATE_LIMIT_ATTEMPTS,
  MAX_RETRY_AFTER_MS,
  MAX_RETRY_SLEEP_TOTAL_MS,
  boundedRetryDelayMs,
  rateLimitRetryAfterMs,
  withinSleepBudget,
} from '../src/server/core'

function makeCfg(fetchOptions?: BarkparkServerConfig['fetchOptions']): BarkparkServerConfig {
  const cfg: BarkparkServerConfig = {
    client: {
      config: {
        projectUrl: 'http://localhost:4000',
        dataset: 'production',
        apiVersion: '2026-01-01',
      },
    } as unknown as BarkparkServerConfig['client'],
    serverToken: 's-tok-123',
  }
  if (fetchOptions !== undefined) cfg.fetchOptions = fetchOptions
  return cfg
}

/** A 429 in Barkpark's canonical rate-limit envelope. */
function rateLimited(opts: { bodyRetryAfter?: number; header?: string; json?: boolean }): Response {
  const headers: Record<string, string> = { 'content-type': 'application/json' }
  if (opts.header !== undefined) headers['retry-after'] = opts.header
  const details =
    opts.bodyRetryAfter !== undefined ? { retry_after: opts.bodyRetryAfter } : undefined
  const body =
    opts.json === false
      ? '<html>slow down</html>'
      : JSON.stringify({
          error: { code: 'rate_limited', message: 'rate limited', details },
        })
  return new Response(body, { status: 429, headers })
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

/**
 * Queue responses in order. The LAST entry repeats forever, so an
 * attempt-cap/budget test cannot pass merely by running out of fixtures — the
 * only thing that stops the loop is the code under test.
 */
function queueFetch(responses: Response[]): () => number {
  let i = 0
  const spy = vi.spyOn(globalThis, 'fetch').mockImplementation(async () => {
    const r = responses[Math.min(i, responses.length - 1)] as Response
    i += 1
    return r.clone()
  })
  return () => spy.mock.calls.length
}

describe('server 429 — bounded retry driven by the response', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
    draftModeMock.mockResolvedValue({ isEnabled: false })
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('RETRIES a 429 carrying details.retry_after and SUCCEEDS on the next attempt', async () => {
    const calls = queueFetch([
      rateLimited({ bodyRetryAfter: 0 }),
      jsonResponse(200, { documents: [{ _id: 'doc-1' }] }),
    ])
    await expect(barkparkFetch(makeCfg(), { type: 'post' })).resolves.toEqual({
      documents: [{ _id: 'doc-1' }],
    })
    expect(calls()).toBe(2)
  })

  it('falls back to the Retry-After HEADER when the body carries no retry_after', async () => {
    const calls = queueFetch([
      rateLimited({ header: '0' }),
      jsonResponse(200, { documents: [] }),
    ])
    await expect(barkparkFetch(makeCfg(), { type: 'post' })).resolves.toEqual({ documents: [] })
    expect(calls()).toBe(2)
  })

  it('honours the BODY over the header (a 2h header does not park the render)', async () => {
    const calls = queueFetch([
      rateLimited({ bodyRetryAfter: 0, header: '7200' }),
      jsonResponse(200, { ok: true }),
    ])
    const started = Date.now()
    await expect(barkparkFetch(makeCfg(), { type: 'post' })).resolves.toEqual({ ok: true })
    expect(calls()).toBe(2)
    // Header-first would have clamped to MAX_RETRY_AFTER_MS and slept 20s.
    expect(Date.now() - started).toBeLessThan(2_000)
  })

  it('does NOT retry a 500 — one attempt, generic API error', async () => {
    const calls = queueFetch([
      jsonResponse(500, { error: { code: 'internal', message: 'boom' } }),
      jsonResponse(200, { documents: [] }),
    ])
    const err = await barkparkFetch(makeCfg(), { type: 'post' }).then(
      () => null,
      (e: unknown) => e,
    )
    expect(err).toBeInstanceOf(BarkparkAPIError)
    expect(err).not.toBeInstanceOf(BarkparkRateLimitError)
    expect(calls()).toBe(1)
  })

  it('does NOT retry a 403', async () => {
    const calls = queueFetch([
      jsonResponse(403, { error: { code: 'forbidden', message: 'nope' } }),
      jsonResponse(200, { documents: [] }),
    ])
    const err = await barkparkFetch(makeCfg(), { type: 'post' }).then(
      () => null,
      (e: unknown) => e,
    )
    expect(err).toBeInstanceOf(BarkparkAuthError)
    expect(calls()).toBe(1)
  })

  it('does NOT retry a 429 with no retry_after anywhere — it never invents a sleep', async () => {
    const calls = queueFetch([rateLimited({}), jsonResponse(200, { documents: [] })])
    const err = await barkparkFetch(makeCfg(), { type: 'post' }).then(
      () => null,
      (e: unknown) => e,
    )
    expect(err).toBeInstanceOf(BarkparkRateLimitError)
    expect((err as BarkparkRateLimitError).retryAfterMs).toBeUndefined()
    expect(calls()).toBe(1)
  })

  it('stops at the ATTEMPT CAP when every attempt is throttled', async () => {
    const calls = queueFetch([rateLimited({ bodyRetryAfter: 0 })])
    const err = await barkparkFetch(makeCfg(), { type: 'post' }).then(
      () => null,
      (e: unknown) => e,
    )
    expect(err).toBeInstanceOf(BarkparkRateLimitError)
    expect(calls()).toBe(MAX_RATE_LIMIT_ATTEMPTS)
  })

  it('stops at the TOTAL SLEEP BUDGET before the attempt cap is reached', async () => {
    vi.useFakeTimers()
    // 15s + 15s = 30s > MAX_RETRY_SLEEP_TOTAL_MS (20s), so the SECOND 429 bails
    // on the budget while the attempt cap (3) would still have allowed a third.
    const calls = queueFetch([rateLimited({ bodyRetryAfter: 15 })])
    const settled = barkparkFetch(makeCfg(), { type: 'post' }).then(
      () => null,
      (e: unknown) => e,
    )
    await vi.advanceTimersByTimeAsync(120_000)
    const err = await settled
    expect(err).toBeInstanceOf(BarkparkRateLimitError)
    expect(calls()).toBe(2)
    expect(calls()).toBeLessThan(MAX_RATE_LIMIT_ATTEMPTS)
  })

  it('lets the configured DEADLINE win over an in-flight retry wait', async () => {
    // The nap is inside the one deadline runFetch arms; a 5s retry_after must
    // not outlive a 60ms timeout.
    const calls = queueFetch([rateLimited({ bodyRetryAfter: 5 })])
    const err = await barkparkFetch(makeCfg({ timeout: 60 }), { type: 'post' }).then(
      () => null,
      (e: unknown) => e,
    )
    expect(err).toBeInstanceOf(BarkparkTimeoutError)
    expect(calls()).toBe(1)
  })

  it('reports the server’s UNCLAMPED retry_after on the error it finally throws', async () => {
    const calls = queueFetch([rateLimited({ bodyRetryAfter: 3600 })])
    const err = await barkparkFetch(makeCfg({ timeout: 60 }), { type: 'post' }).then(
      () => null,
      (e: unknown) => e,
    )
    // The 3600s wait clamps to 20s for OUR sleep, which the 60ms deadline then
    // cuts short — but the value handed to the caller is the server's own.
    expect(calls()).toBe(1)
    expect(err).toBeInstanceOf(BarkparkTimeoutError)
  })
})

describe('retry_after parsing + bounds (the pure decisions)', () => {
  it('reads the body first, in SECONDS, unclamped', () => {
    const body = { error: { code: 'rate_limited', details: { retry_after: 42 } } }
    expect(rateLimitRetryAfterMs(body, '7200')).toBe(42_000)
  })

  it('falls back to the header only when the body has no number', () => {
    expect(rateLimitRetryAfterMs({ error: { code: 'rate_limited' } }, '3')).toBe(3_000)
    expect(rateLimitRetryAfterMs(undefined, '3')).toBe(3_000)
  })

  it('refuses an HTTP-date header and a negative value — undefined means DO NOT retry', () => {
    expect(rateLimitRetryAfterMs(undefined, 'Wed, 21 Oct 2026 07:28:00 GMT')).toBeUndefined()
    expect(rateLimitRetryAfterMs(undefined, '-5')).toBeUndefined()
    expect(rateLimitRetryAfterMs(undefined, null)).toBeUndefined()
    expect(boundedRetryDelayMs(undefined)).toBeUndefined()
  })

  it('clamps one honoured wait to MAX_RETRY_AFTER_MS', () => {
    expect(boundedRetryDelayMs(3_600_000)).toBe(MAX_RETRY_AFTER_MS)
    expect(boundedRetryDelayMs(1_500)).toBe(1_500)
  })

  it('bounds the SUM of the waits, not just each one', () => {
    expect(withinSleepBudget(15_000, 0)).toBe(true)
    expect(withinSleepBudget(15_000, 15_000)).toBe(false)
    expect(withinSleepBudget(MAX_RETRY_SLEEP_TOTAL_MS, 0)).toBe(true)
    expect(withinSleepBudget(1, MAX_RETRY_SLEEP_TOTAL_MS)).toBe(false)
  })
})
