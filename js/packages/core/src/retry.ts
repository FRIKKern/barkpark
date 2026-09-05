// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// THE RETRY CONTRACT — narrow on purpose, and the narrowness is the point.
//
// This file used to retry any 5xx, plus every transport failure and timeout,
// three times, with no deadline arithmetic anywhere. That is strictly wider
// than the Go client this SDK shares an API with (internal/apiclient/retry.go),
// and the divergence was accidental rather than chosen. It is chosen now, and
// it is chosen NARROW, because the only measurement anyone has taken against
// this API says a broader retry is not a better one: an interleaved A/B of 40
// command pairs against the live box had the RETRYING binary at 19/40 against
// the non-retrying one at 24/40 — until a budget check existed
// (internal/apiclient/retry.go, `hasBudgetFor`). More attempts, WORSE outcomes.
//
// WHAT IS RETRIED, exhaustively. Three fault classes, kept apart on purpose —
// a reader handed one channel for all three cannot tell a throttle from a sick
// server from a dropped cable.
//
//   1. SERVED FAULT — the server answered, and its answer was a fault it calls
//      transient. Status >= 500 AND the envelope's machine code is
//      {@link RETRYABLE_SERVER_CODE} (today: `internal_error`, exactly the Go
//      client's `retryErrorCode`). 3 attempts on a read, 300ms base backoff.
//      Keyed on the CODE, never the status class: the API emits distinct 5xx
//      codes (`import_failed`, `export_failed`, `chat_create_failed`) that name
//      a real defect, and retrying one papers over the defect that produced it.
//      A 5xx with no code, or an unlisted code, is handed straight back.
//
//   2. TRANSPORT FAULT — no answer was served (`BarkparkNetworkError`: DNS,
//      offline, TLS, mid-body reset; `BarkparkTimeoutError`: the per-attempt
//      deadline elapsed). NOT retried under the default policy, matching the
//      Go client's deliberate refusal: "conflating a dropped connection with a
//      served fault would hide a different failure mode — the same host dropped
//      SYNs on 2026-08-21". It is retried ONLY under
//      {@link IDEMPOTENT_WRITE_POLICY}, which is the one place this SDK holds
//      evidence the Go transport cannot: a stable Idempotency-Key shared by
//      every attempt, so a replay of a request whose response was lost provably
//      cannot double-apply. That is also what the taxonomy already documented
//      ("Retried only for idempotent writes", errors.ts) and what the wide
//      default silently contradicted.
//
//   3. BACKPRESSURE — a 429. Always retryable, honouring the server's
//      Retry-After up to {@link MAX_RATE_LIMIT_BACKOFF_MS}. A throttle is not a
//      fault; the server is healthy and is telling us the rate, and it halted
//      before the controller so no write can have landed.
//
// WHICH METHODS. The Go transport gates on GET/HEAD because a bare
// RoundTripper cannot tell a read-shaped POST from a mutating one. This layer
// does not have to guess: the caller declares `kind: 'read' | 'write'`, and
// writes get `maxAttempts: 1` unless they opt in with a stable idempotency key.
// That is a DELIBERATE difference from the Go rule, not an oversight — it is
// why the query endpoint (a read-shaped POST) is still retried here and is not
// retried by `bp`.
//
// AND EVERY RETRY IS BUDGET-CHECKED. See {@link MIN_ATTEMPT_BUDGET_MS}: a
// retry that cannot finish inside the caller's remaining time is not attempted
// at all, because spending the deadline on a sleep converts a would-be success
// into an abort. This is the port of `hasBudgetFor`, and it is the half of the
// Go client the row calls "unambiguously better".
//
// Mechanically: exponential backoff with Retry-After override and an optional
// per-attempt hook, decoupled from transport. The backoff sleep is abortable
// via the caller's AbortSignal — but honouring an abort is NOT the same as
// declining to start an attempt that cannot finish, which is what the budget
// check adds.

import {
  BarkparkAPIError,
  BarkparkNetworkError,
  BarkparkRateLimitError,
  BarkparkTimeoutError,
} from './errors'

/**
 * @internal Describes the transport's retry engine, which is configured
 * publicly by intent rather than by policy object: a caller sets `retry: true`
 * on a write (with `idempotencyKey` / `timeoutMs`) and this package picks the
 * matching policy. Exporting the policy shape would let a consumer hand-build
 * one, which the transport has no exported entry point to accept — the knob
 * would be typed but unreachable.
 */
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
  /** Default: {@link defaultShouldRetry} — a 429, or a >=5xx whose server code
   *  is {@link RETRYABLE_SERVER_CODE}. Transport faults are excluded; see
   *  the contract at the top of this file. */
  shouldRetry?: (err: unknown, attempt: number) => boolean
  /** Absolute epoch-ms deadline for the WHOLE call, retries and backoff sleeps
   *  included. When set, a retry is DECLINED (and the last error thrown
   *  immediately) unless the wait plus {@link MIN_ATTEMPT_BUDGET_MS} still fits
   *  inside it. Undefined means unbounded — an unbounded caller has not asked
   *  us to hurry, exactly as the Go client treats a context with no deadline. */
  deadlineAt?: number
  /** @internal Injectable clock, so the budget check is testable without
   *  spending real seconds. Defaults to `Date.now`. */
  now?: () => number
}

/**
 * @internal A tuned default, not a contract. These three constants are the
 * transport's own calibration and are expected to move as the server's
 * behaviour is measured; publishing them would freeze tuning numbers into the
 * package's public API and invite consumers to depend on a specific backoff
 * curve. The supported knobs are `retry` and `timeoutMs` on the call.
 */
export const DEFAULT_READ_POLICY: RetryPolicy = {
  maxAttempts: 3,
  baseMs: 300,
  maxBackoffMs: 5000,
  jitter: true,
}

/**
 * @internal A tuned default, not a contract — see {@link DEFAULT_READ_POLICY}.
 * That writes do not retry by default is the durable fact (ADR-002 bullet 8),
 * and it is already observable: it is what `retry: false` means on a commit.
 * The numbers encoding it are not part of the public surface.
 */
export const DEFAULT_WRITE_POLICY: RetryPolicy = {
  maxAttempts: 1,
  baseMs: 0,
  maxBackoffMs: 0,
  jitter: false,
}

/**
 * @internal A tuned default, not a contract — see {@link DEFAULT_READ_POLICY}.
 * A consumer selects this policy by opting in (`retry: true` on a write, which
 * makes the transport carry one stable Idempotency-Key across attempts); they
 * select it by intent, never by naming the constant.
 */
export const IDEMPOTENT_WRITE_POLICY: RetryPolicy = {
  maxAttempts: 3,
  baseMs: 400,
  maxBackoffMs: 8000,
  jitter: true,
  // The one policy that also repeats a TRANSPORT fault — see
  // {@link idempotentWriteShouldRetry} for the evidence that permits it.
  // (Function declarations hoist, so naming it above its definition is fine.)
  shouldRetry: idempotentWriteShouldRetry,
}

/**
 * The ONLY server error codes a >=5xx response may carry and still be retried.
 *
 * @internal Deliberately identical to the Go client's `retryErrorCode`
 * (internal/apiclient/retry.go): `internal_error` is the generic server-fault
 * code from `Barkpark.Content.Errors`, the one the server itself annotates
 * "Retry shortly". Everything else a 5xx can carry names a specific cause —
 * `import_failed`, `export_failed`, `chat_create_failed`, `storage_unavailable`,
 * `runtime_unavailable`, `runtime_capacity` — and repeating those either papers
 * over a defect or hammers a component that has already said it is out of room.
 *
 * Widening this to a SET is a CROSS-CLIENT decision, not a local one: the whole
 * point of pinning it here is that `bp` and this SDK stop disagreeing about
 * what a 5xx means. Add a code to both, with a measurement, or to neither.
 */
export const RETRYABLE_SERVER_CODE = 'internal_error'

/**
 * @internal Fault class 1 of the contract at the top of this file: the server
 * ANSWERED, and its answer is a fault it calls transient. Keyed on the
 * envelope's machine code, never on the status class — a 502 from a proxy and a
 * 500 naming a real defect are different faults and both are handed back.
 */
export function isRetryableServerFault(err: unknown): boolean {
  // Three things fall out of this one expression and each is deliberate. A 429
  // needs no arm: `BarkparkRateLimitError` extends `BarkparkAPIError` and its
  // status is below 500. `?? 0` folds "no status" into "not a 5xx". And a 5xx
  // carrying NO code fails the equality, because an absent code is not evidence
  // of a transient fault.
  return (
    err instanceof BarkparkAPIError &&
    (err.status ?? 0) >= 500 &&
    err.serverCode === RETRYABLE_SERVER_CODE
  )
}

/**
 * @internal Fault class 2: NO answer was served. A dropped connection, a TLS
 * failure, a mid-body reset, or an elapsed per-attempt deadline. This predicate
 * exists so the served-fault arm above can never absorb one of these — the Go
 * client's stated reason for refusing them is that conflating the two hides a
 * distinct failure mode, and a shared arm is exactly that conflation.
 */
export function isTransportFault(err: unknown): boolean {
  return err instanceof BarkparkNetworkError || err instanceof BarkparkTimeoutError
}

/**
 * @internal The default arm of a hook (`RetryPolicy.shouldRetry`) that has no
 * exported way to be supplied, so there is no supported call site for it. The
 * classification it encodes is already public in a more useful form: the error
 * taxonomy itself is exported, so a consumer deciding whether to re-issue a
 * call can test the caught error's class or its `code` literal directly.
 *
 * A transport fault is NOT retried here. That is the narrowing, and it is the
 * Go client's refusal ported verbatim: only {@link idempotentWriteShouldRetry}
 * takes one on, and only because a stable Idempotency-Key makes the replay
 * provably safe.
 */
export function defaultShouldRetry(err: unknown): boolean {
  // No transport arm is needed to EXCLUDE one: a transport fault is not a
  // `BarkparkAPIError`, so the served-fault predicate already refuses it. The
  // refusal is asserted directly in tests/retry.test.ts so it cannot rot.
  return err instanceof BarkparkRateLimitError || isRetryableServerFault(err)
}

/**
 * @internal The one policy that may repeat a transport fault, and the evidence
 * that lets it: `retryPolicy: 'on-idempotency-key'` sets ONE stable
 * Idempotency-Key shared by every attempt, so a request whose response was lost
 * in flight collapses onto the original server-side instead of double-applying.
 * The Go transport has no equivalent and therefore refuses; this one does, and
 * the taxonomy has documented the exception all along ("Retried only for
 * idempotent writes", errors.ts).
 */
export function idempotentWriteShouldRetry(err: unknown): boolean {
  return isTransportFault(err) || defaultShouldRetry(err)
}

/**
 * Ceiling on a server-supplied rate-limit backoff. Without it a `Retry-After:
 * 3600` (whether hostile or misconfigured) would pin a single request for ~1h.
 * We honor the server's hint up to this bound, then cap — the caller can still
 * abort sooner via the signal.
 *
 * @internal A defensive ceiling this package applies on the caller's behalf,
 * not a value they act on. What a consumer needs is the server's actual hint,
 * and they already have it: `err.retryAfterMs` on a caught
 * `BarkparkRateLimitError`. Publishing the cap would only let them re-derive a
 * decision the transport has already made for them.
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

/**
 * The time a retry must be able to leave for the NEXT attempt after its wait.
 *
 * @internal The port of `minAttemptBudget` (internal/apiclient/retry.go), and
 * the same number for the same reason: a healthy response off this API arrives
 * in well under 100ms, so one second is generous enough that a merely-slow
 * server still gets its chance and tight enough that the check actually bites
 * near the deadline. Not published — a consumer bounds a call with
 * `deadlineMs`, and re-deriving the transport's internal allowance from it
 * would only let them predict a decision already made for them.
 */
export const MIN_ATTEMPT_BUDGET_MS = 1000

/**
 * @internal Does the caller's remaining time leave room to wait `delayMs` AND
 * still make a realistic attempt?
 *
 * A policy with NO deadline always has budget — an unbounded caller has not
 * asked us to hurry, exactly as `hasBudgetFor` treats a context whose
 * `Deadline()` is unset. This is the check whose absence the Go client measured
 * at 19/40 vs 24/40: without it, three attempts plus their sleeps eat the whole
 * budget on a box that is sick AND slow, and the caller gets an abort instead
 * of the answer the second attempt would have produced.
 */
export function hasBudgetFor(policy: RetryPolicy, delayMs: number): boolean {
  return (
    policy.deadlineAt === undefined ||
    policy.deadlineAt - (policy.now ?? Date.now)() > delayMs + MIN_ATTEMPT_BUDGET_MS
  )
}

/**
 * @internal A general-purpose retry loop, and that is exactly the problem with
 * exporting it: it would become a public utility with no Barkpark meaning,
 * pinning this signature as a permanent contract for a package whose job is an
 * HTTP client. Consumers who want a generic retry combinator are better served
 * by one; the retry behaviour that IS Barkpark-specific — idempotency-key reuse
 * across attempts, Retry-After honouring — is reached with `retry: true` on a
 * write, where the transport wires those in.
 */
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
      // BUDGET CHECK, before the sleep and before the attempt it would buy.
      // Honouring an abort mid-backoff (which `sleep` below already does) is
      // NOT the same as declining to START an attempt that cannot finish: the
      // former still spends the caller's remaining time on a wait and then
      // hands back a cancellation, the latter hands back the honest error now,
      // with nothing spent the caller did not authorise.
      if (!hasBudgetFor(policy, delay)) throw err
      // Abortable: a caller aborting mid-backoff (e.g. during a 429/5xx wait)
      // rejects here instead of blocking until the sleep elapses.
      if (delay > 0) await sleep(delay, signal)
      attempt += 1
      if (policy.onBeforeAttempt) await policy.onBeforeAttempt(attempt, err)
    }
  }
}
