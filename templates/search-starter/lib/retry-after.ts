/**
 * `Retry-After` handling for the upstream retry ladder — the pure half.
 *
 * WHY IT IS ITS OWN MODULE. This logic belongs to `bp-fetch.ts`, but that file
 * opens with `import "server-only"` and pulls in `undici`, so nothing in it can
 * be reached from a `node --test` unit test (the same reason `markers.ts` keeps
 * the marker VALUE SHAPING away from `graph.ts`). The decision "how long do we
 * wait before the next attempt" is exactly the kind of arithmetic that must be
 * pinned by a test rather than by a live box, so it lives here, dependency-free.
 *
 * WHAT IT FIXES. `bp-fetch.ts` retried transient failures on a FIXED ladder
 * (1s, then 2s) sized against an API restart, and threw the upstream's own
 * `Retry-After` away. `GET /v1/graph` sheds beyond four concurrent derivations
 * (503 `graph_corpus_busy`) and holds each slot for a WHOLE derivation —
 * measured live on guerrilla at 10.18/10.38/10.57/10.76s for four concurrent
 * reads, against 2.45-3.36s serial-warm. So the SSR landing's three attempts
 * landed at t+0.31s, t+1.44s and t+3.58s, all three inside the first 10.2s
 * hold, all three shed. It then rendered an empty `bp-doc-id`, and
 * `deploy/site-deploy-node.sh` health_gate_node — which does NOT retry an empty
 * marker — correctly refused to switch the slot. Concurrent deploys failed each
 * other's health probe. See `stw10-backlog-flagship-health-pool`.
 */

/**
 * Ceiling on a server-supplied backoff, mirroring the SDK's
 * `MAX_RATE_LIMIT_BACKOFF_MS` (`js/packages/core/src/retry.ts`). Without it a
 * `Retry-After: 3600` — hostile, misconfigured, or simply larger than we can
 * afford — would pin an SSR render for an hour. The header is ADVICE; this is
 * the bound that keeps it advice.
 *
 * 20s clears the ~10.8s worst-case hold measured above with room for one slot
 * generation of jitter, and stays well inside the deploy gate's patient 90s
 * probe (`HEALTH_PATIENT_MAX` in `deploy/site-deploy-node.sh`).
 */
export const MAX_RETRY_AFTER_MS = 20_000;

/**
 * Parse a `Retry-After` header into milliseconds, clamped to
 * `MAX_RETRY_AFTER_MS`.
 *
 * ONLY the delta-seconds form is honored. The HTTP-date form is legal HTTP but
 * depends on the box and the builder agreeing about the time, and a skewed
 * clock resolves it to either an instant retry or an absurd wait — neither of
 * which is better than our own ladder. Anything unparseable degrades to
 * `undefined`, which means "no advice", which is the same state as a response
 * that carried no header at all.
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
