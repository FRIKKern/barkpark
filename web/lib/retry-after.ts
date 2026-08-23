/**
 * `Retry-After` handling for `bp-fetch.ts`'s upstream retry ladder — the pure,
 * dependency-free half, so the arithmetic that decides how long a render waits
 * is pinned by a test rather than by a live box.
 *
 * WHAT IT FIXES. `bp-fetch.ts` retried transient failures on a FIXED ladder
 * (1s, then 2s) sized against an API RESTART, and threw the upstream's own
 * `Retry-After` away. But `GET /v1/graph` — which `lib/graph.ts` calls for the
 * "/" finder landing — does not only fail during restarts: it SHEDS. Beyond
 * `@graph_corpus_max_concurrency` (4) concurrent derivations it answers 503
 * `graph_corpus_busy` with `retry-after: 12`
 * (`@graph_corpus_retry_after_seconds`), and it holds each slot for a WHOLE
 * derivation — measured live on guerrilla at 10.18/10.38/10.57/10.76s for four
 * concurrent reads, against 2.45-3.36s serial-warm.
 *
 * That shed reaches the RETRYABLE path (503 is in `TRANSIENT_STATUS`, and
 * `errorEnvelope` does not recognise its `{ok,reason,retry_after,message}`
 * body as a definitive `{error:…}` answer), so the ladder does fire — it just
 * fires at roughly t+0, t+1 and t+3, all three inside the first ~10.2s hold,
 * all three shed. `fetchCorpusGraph` then degrades to an empty graph and the
 * landing paints a blank canvas, having been told exactly how long to wait and
 * ignored it.
 *
 * The extracted `templates/search-starter` fork got this fix in #12956; this
 * is the origin it was extracted from, which never did.
 *
 * WHY THIS IS NOT A VERBATIM PORT — THE DEADLINE. The fork's SSR runs at
 * DEPLOY time on a box with no request deadline, so waiting 12s twice (24s
 * total) is free there. `web/` renders on a serverless function with one, and
 * a retry that outlives its own deadline trades a fast degraded page for a
 * hard timeout — strictly worse. So this module adds `withinSleepBudget`: the
 * advice is honoured, but the TOTAL time the loop may spend asleep is bounded,
 * and a wait that would not fit is not taken at all. Giving up honestly beats
 * burning an attempt we already know will be shed.
 */

/**
 * Ceiling on a single server-supplied backoff, mirroring the SDK's
 * `MAX_RATE_LIMIT_BACKOFF_MS` (`js/packages/core/src/retry.ts`). Without it a
 * `Retry-After: 3600` — hostile, misconfigured, or simply larger than we can
 * afford — would pin a render for an hour. The header is ADVICE; this is the
 * bound that keeps it advice.
 *
 * 20s clears the ~10.8s worst-case hold measured above with room for one slot
 * generation of jitter.
 */
export const MAX_RETRY_AFTER_MS = 20_000;

/**
 * Ceiling on the TOTAL time one `bpFetchJson` call may spend asleep between
 * attempts. This is the deadline half of the fix and the part the fork does
 * not need: a serverless render that sleeps past its function limit returns a
 * timeout instead of a degraded page.
 *
 * 20s admits exactly one full `retry-after: 12` wait (t=12) and refuses a
 * second (t=24) — long enough to outlast one saturated `/v1/graph` slot hold,
 * short enough that the landing still renders. The no-advice path is
 * unaffected: the fixed ladder sleeps 1s + 2s = 3s in total, far inside this.
 */
export const MAX_RETRY_SLEEP_TOTAL_MS = 20_000;

/**
 * Parse a `Retry-After` header into milliseconds, clamped to
 * `MAX_RETRY_AFTER_MS`.
 *
 * ONLY the delta-seconds form is honoured. The HTTP-date form is legal HTTP but
 * depends on the box and the server agreeing about the time, and a skewed clock
 * resolves it to either an instant retry or an absurd wait — neither of which
 * is better than our own ladder. Anything unparseable degrades to `undefined`,
 * which means "no advice", the same state as a response that carried no header.
 */
export function parseRetryAfterMs(
  header: string | null | undefined,
): number | undefined {
  if (header === null || header === undefined) return undefined;
  const trimmed = header.trim();
  // Deliberately strict: no sign, no decimal point, no leading `+`. `-1`,
  // `1.5` and `Wed, 21 Oct 2026 07:28:00 GMT` all become "no advice".
  if (!/^\d+$/.test(trimmed)) return undefined;
  const seconds = Number(trimmed);
  if (!Number.isFinite(seconds)) return undefined;
  return Math.min(seconds * 1_000, MAX_RETRY_AFTER_MS);
}

/**
 * How long to wait before the next attempt: the LONGER of our scheduled backoff
 * and the upstream's advice.
 *
 * THE `max` IS THE WHOLE POINT. Obeying the header alone would let an upstream
 * SHORTEN the restart-window coverage the fixed ladder exists to provide (a
 * `Retry-After: 0` during a BEAM bounce would turn the ladder into a hot loop).
 * Ignoring it — the behaviour before this fix — makes the ladder retry into a
 * wall the server already told us about. Take both seriously: never sooner than
 * we planned, never sooner than we were asked.
 */
export function retryDelayMs(
  scheduledMs: number,
  retryAfterMs?: number,
): number {
  if (retryAfterMs === undefined) return scheduledMs;
  return Math.max(scheduledMs, retryAfterMs);
}

/**
 * May the loop take a `delayMs` nap, having already slept `sleptMs` in total?
 *
 * A wait that would push the cumulative sleep past the budget is NOT taken and
 * NOT shortened: a truncated wait lands back inside the hold the server told us
 * about, which is the exact behaviour this whole module exists to end. The
 * caller stops retrying and surfaces the last error instead — a degraded page
 * now, rather than a function timeout later.
 */
export function withinSleepBudget(
  delayMs: number,
  sleptMs: number,
  budgetMs: number = MAX_RETRY_SLEEP_TOTAL_MS,
): boolean {
  return sleptMs + delayMs <= budgetMs;
}
