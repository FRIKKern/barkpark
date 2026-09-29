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
import { appendFileSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, it, expect } from 'vitest'
import {
  retry,
  defaultShouldRetry,
  DEFAULT_READ_POLICY,
  DEFAULT_WRITE_POLICY,
  IDEMPOTENT_WRITE_POLICY,
  RETRYABLE_SERVER_CODE,
  MAX_RATE_LIMIT_BACKOFF_MS,
  MIN_ATTEMPT_BUDGET_MS,
  type RetryPolicy,
} from '../src/retry'
import {
  RECORDED_AT,
  RECORDED_IN_PR,
  RECORDED_POLICY_INPUTS,
  RECORDED_REPORT,
  RECORDED_SICK_BOX_RESULT,
  REARM_COMMAND,
  RECORD_NUMBERS_IN,
} from './retry-ab.recorded'
import {
  PAIRS,
  BUDGET_MS,
  BASE_MS,
  MAX_BACKOFF_MS,
  MAX_ATTEMPTS,
  TTFB_MIN,
  TTFB_MAX,
  FAULT_RATE,
} from './retry-ab-inputs'
import {
  BarkparkAPIError,
  BarkparkNetworkError,
  BarkparkRateLimitError,
  BarkparkTimeoutError,
} from '../src/errors'

const RUN = process.env.BARKPARK_RETRY_AB === '1'

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
const backoffBefore = (attempt: number) =>
  Math.min(BASE_MS * Math.pow(2, attempt - 2), MAX_BACKOFF_MS)

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
    maxBackoffMs: MAX_BACKOFF_MS,
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

// ---------------------------------------------------------------------------
// THE PIN — NOT env-gated. This is the only part of this file CI runs.
//
// WHY. Both arms above are behind BARKPARK_RETRY_AB, so a green CI run never
// re-runs them, and the numbers they produced lived nowhere but PR 16218's body
// and a ledger stamp. Move a policy constant and the justification for the
// narrowing silently becomes a statement about code that no longer ships, with
// no signal anywhere.
//
// WHAT A GREEN HERE BUYS, precisely. It does NOT re-verify 27/40 vs 32/40 — no
// measurement happens in an ordinary run, nothing is fetched, arm A is skipped
// and no request reaches the live box. It buys exactly one claim: THE RECORDED
// NUMBERS STILL DESCRIBE THE POLICY THAT SHIPS. That is a shelf-life check, not
// a re-measurement.
//
// WHY IT IS NOT A CHANGE-DETECTOR. It compares VALUES, read through the
// module's exported constants — not file text, not a hash. Renaming a local,
// rewording a comment, reordering a function, or reformatting src/retry.ts
// moves nothing it reads. Only an actual policy input moving fires it.
//
// WHY THE EXPECTATION CANNOT LAUNDER ITSELF. `retry-ab.recorded.ts` is a
// hand-typed transcript that imports nothing; if it ever imported the live
// constants it would agree with every future edit and this pin would be inert.
// The second `it` below reads that file's SOURCE TEXT and fails on any import.
// ---------------------------------------------------------------------------

describe('recorded A/B measurement — shelf-life pin', () => {
  /**
   * The live policy inputs, serialized the same way the transcript records
   * them. Object policies are written out field by field in a fixed order so a
   * reordering of the literal is not mistaken for a change of value.
   */
  function livePolicyInputs(): Record<string, string> {
    const policy = (p: RetryPolicy): string =>
      JSON.stringify({
        maxAttempts: p.maxAttempts,
        baseMs: p.baseMs,
        maxBackoffMs: p.maxBackoffMs,
        jitter: p.jitter === true,
      })
    return {
      DEFAULT_READ_POLICY: policy(DEFAULT_READ_POLICY),
      DEFAULT_WRITE_POLICY: policy(DEFAULT_WRITE_POLICY),
      IDEMPOTENT_WRITE_POLICY: policy(IDEMPOTENT_WRITE_POLICY),
      RETRYABLE_SERVER_CODE: JSON.stringify(RETRYABLE_SERVER_CODE),
      MAX_RATE_LIMIT_BACKOFF_MS: String(MAX_RATE_LIMIT_BACKOFF_MS),
      MIN_ATTEMPT_BUDGET_MS: String(MIN_ATTEMPT_BUDGET_MS),
      'harness.PAIRS': String(PAIRS),
      'harness.BUDGET_MS': String(BUDGET_MS),
      'harness.BASE_MS': String(BASE_MS),
      'harness.MAX_BACKOFF_MS': String(MAX_BACKOFF_MS),
      'harness.MAX_ATTEMPTS': String(MAX_ATTEMPTS),
      'harness.TTFB_MIN': String(TTFB_MIN),
      'harness.TTFB_MAX': String(TTFB_MAX),
      'harness.FAULT_RATE': String(FAULT_RATE),
    }
  }

  /** The red a stranger has to act on. It must say re-MEASURE, not re-EDIT. */
  function staleMeasurementReport(drift: string[]): string {
    return [
      ``,
      `THE POLICY MOVED AND ITS MEASUREMENT DID NOT.`,
      ``,
      `${drift.length} policy input(s) no longer match the A/B recorded on`,
      `${RECORDED_AT} (PR ${RECORDED_IN_PR}). The recorded result —`,
      `OLD ${RECORDED_SICK_BOX_RESULT.old} vs NEW ${RECORDED_SICK_BOX_RESULT.neu} on a sick-and-slow box — is the whole`,
      `justification for narrowing this retry policy, and it now describes code`,
      `that is not the code shipping.`,
      ``,
      ...drift.map((d) => `  ${d}`),
      ``,
      `THE FIX IS TO RE-MEASURE, NOT TO EDIT THE TRANSCRIPT TO MATCH.`,
      `Editing ${RECORD_NUMBERS_IN} to agree with the new constants`,
      `satisfies this test and destroys the only evidence the narrowing rests on.`,
      ``,
      `Re-run the harness:`,
      ``,
      `    ${REARM_COMMAND}`,
      ``,
      `Then copy the printed ARM A / ARM B blocks into RECORDED_REPORT, update`,
      `RECORDED_POLICY_INPUTS and RECORDED_AT, all in:`,
      ``,
      `    ${RECORD_NUMBERS_IN}`,
      ``,
      `(Arm B is deterministic — seeded LCG on a virtual clock — so it reproduces`,
      `exactly. Arm A talks to the live box and its numbers move with its health.)`,
      ``,
    ].join('\n')
  }

  it('the recorded numbers still describe the policy that ships', () => {
    const live = livePolicyInputs()
    const recorded = RECORDED_POLICY_INPUTS
    const keys = [...new Set([...Object.keys(recorded), ...Object.keys(live)])].sort()

    const drift = keys
      .filter((k) => live[k] !== recorded[k])
      .map((k) => `${k}: recorded ${recorded[k] ?? '(absent)'} -> now ${live[k] ?? '(absent)'}`)

    expect(drift, staleMeasurementReport(drift)).toEqual([])

    // The transcript must actually carry the number, or a future edit could
    // empty it out and leave a green pin guarding nothing.
    expect(RECORDED_REPORT).toContain(`${RECORDED_SICK_BOX_RESULT.old}`)
    expect(RECORDED_REPORT).toContain(`${RECORDED_SICK_BOX_RESULT.neu}`)
  })

  it('the transcript cannot read its expectation out of the thing it guards', () => {
    // A guard whose expected value is derived from the guarded source is inert:
    // it agrees with every edit. The transcript is hand-typed and must stay
    // that way, so this asserts on its SOURCE TEXT, which is the only place an
    // import could hide.
    const path = fileURLToPath(new URL('./retry-ab.recorded.ts', import.meta.url))
    const source = readFileSync(path, 'utf8')
    const imports = source
      .split('\n')
      .map((l, i) => [i + 1, l] as const)
      .filter(([, l]) => /^\s*import[\s{*'"]/.test(l) || /^\s*export\s+.*\bfrom\b/.test(l))
      .map(([n, l]) => `${n}: ${l.trim()}`)

    expect(
      imports,
      `${RECORD_NUMBERS_IN} must import NOTHING — it is a hand-typed transcript of a\n` +
        `measurement. An import of the live constants would make the pin above agree\n` +
        `with any future edit, i.e. inert. Delete the import and type the value.`,
    ).toEqual([])

    // Positive control for the probe itself: the detector DOES see an import
    // when one is present, so an empty result above means absence, not a dead
    // regex. (An absence is never caught by inspection.)
    const control = ["import { X } from './y'", "export * from './z'", 'const k = 1']
    expect(
      control.filter((l) => /^\s*import[\s{*'"]/.test(l) || /^\s*export\s+.*\bfrom\b/.test(l)),
    ).toHaveLength(2)
  })

  it('an ordinary run does not touch the live box', () => {
    // The prod-facing arm stays behind the env gate, unconditionally. This
    // asserts the gate expression itself rather than trusting the comment: with
    // BARKPARK_RETRY_AB unset (CI), RUN is false and arm A is skipped, so no
    // request is issued to BARKPARK_API_URL / the default 89.167.28.206.
    expect(RUN).toBe(process.env.BARKPARK_RETRY_AB === '1')
    if (process.env.BARKPARK_RETRY_AB !== '1') expect(RUN).toBe(false)
  })
})
