// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Generic exponential-backoff retry with Retry-After override and optional
// per-attempt hook. Decoupled from transport — for idempotent writes transport
// sets ONE stable Idempotency-Key shared across every attempt (it is NOT rotated
// between attempts), so the server's dedup can collapse a retried write onto the
// original. The backoff sleep is abortable via the caller's AbortSignal.

import {
  BarkparkAPIError,
  BarkparkNetworkError,
  BarkparkRateLimitError,
  BarkparkTimeoutError,
} from './errors'

export interface RetryPolicy {
  /** Max attempts including the first. 3 for reads, 1 for writes (unless on-idempotency-key). */
  maxAttempts: number
  /** Base delay in ms for exponential backoff. */
  baseMs: number
  /** Cap on backoff. */
  maxBackoffMs: number
  /** If true, add ±25% jitter. */
  jitter?: boolean
  /** Called before each attempt > 1 — lets caller mutate headers before the retry. */
  onBeforeAttempt?: (attempt: number, prevError: unknown) => void | Promise<void>
  /** Default: retry BarkparkNetworkError | BarkparkTimeoutError | BarkparkRateLimitError | 5xx BarkparkAPIError. */
  shouldRetry?: (err: unknown, attempt: number) => boolean
}

export const DEFAULT_READ_POLICY: RetryPolicy = {
  maxAttempts: 3,
  baseMs: 300,
  maxBackoffMs: 5000,
  jitter: true,
}

export const DEFAULT_WRITE_POLICY: RetryPolicy = {
  maxAttempts: 1,
  baseMs: 0,
  maxBackoffMs: 0,
  jitter: false,
}

export const IDEMPOTENT_WRITE_POLICY: RetryPolicy = {
  maxAttempts: 3,
  baseMs: 400,
  maxBackoffMs: 8000,
  jitter: true,
}

export function defaultShouldRetry(err: unknown): boolean {
  if (err instanceof BarkparkNetworkError) return true
  if (err instanceof BarkparkTimeoutError) return true
  if (err instanceof BarkparkRateLimitError) return true
  if (err instanceof BarkparkAPIError && err.status !== undefined && err.status >= 500) return true
  return false
}

/**
 * Ceiling on a server-supplied rate-limit backoff. Without it a `Retry-After:
 * 3600` (whether hostile or misconfigured) would pin a single request for ~1h.
 * We honor the server's hint up to this bound, then cap — the caller can still
 * abort sooner via the signal.
 */
export const MAX_RATE_LIMIT_BACKOFF_MS = 60_000

/**
 * Build the cancellation error we reject a backoff sleep with. Mirrors the
 * transport's abort shape (callers detect cancellation via `err.name ===
 * 'AbortError'`): prefer the signal's own `reason` — exactly what a fetch abort
 * surfaces — falling back to a synthesized AbortError when the runtime supplies none.
 */
function abortError(signal: AbortSignal): unknown {
  const reason: unknown = (signal as { reason?: unknown }).reason
  if (reason !== undefined && reason !== null) return reason
  const err = new Error('The operation was aborted.')
  err.name = 'AbortError'
  return err
}

// Sleep `ms`, resolving normally on elapse. If `signal` aborts first, reject
// immediately with the abort error and clean up the timer + listener (no leak).
function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal !== undefined && signal.aborted) {
      reject(abortError(signal))
      return
    }
    const onAbort = () => {
      clearTimeout(timer)
      reject(abortError(signal as AbortSignal))
    }
    const timer = setTimeout(() => {
      if (signal !== undefined) signal.removeEventListener('abort', onAbort)
      resolve()
    }, ms)
    if (signal !== undefined) signal.addEventListener('abort', onAbort, { once: true })
  })
}

function computeDelay(policy: RetryPolicy, attempt: number, err: unknown): number {
  if (err instanceof BarkparkRateLimitError && err.retryAfterMs !== undefined) {
    return Math.min(Math.max(0, err.retryAfterMs), MAX_RATE_LIMIT_BACKOFF_MS)
  }
  const backoff = policy.baseMs * Math.pow(2, attempt - 1)
  let delay = Math.min(backoff, policy.maxBackoffMs)
  if (policy.jitter === true && delay > 0) {
    delay = delay * (1 + (Math.random() * 0.5 - 0.25))
  }
  return delay
}

export async function retry<T>(
  fn: (attempt: number) => Promise<T>,
  policy: RetryPolicy,
  signal?: AbortSignal,
): Promise<T> {
  const decide = policy.shouldRetry ?? defaultShouldRetry
  let attempt = 1
  for (;;) {
    try {
      return await fn(attempt)
    } catch (err) {
      if (attempt >= policy.maxAttempts || !decide(err, attempt)) throw err
      const delay = computeDelay(policy, attempt, err)
      // Abortable: a caller aborting mid-backoff (e.g. during a 429/5xx wait)
      // rejects here instead of blocking until the sleep elapses.
      if (delay > 0) await sleep(delay, signal)
      attempt += 1
      if (policy.onBeforeAttempt) await policy.onBeforeAttempt(attempt, err)
    }
  }
}
