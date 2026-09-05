// THE MEASUREMENT — an interleaved A/B of the OLD (wide) retry policy against
// the NEW (narrowed + budget-checked) one, over 40 command pairs.
//
// WHY IT EXISTS. The Go client this SDK shares an API with carries the only
// number anyone has measured about retrying against this API, written into
// `hasBudgetFor` (internal/apiclient/retry.go):
//
//     "an interleaved A/B of 40 command pairs against the live box had the
//      retrying binary at 19/40 against the non-retrying one at 24/40 until
//      this check existed."
//
// More attempts, WORSE outcomes. That number was never applied to this SDK, and
// narrowing a retry policy on intuition is exactly the mistake it records — so
// the narrowing in src/retry.ts is measured here before it is believed.
//
// SKIPPED BY DEFAULT — arm A talks to the live box. Run it deliberately:
//
//     BARKPARK_RETRY_AB=1 pnpm --filter @barkpark/core exec vitest run \
//       tests/retry-ab.test.ts --maxWorkers=2
//
// WHAT IS UNDER TEST. Both arms drive the real `retry` loop from src/retry.ts.
// Only the POLICY differs, and the old one is reconstructed exactly (see
// {@link wideShouldRetry}). It is the loop and the policy that this change
// touches; that the transport reaches them is proved separately, end to end, in
// tests/retry-deadline-budget.test.ts.
//
// INTERLEAVING. The criterion is an interleaved A/B, not a sequenced one: a box
// that gets slower — or warms up — mid-run would otherwise bias whichever arm
// ran second. This harness alternates pair by pair AND flips the within-pair
// order on odd pairs, so neither arm holds the first slot more than half the
// time. That is strictly stronger than pair-by-pair alternation alone.
//
// SUCCESS, DEFINED. A command succeeds when, inside the caller's budget, it
// yields the SERVER'S OWN ANSWER — a 200 payload, or the server's error
// envelope. It fails when the budget elapses first and the caller is handed
// nothing but an abort, holding no information about what the server said. That
// is verbatim the Go client's framing of the regression it measured: "the
// caller got a context deadline instead of the answer".
import { appendFileSync } from 'node:fs'
import { describe, it, expect } from 'vitest'
import { retry, defaultShouldRetry, type RetryPolicy } from '../src/retry'
import {
  BarkparkAPIError,
  BarkparkNetworkError,
  BarkparkRateLimitError,
  BarkparkTimeoutError,
} from '../src/errors'

const RUN = process.env.BARKPARK_RETRY_AB === '1'
const PAIRS = 40
/** The caller's whole-call budget, mirroring the Go client's 5s http.Client.Timeout. */
const BUDGET_MS = 5_000
const BASE_MS = 300
const MAX_ATTEMPTS = 3

/**
 * The policy this change replaced, reconstructed exactly: any >=5xx by status
 * CLASS, plus every transport fault and timeout, three attempts, and no
 * deadline arithmetic anywhere. This is arm A of the A/B — the control. It is
 * not sentiment; deleting it makes the number below unreproducible.
 */
function wideShouldRetry(err: unknown): boolean {
  if (err instanceof BarkparkNetworkError) return true
  if (err instanceof BarkparkTimeoutError) return true
  if (err instanceof BarkparkRateLimitError) return true
  if (err instanceof BarkparkAPIError && err.status !== undefined && err.status >= 500) return true
  return false
}

interface Tally {
  ok: number
  budgetBlown: number
  requests: number
  totalMs: number
}
const tally = (): Tally => ({ ok: 0, budgetBlown: 0, requests: 0, totalMs: 0 })

/** stdout, plus an optional file — a vitest worker's console can be swallowed,
 *  and a measurement nobody can read is not a measurement. */
function emit(text: string): void {
  process.stdout.write(`${text}\n`)
  const out = process.env.BARKPARK_RETRY_AB_OUT
  if (out !== undefined && out !== '') appendFileSync(out, `${text}\n`)
}

function report(label: string, old_: Tally, neu: Tally): string {
  return [
    ``,
    `  ${label}`,
    `  ${'='.repeat(label.length)}`,
    `  OLD  any-5xx + transport, 3 attempts, no budget : ${old_.ok}/${PAIRS}` +
      `   requests=${old_.requests}  mean=${Math.round(old_.totalMs / PAIRS)}ms`,
    `  NEW  internal_error only, budget-checked        : ${neu.ok}/${PAIRS}` +
      `   requests=${neu.requests}  mean=${Math.round(neu.totalMs / PAIRS)}ms`,
    ``,
  ].join('\n')
}

/** The deterministic backoff the loop will have slept before `attempt`. */
const backoffBefore = (attempt: number) => Math.min(BASE_MS * Math.pow(2, attempt - 2), 5_000)

/**
 * One command, on a clock the caller controls. `attemptMs` reports how long the
 * server took to answer each attempt; the harness folds that plus the loop's
 * backoff into `clock`, which is what the budget check reads. The OLD arm gets
 * no deadline at all — that IS the old behaviour, not a handicap.
 */
async function command(
  arm: 'old' | 'new',
  t: Tally,
  attempt: (n: number) => Promise<{ ms: number; fault?: unknown }>,
): Promise<void> {
  let clock = 0
  let requests = 0
  const policy: RetryPolicy = {
    maxAttempts: MAX_ATTEMPTS,
    baseMs: BASE_MS,
    maxBackoffMs: 5_000,
    jitter: false,
    now: () => clock,
    onBeforeAttempt: (n) => {
      clock += backoffBefore(n)
    },
    ...(arm === 'old'
      ? { shouldRetry: wideShouldRetry }
      : { shouldRetry: defaultShouldRetry, deadlineAt: BUDGET_MS }),
  }

  const outcome = await retry<'answered'>(async (n) => {
    requests += 1
    const { ms, fault } = await attempt(n)
    clock += ms
    if (fault !== undefined) throw fault
    return 'answered'
  }, policy)
    .then(() => 'answered' as const)
    // The server's own envelope IS an answer — see SUCCESS, DEFINED above.
    .catch((e) => (e instanceof BarkparkAPIError ? ('answered' as const) : ('no-answer' as const)))

  t.requests += requests
  t.totalMs += Math.min(clock, BUDGET_MS)
  if (outcome === 'answered' && clock <= BUDGET_MS) t.ok += 1
  else t.budgetBlown += 1
}

/** Interleaved, order-flipped, PAIRS pairs. `mk` builds one arm's attempt fn. */
async function interleave(
  mk: (pair: number) => (n: number) => Promise<{ ms: number; fault?: unknown }>,
): Promise<[Tally, Tally]> {
  const old_ = tally()
  const neu = tally()
  for (let i = 0; i < PAIRS; i += 1) {
    if (i % 2 === 0) {
      await command('old', old_, mk(i))
      await command('new', neu, mk(i))
    } else {
      await command('new', neu, mk(i))
      await command('old', old_, mk(i))
    }
  }
  return [old_, neu]
}

// ---------------------------------------------------------------------------
// ARM A — LIVE. Real HTTP, real latency, against the real box.
// ---------------------------------------------------------------------------

describe.skipIf(!RUN)('A/B arm A — live box', () => {
  const BASE = process.env.BARKPARK_API_URL ?? 'http://89.167.28.206'
  const URL = `${BASE}/v1/data/query/production/post?query=${encodeURIComponent('*[_type=="post"][0..2]')}`

  it(
    `runs ${PAIRS} interleaved command pairs against ${BASE}`,
    async () => {
      const live = () => async () => {
        const started = Date.now()
        try {
          const res = await fetch(URL, { headers: { accept: 'application/json' } })
          const body = (await res.json().catch(() => ({}))) as { error?: { code?: string } }
          const ms = Date.now() - started
          if (res.ok) return { ms }
          // `exactOptionalPropertyTypes`: a missing code must be an ABSENT key,
          // not an explicit `undefined` — and the difference is real here, since
          // a 5xx with no code is one of the things the new policy refuses.
          const code = body.error?.code
          const opts =
            code === undefined ? { status: res.status } : { status: res.status, serverCode: code }
          return { ms, fault: new BarkparkAPIError('live', opts) }
        } catch (e) {
          return { ms: Date.now() - started, fault: new BarkparkNetworkError(String(e)) }
        }
      }
      const [old_, neu] = await interleave(live)
      emit(report(`ARM A — LIVE, ${BASE}`, old_, neu))
      expect(old_.ok + old_.budgetBlown).toBe(PAIRS)
      expect(neu.ok + neu.budgetBlown).toBe(PAIRS)
      // The claim a green live arm buys: on a HEALTHY box the narrowing costs
      // nothing. The hazard itself is arm B's job — a healthy box cannot show it.
      expect(neu.ok).toBeGreaterThanOrEqual(old_.ok)
    },
    10 * 60_000,
  )
})

// ---------------------------------------------------------------------------
// ARM B — SIMULATED, AND LABELLED AS SUCH.
//
// A healthy box cannot exhibit the regression: with nothing failing, both arms
// make one request and both score 40/40. The Go number was taken against a box
// that was SICK AND SLOW, and this arm reproduces that CONDITION rather than
// pretending to have found one.
//
// THE DISTRIBUTION IS AN ASSUMPTION, not a measurement. Two of its three
// parameters are the row's own recorded observations; the third is not:
//
//   TTFB   uniform over [350ms, 4500ms]  — the guerrilla band recorded 2026-08-23
//   budget 5000ms                        — the Go client's http.Client.Timeout
//   fault  45% of responses are 500 `internal_error`  <-- INVENTED. No fault
//                                           rate was ever recorded for that box.
//
// So arm B is an honest substitute for a sick-box A/B, not a sick-box A/B. It
// shows the MECHANISM under a stated distribution; it does not establish a rate.
// It runs on the harness's virtual clock, so it costs no real seconds waiting
// for a slow server and its arithmetic is exact.
// ---------------------------------------------------------------------------

describe.skipIf(!RUN)('A/B arm B — simulated sick-and-slow box', () => {
  const TTFB_MIN = 350
  const TTFB_MAX = 4_500
  const FAULT_RATE = 0.45

  /** Seeded LCG, so both arms of a pair meet the IDENTICAL box. */
  function rng(seed: number) {
    let s = seed >>> 0
    return () => {
      s = (s * 1664525 + 1013904223) >>> 0
      return s / 0x1_0000_0000
    }
  }

  it(
    `runs ${PAIRS} interleaved command pairs on a virtual clock`,
    async () => {
      const sick = (pair: number) => {
        const draw = rng(0xbeef + pair)
        return async () => {
          const ms = TTFB_MIN + draw() * (TTFB_MAX - TTFB_MIN)
          const faulty = draw() < FAULT_RATE
          return faulty
            ? {
                ms,
                fault: new BarkparkAPIError('server said so', {
                  status: 500,
                  serverCode: 'internal_error',
                }),
              }
            : { ms }
        }
      }
      const [old_, neu] = await interleave(sick)
      emit(
        report(
          `ARM B — SIMULATED  TTFB ${TTFB_MIN}-${TTFB_MAX}ms, ${FAULT_RATE * 100}% 500 internal_error, budget ${BUDGET_MS}ms`,
          old_,
          neu,
        ),
      )
      expect(old_.ok + old_.budgetBlown).toBe(PAIRS)
      expect(neu.ok + neu.budgetBlown).toBe(PAIRS)
      // THE POINT, and the reason the check exists at all: declining a retry that
      // cannot finish hands the caller the server's answer instead of an abort.
      expect(neu.ok).toBeGreaterThan(old_.ok)
    },
    10 * 60_000,
  )
})
