import assert from "node:assert/strict";
import { test } from "node:test";

import {
  MAX_RETRY_AFTER_MS,
  parseRetryAfterMs,
  retryDelayMs,
} from "./retry-after.ts";

/**
 * These tests pin the arithmetic that decides whether a deploy lives or dies.
 *
 * `GET /v1/graph` sheds beyond four concurrent derivations and holds each slot
 * for a whole derivation (measured live on guerrilla, 2026-08-22: 10.18 /
 * 10.38 / 10.57 / 10.76s for four concurrent reads, against 2.45-3.36s
 * serial-warm). Before this module existed, `bp-fetch.ts` retried on a fixed
 * 1s/2s ladder and DISCARDED the server's `Retry-After`, so the SSR landing's
 * three attempts all landed inside the first hold, all three were shed, the
 * page rendered an empty `bp-doc-id`, and the deploy HEALTH gate — which does
 * not retry an empty marker — refused to switch. See
 * `stw10-backlog-flagship-health-pool`.
 *
 * The scenario test at the bottom is the one that FAILS WITHOUT THE FIX.
 */

/* ── parseRetryAfterMs ────────────────────────────────────────────────────── */

test("a delta-seconds header becomes milliseconds", () => {
  assert.equal(parseRetryAfterMs("12"), 12_000);
  assert.equal(parseRetryAfterMs("1"), 1_000);
  // Whitespace is header noise, not a value change.
  assert.equal(parseRetryAfterMs("  7  "), 7_000);
});

test("`0` is advice, not absence — it must survive as 0, never become undefined", () => {
  // The distinction is load-bearing: `undefined` means "no advice, use the
  // ladder", while 0 means "come back immediately" — and `retryDelayMs` must
  // still floor 0 at the scheduled backoff rather than hot-looping.
  assert.equal(parseRetryAfterMs("0"), 0);
  assert.equal(retryDelayMs(1_000, parseRetryAfterMs("0")), 1_000);
});

test("no header at all is no advice", () => {
  assert.equal(parseRetryAfterMs(null), undefined);
  assert.equal(parseRetryAfterMs(undefined), undefined);
  assert.equal(parseRetryAfterMs(""), undefined);
});

test("the HTTP-date form is REFUSED rather than misread", () => {
  // Legal HTTP, but resolving it needs the box and the builder to agree about
  // the time. A skewed clock turns it into an instant retry or an absurd wait;
  // "no advice" is strictly better than either.
  assert.equal(parseRetryAfterMs("Wed, 21 Oct 2026 07:28:00 GMT"), undefined);
});

test("a malformed value degrades to no advice instead of NaN", () => {
  // `Number("1.5")` is 1500ms and `Number("-1")` is -1000ms — both would flow
  // straight into a `Math.max` and silently corrupt the ladder, so the strict
  // pattern rejects them at the door.
  for (const bad of ["1.5", "-1", "+3", "soon", "12s", "1e3", "٣"]) {
    assert.equal(
      parseRetryAfterMs(bad),
      undefined,
      `Retry-After: ${bad} should be unparseable, not silently coerced`,
    );
  }
});

test("a hostile Retry-After is clamped, never obeyed", () => {
  // Without the ceiling, `Retry-After: 3600` pins an SSR render for an hour.
  assert.equal(parseRetryAfterMs("3600"), MAX_RETRY_AFTER_MS);
  assert.equal(parseRetryAfterMs("999999999"), MAX_RETRY_AFTER_MS);
  // The clamp stays comfortably inside the deploy gate's patient 90s probe.
  assert.ok(MAX_RETRY_AFTER_MS < 90_000);
});

/* ── retryDelayMs ─────────────────────────────────────────────────────────── */

test("with no advice the scheduled ladder is used unchanged", () => {
  assert.equal(retryDelayMs(1_000, undefined), 1_000);
  assert.equal(retryDelayMs(2_000, undefined), 2_000);
});

test("advice LONGER than the ladder wins — this is the whole fix", () => {
  assert.equal(retryDelayMs(1_000, 12_000), 12_000);
  assert.equal(retryDelayMs(2_000, 12_000), 12_000);
});

test("advice SHORTER than the ladder never shortens it", () => {
  // An upstream must not be able to shrink the restart-window coverage the
  // fixed ladder exists to provide.
  assert.equal(retryDelayMs(2_000, 500), 2_000);
  assert.equal(retryDelayMs(2_000, 0), 2_000);
});

/* ── the scenario ─────────────────────────────────────────────────────────── */

test("the SSR retry ladder now OUTLASTS a saturated /v1/graph slot hold", () => {
  // Reproduces `bp-fetch.ts`'s loop arithmetic against the live-measured facts.
  const BACKOFF_MS = [1_000, 2_000]; // bp-fetch.ts
  const RETRIES = 2; // bp-fetch.ts — total attempts = RETRIES + 1
  const SLOT_HOLD_MS = 10_760; // worst of four concurrent reads, measured live
  const SERVER_RETRY_AFTER = "12"; // what tasks_controller.ex now sends

  const advised = parseRetryAfterMs(SERVER_RETRY_AFTER);

  // When does the LAST attempt land, counting only the waits between them?
  const lastAttemptAt = (advice: number | undefined): number => {
    let t = 0;
    for (let i = 0; i < RETRIES; i++) {
      t += retryDelayMs(BACKOFF_MS[i] ?? 2_000, advice);
    }
    return t;
  };

  // BEFORE (advice discarded): every attempt lands inside the hold.
  assert.ok(
    lastAttemptAt(undefined) < SLOT_HOLD_MS,
    "the old fixed ladder should exhaust inside the slot hold — that was the bug",
  );
  assert.equal(lastAttemptAt(undefined), 3_000);

  // AFTER: the second attempt alone already outlasts the hold, so the SSR
  // anchors a document and `bp-doc-id` is non-empty when HEALTH reads it.
  assert.ok(
    retryDelayMs(BACKOFF_MS[0], advised) > SLOT_HOLD_MS,
    `the first retry must land after the ~${SLOT_HOLD_MS}ms hold, not inside it`,
  );
  assert.equal(lastAttemptAt(advised), 24_000);
});
