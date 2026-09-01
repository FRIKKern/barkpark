// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// CAPABILITY: a consumer who sets `fetchOptions: { timeout: N }` on
// `createBarkparkServer` gets a real deadline — a hung Barkpark origin aborts
// the fetch after N ms and raises `BarkparkTimeoutError`, instead of hanging the
// Server Component render until the hosting platform's own limit.
//
// The option was DECLARED in server/types.ts under "Per-call defaults applied by
// barkparkFetch" and its only read was inside the timeout error's constructor —
// no AbortController, no AbortSignal.timeout, no timer anywhere on the server
// fetch path. A declared option nothing arms is worse than an absent one: the
// consumer relies on a promise the code never makes. @barkpark/core fixed the
// same shape in its transport (see its "an un-configured client applied NO
// timeout" note); this file holds the nextjs side to the same semantics —
// including composing with a caller-supplied signal, attributing the deadline
// that actually fired, and clearing the timer + abort listener on every exit.

import { describe, it, expect, beforeEach, vi } from 'vitest'

const { draftModeMock } = vi.hoisted(() => ({
  draftModeMock: vi.fn(async () => ({ isEnabled: false })),
}))
vi.mock('next/headers', () => ({
  draftMode: draftModeMock,
}))

import { BarkparkTimeoutError } from '@barkpark/core'
import { barkparkFetch } from '../src/server/index'
import type { BarkparkServerConfig } from '../src/server/index'

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

/**
 * A fetch that NEVER settles on its own — the hung-origin subject. It rejects
 * only when the signal it was handed aborts, and with that signal's `reason`,
 * exactly as a real `fetch` does. Forwarding the reason is what lets the test
 * tell OUR deadline (an AbortError from our own controller) apart from the
 * caller's (`AbortSignal.timeout` → a TimeoutError).
 */
function mockHangingFetch(): void {
  vi.spyOn(globalThis, 'fetch').mockImplementation(
    (_url, init) =>
      new Promise<Response>((_resolve, reject) => {
        const sig = (init as RequestInit | undefined)?.signal
        const fail = (): void => {
          reject(
            sig?.reason instanceof Error
              ? sig.reason
              : new DOMException('The operation was aborted.', 'AbortError'),
          )
        }
        if (sig === null || sig === undefined) return
        if (sig.aborted) {
          fail()
          return
        }
        sig.addEventListener('abort', fail, { once: true })
      }),
  )
}

/**
 * A fetch whose HEADERS arrive at once but whose BODY never finishes
 * (slow-loris). `bodyRejectsWith: 'terminated'` reproduces undici's real shape
 * for an abort landing mid-stream — a `TypeError: terminated` whose `cause` is
 * the AbortError, NOT an AbortError itself.
 */
function mockStallingBodyFetch(bodyRejectsWith: 'abort' | 'terminated' = 'abort'): void {
  vi.spyOn(globalThis, 'fetch').mockImplementation((_url, init) => {
    const sig = (init as RequestInit | undefined)?.signal
    const resp = {
      ok: true,
      status: 200,
      headers: new Headers(),
      text: () =>
        new Promise<string>((_resolve, reject) => {
          const fail = (): void => {
            const abortErr =
              sig?.reason instanceof Error
                ? sig.reason
                : new DOMException('The operation was aborted.', 'AbortError')
            reject(
              bodyRejectsWith === 'terminated'
                ? new TypeError('terminated', { cause: abortErr })
                : abortErr,
            )
          }
          if (sig === null || sig === undefined) return
          if (sig.aborted) {
            fail()
            return
          }
          sig.addEventListener('abort', fail, { once: true })
        }),
    }
    return Promise.resolve(resp as unknown as Response)
  })
}

function mockOkFetch(body: unknown = { ok: true }): void {
  vi.spyOn(globalThis, 'fetch').mockImplementation(() =>
    Promise.resolve(
      new Response(JSON.stringify(body), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    ),
  )
}

beforeEach(() => {
  draftModeMock.mockReset()
  draftModeMock.mockResolvedValue({ isEnabled: false })
  vi.restoreAllMocks()
})

describe('barkparkFetch — the configured fetchOptions.timeout is actually armed', () => {
  it('a hung origin aborts WITHIN the configured window and raises BarkparkTimeoutError carrying that window', async () => {
    mockHangingFetch()
    const startedAt = Date.now()
    const err = await barkparkFetch(makeCfg({ timeout: 80 }), { type: 'post' }).then(
      () => {
        throw new Error('unexpectedly resolved — the hung origin was never aborted')
      },
      (e: unknown) => e,
    )
    const elapsed = Date.now() - startedAt
    expect(err).toBeInstanceOf(BarkparkTimeoutError)
    // The deadline that FIRED is the one reported.
    expect((err as BarkparkTimeoutError).timeoutMs).toBe(80)
    // Not aborted instantly (that would pass a fix that aborts everything)…
    expect(elapsed).toBeGreaterThanOrEqual(70)
    // …and genuinely bounded, nowhere near the platform limit.
    expect(elapsed).toBeLessThan(2000)
  }, 3000)

  it('THE SUBJECT IS PRESENT: a normal fast request still succeeds under the same configured timeout', async () => {
    mockOkFetch({ documents: [{ _id: 'p1' }] })
    await expect(barkparkFetch(makeCfg({ timeout: 80 }), { type: 'post' })).resolves.toEqual({
      documents: [{ _id: 'p1' }],
    })
  })

  it('the deadline stays armed through the BODY read — a slow-loris body times out too', async () => {
    mockStallingBodyFetch()
    const err = await barkparkFetch(makeCfg({ timeout: 80 }), { type: 'post' }).then(
      () => {
        throw new Error('unexpectedly resolved — the stalled body was never aborted')
      },
      (e: unknown) => e,
    )
    expect(err).toBeInstanceOf(BarkparkTimeoutError)
    expect((err as BarkparkTimeoutError).timeoutMs).toBe(80)
  }, 3000)

  it("undici's real mid-body shape — a `TypeError: terminated` — is still reported as the timeout it is", async () => {
    mockStallingBodyFetch('terminated')
    const err = await barkparkFetch(makeCfg({ timeout: 80 }), { type: 'post' }).then(
      () => {
        throw new Error('unexpectedly resolved')
      },
      (e: unknown) => e,
    )
    expect(err).toBeInstanceOf(BarkparkTimeoutError)
    expect(err).not.toBeInstanceOf(TypeError)
    expect((err as BarkparkTimeoutError).timeoutMs).toBe(80)
  }, 3000)

  it('NO configured timeout leaves the request unbounded — no invented default is applied', async () => {
    mockHangingFetch()
    const settled = barkparkFetch(makeCfg(), { type: 'post' }).then(
      () => 'resolved',
      () => 'rejected',
    )
    const race = await Promise.race([
      settled,
      new Promise<string>((r) => setTimeout(() => r('still-pending'), 300)),
    ])
    expect(race).toBe('still-pending')
  }, 3000)
})

describe('barkparkFetch — deadline / caller-signal composition', () => {
  it('a caller abort is STILL a raw AbortError cancellation while a config deadline is armed', async () => {
    mockHangingFetch()
    const ac = new AbortController()
    const settled = barkparkFetch(makeCfg({ timeout: 5000 }), {
      type: 'post',
      signal: ac.signal,
    }).then(
      () => {
        throw new Error('unexpectedly resolved')
      },
      (e: unknown) => e,
    )
    ac.abort()
    const err = await settled
    expect(err).toBeInstanceOf(Error)
    expect((err as Error).name).toBe('AbortError')
    expect(err).not.toBeInstanceOf(BarkparkTimeoutError)
  }, 3000)

  it("a caller's AbortSignal.timeout wins the race and the error does NOT report the config's unrelated window", async () => {
    mockHangingFetch()
    const err = await barkparkFetch(makeCfg({ timeout: 30_000 }), {
      type: 'post',
      signal: AbortSignal.timeout(60),
    }).then(
      () => {
        throw new Error('unexpectedly resolved')
      },
      (e: unknown) => e,
    )
    expect(err).toBeInstanceOf(BarkparkTimeoutError)
    // 30000 never elapsed — reporting it would name a deadline that did not fire.
    expect((err as BarkparkTimeoutError).timeoutMs).toBeUndefined()
  }, 3000)

  it('the caller-signal abort listener is removed on a SUCCESSFUL exit (no listener leak)', async () => {
    mockOkFetch()
    const ac = new AbortController()
    const removeSpy = vi.spyOn(ac.signal, 'removeEventListener')
    await barkparkFetch(makeCfg({ timeout: 5000 }), { type: 'post', signal: ac.signal })
    expect(removeSpy).toHaveBeenCalled()
  })

  it('an ALREADY-aborted caller signal aborts the composed request immediately', async () => {
    mockHangingFetch()
    const ac = new AbortController()
    ac.abort()
    const err = await barkparkFetch(makeCfg({ timeout: 5000 }), {
      type: 'post',
      signal: ac.signal,
    }).then(
      () => {
        throw new Error('unexpectedly resolved')
      },
      (e: unknown) => e,
    )
    expect((err as Error).name).toBe('AbortError')
    expect(err).not.toBeInstanceOf(BarkparkTimeoutError)
  })
})
