// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Generic exponential-backoff retry with Retry-After override and optional
// per-attempt hook. Decoupled from transport — transport injects the hook
// used to rotate the Idempotency-Key between attempts.

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
  /** Called before each attempt > 1 — lets caller mutate headers (e.g. add Idempotency-Key). */
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

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function computeDelay(policy: RetryPolicy, attempt: number, err: unknown): number {
  if (err instanceof BarkparkRateLimitError && err.retryAfterMs !== undefined) {
    return Math.max(0, err.retryAfterMs)
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
): Promise<T> {
  const decide = policy.shouldRetry ?? defaultShouldRetry
  let attempt = 1
  for (;;) {
    try {
      return await fn(attempt)
    } catch (err) {
      if (attempt >= policy.maxAttempts || !decide(err, attempt)) throw err
      const delay = computeDelay(policy, attempt, err)
      if (delay > 0) await sleep(delay)
      attempt += 1
      if (policy.onBeforeAttempt) await policy.onBeforeAttempt(attempt, err)
    }
  }
}
