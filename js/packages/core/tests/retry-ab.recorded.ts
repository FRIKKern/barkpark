// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// THE RECORDED MEASUREMENT — a transcript, not a computation.
//
// Every value below was TYPED BY HAND from a run of the A/B harness. This file
// imports NOTHING. That is the whole design: the pin in retry-ab.test.ts
// compares the live policy inputs against this transcript, and a guard whose
// expected value is read out of the thing it guards is inert — it would agree
// with any edit, forever, and report green while the measurement rotted.
//
// A LINT-STYLE ARM IN retry-ab.test.ts READS THIS FILE'S SOURCE TEXT and fails
// if an `import` ever appears in it. Do not add one, not even for a type.
//
// ---------------------------------------------------------------------------
// HOW TO RE-RECORD, exactly. Run the harness:
//
//     BARKPARK_RETRY_AB=1 pnpm --filter @barkpark/core exec vitest run \
//       tests/retry-ab.test.ts --maxWorkers=2
//
// Arm B is deterministic (seeded LCG on a virtual clock), so it reproduces
// byte-for-byte on any machine; arm A talks to the live box and its numbers
// move with the box's health. Copy the printed ARM A / ARM B blocks into
// `RECORDED_REPORT` below VERBATIM, then update `RECORDED_AT`, and update
// `RECORDED_POLICY_INPUTS` to the values the run actually used. Numbers go
// HERE — never into the pin's assertion, and never by editing the live
// constants to match a stale transcript.
// ---------------------------------------------------------------------------

/** The run this transcript came from. */
export const RECORDED_AT = '2026-09-05'

/** The PR whose body first carried these numbers, and the only other place they lived. */
export const RECORDED_IN_PR = 16218

/** The re-arm command, quoted in the pin's failure message so a stranger can follow it. */
export const REARM_COMMAND =
  'BARKPARK_RETRY_AB=1 pnpm --filter @barkpark/core exec vitest run tests/retry-ab.test.ts --maxWorkers=2'

/** Where a fresh run's numbers go. Quoted in the pin's failure message. */
export const RECORD_NUMBERS_IN = 'js/packages/core/tests/retry-ab.recorded.ts'

/**
 * The policy inputs AS THEY STOOD when the numbers below were taken. Literals,
 * copied by hand. The pin diffs the live constants against this map key by key.
 *
 * Keys 1-6 are the shipped policy (src/retry.ts). Keys 7-13 are the harness
 * parameters (tests/retry-ab-inputs.ts). Both halves determine the result: the
 * first is what is under measurement, the second is the conditions it was
 * measured under, and a change to either makes the numbers describe something
 * that is no longer shipping.
 */
export const RECORDED_POLICY_INPUTS: Readonly<Record<string, string>> = {
  DEFAULT_READ_POLICY: '{"maxAttempts":3,"baseMs":300,"maxBackoffMs":5000,"jitter":true}',
  DEFAULT_WRITE_POLICY: '{"maxAttempts":1,"baseMs":0,"maxBackoffMs":0,"jitter":false}',
  IDEMPOTENT_WRITE_POLICY: '{"maxAttempts":3,"baseMs":400,"maxBackoffMs":8000,"jitter":true}',
  RETRYABLE_SERVER_CODE: '"internal_error"',
  MAX_RATE_LIMIT_BACKOFF_MS: '60000',
  MIN_ATTEMPT_BUDGET_MS: '1000',
  'harness.PAIRS': '40',
  'harness.BUDGET_MS': '5000',
  'harness.BASE_MS': '300',
  'harness.MAX_BACKOFF_MS': '5000',
  'harness.MAX_ATTEMPTS': '3',
  'harness.TTFB_MIN': '350',
  'harness.TTFB_MAX': '4500',
  'harness.FAULT_RATE': '0.45',
}

/**
 * The harness output, verbatim. Arm A is a HEALTHY box and shows nothing (40/40
 * vs 40/40 is not evidence for the change); arm B is where the claim lives.
 */
export const RECORDED_REPORT = `
ARM A — LIVE, http://89.167.28.206
OLD  any-5xx + transport, 3 attempts, no budget : 40/40   requests=40  mean=31ms
NEW  internal_error only, budget-checked        : 40/40   requests=40  mean=30ms

ARM B — SIMULATED  TTFB 350-4500ms, 45% 500 internal_error, budget 5000ms
OLD  any-5xx + transport, 3 attempts, no budget : 27/40   requests=70  mean=2724ms
NEW  internal_error only, budget-checked        : 32/40   requests=63  mean=2615ms
`.trim()

/**
 * The single number the narrowing rests on, pulled out so it is greppable:
 * on a sick-and-slow box the OLD wide policy answered 27 of 40 commands inside
 * the caller's budget and the NEW narrowed, budget-checked one answered 32/40 —
 * from FEWER requests (70 -> 63). More attempts, worse outcomes.
 */
export const RECORDED_SICK_BOX_RESULT = { old: '27/40', neu: '32/40' } as const
