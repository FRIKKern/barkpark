/**
 * Pins the arithmetic that decides how long `bp-fetch.ts` waits between
 * attempts, and then proves the wiring END TO END against a real local server.
 *
 * THE DEFECT. `bp-fetch.ts` retried transient failures on a FIXED 1s/2s ladder
 * and DISCARDED the upstream's `Retry-After`. `GET /v1/graph` — which
 * `lib/graph.ts` calls for the "/" finder landing — sheds beyond four
 * concurrent derivations (503 `graph_corpus_busy`, `retry-after: 12`) and holds
 * each slot for a WHOLE derivation: measured live on guerrilla at
 * 10.18/10.38/10.57/10.76s for four concurrent reads, against 2.45-3.36s
 * serial-warm. So the landing's three attempts landed at ~t+0, t+1 and t+3,
 * all three inside the first ~10.2s hold, all three shed, and the page painted
 * a blank canvas — having been told exactly how long to wait and ignored it.
 * `templates/search-starter` got this in #12956; this is the origin it was
 * extracted from.
 *
 * THE DEADLINE HALF IS NOT IN THE FORK. The fork's SSR runs at deploy time
 * with no request deadline; `web/` renders on a serverless function with one,
 * where a retry that outlives its deadline trades a fast degraded page for a
 * hard timeout. Hence `withinSleepBudget` and its own tests below.
 *
 * NAMED MUTANTS each test kills:
 *   • drop-the-header        → the e2e "advice wins" test reds (fast retry)
 *   • obey-the-header-alone  → "advice SHORTER never shortens" reds
 *   • accept-the-date-form   → the HTTP-date test reds
 *   • drop-the-clamp         → the hostile-header test reds
 *   • drop-the-budget        → the e2e budget test reds (call sleeps on)
 *   • truncate-instead-of-stop → the "not shortened" budget test reds
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import {
  MAX_RETRY_AFTER_MS,
  MAX_RETRY_SLEEP_TOTAL_MS,
  parseRetryAfterMs,
  retryDelayMs,
  withinSleepBudget,
} from "../lib/retry-after.ts";
import { bpFetchJson, BpUpstreamError } from "../lib/bp-fetch.ts";

/* ── parseRetryAfterMs ────────────────────────────────────────────────────── */

test("a delta-seconds header becomes milliseconds", () => {
  assert.equal(parseRetryAfterMs("12"), 12_000);
  assert.equal(parseRetryAfterMs("1"), 1_000);
  // Whitespace is header noise, not a value change.
  assert.equal(parseRetryAfterMs("  7  "), 7_000);
});

test("`0` is advice, not absence — it survives as 0, never becomes undefined", () => {
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
  // Legal HTTP, but resolving it needs the box and the server to agree about
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
  // Without the ceiling, `Retry-After: 3600` pins a render for an hour.
  //
  // PINNED TO LITERALS, DELIBERATELY. Asserting only that the parse equals
  // MAX_RETRY_AFTER_MS makes this test agree with whatever the constant
  // happens to say: raise the cap to an hour and
  // `parseRetryAfterMs("3600") === MAX_RETRY_AFTER_MS` is STILL true, so the
  // ceiling this test exists to defend could be deleted without reddening
  // anything. Measured, not supposed — mutating the constant to 3_600_000 left
  // all 18 tests in this file green before these three lines changed.
  //
  // templates/search-starter/lib/retry-after.test.ts — the FORK of this file —
  // already carried an `assert.ok(MAX_RETRY_AFTER_MS < 90_000)` bound, and the
  // port into web/ dropped it. That left web/ the weaker of the two despite
  // being the tree with a real serverless deadline, which is the opposite of
  // the intended direction.
  assert.equal(parseRetryAfterMs("3600"), 20_000);
  assert.equal(parseRetryAfterMs("999999999"), 20_000);
  // The ceiling itself, pinned by VALUE rather than by reference to itself.
  // Moving it should be a deliberate edit on this line, not a silent widening
  // in the module that this file then rubber-stamps.
  assert.equal(
    MAX_RETRY_AFTER_MS,
    20_000,
    "the Retry-After ceiling moved; that is a deadline decision, so change it here on purpose",
  );
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

/* ── withinSleepBudget — the deadline half ────────────────────────────────── */

test("the no-advice ladder fits the budget with room to spare", () => {
  // 1s + 2s = 3s total, so this fix cannot change any pre-existing path.
  assert.ok(withinSleepBudget(1_000, 0));
  assert.ok(withinSleepBudget(2_000, 1_000));
  assert.ok(3_000 < MAX_RETRY_SLEEP_TOTAL_MS);
});

test("the budget admits ONE full /v1/graph hold and refuses a second", () => {
  const advised = parseRetryAfterMs("12"); // what tasks_controller.ex sends
  assert.equal(advised, 12_000);
  const first = retryDelayMs(1_000, advised);
  assert.ok(withinSleepBudget(first, 0), "one 12s wait must fit");
  assert.ok(
    !withinSleepBudget(retryDelayMs(2_000, advised), first),
    "a SECOND 12s wait must not fit — 24s is past the budget",
  );
});

test("a wait that does not fit is refused, not truncated", () => {
  // Truncating would land the retry back inside the hold the server just named
  // — the exact behaviour this module exists to end. The predicate is a
  // boolean, so there is no shortened value to take.
  assert.equal(withinSleepBudget(20_001, 0, 20_000), false);
  assert.equal(withinSleepBudget(20_000, 0, 20_000), true, "exactly-at-budget fits");
  assert.equal(withinSleepBudget(1, 20_000, 20_000), false);
});

/* ── end to end, through the real bpFetchJson ─────────────────────────────── */

/** A server that sheds the first `shedCount` requests exactly the way
 * `TasksController.graph_corpus/2` does, then answers 200. */
async function shedThenServe(
  shedCount: number,
  retryAfter: string | null,
): Promise<{ url: string; hits: () => number; stop: () => Promise<void> }> {
  let n = 0;
  const server: Server = createServer((_req, res) => {
    n += 1;
    if (n <= shedCount) {
      const headers: Record<string, string> = { "content-type": "application/json" };
      if (retryAfter !== null) headers["retry-after"] = retryAfter;
      res.writeHead(503, headers);
      // The REAL shed body: `reason`/`message`, no `error` key — which is why
      // `errorEnvelope` does not mark it definitive and the ladder does fire.
      res.end(
        JSON.stringify({
          ok: false,
          reason: "graph_corpus_busy",
          retry_after: Number(retryAfter ?? 0),
          message: "too many concurrent /v1/graph derivations",
        }),
      );
      return;
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, nodes: [], edges: [] }));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${port}/`,
    hits: () => n,
    stop: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}

test("E2E: a shed carrying Retry-After makes the ladder wait the SERVER's time", async () => {
  // Scheduled backoff for attempt 1 is 1000ms; the server asks for 2s.
  const { url, hits, stop } = await shedThenServe(1, "2");
  try {
    const t0 = Date.now();
    const out = await bpFetchJson(url);
    const elapsed = Date.now() - t0;
    assert.deepEqual(out, { ok: true, nodes: [], edges: [] });
    assert.equal(hits(), 2, "one shed, then one success");
    assert.ok(
      elapsed >= 1_950,
      `must honour the 2s advice, not the 1s ladder — waited ${elapsed}ms`,
    );
  } finally {
    await stop();
  }
});

test("E2E CONTROL: the same shed WITHOUT the header still uses the 1s ladder", async () => {
  // The control is what makes the test above about the HEADER rather than
  // about the retry existing at all.
  const { url, hits, stop } = await shedThenServe(1, null);
  try {
    const t0 = Date.now();
    await bpFetchJson(url);
    const elapsed = Date.now() - t0;
    assert.equal(hits(), 2);
    assert.ok(
      elapsed < 1_900,
      `no advice means the scheduled 1s ladder — waited ${elapsed}ms`,
    );
  } finally {
    await stop();
  }
});

test("E2E: the shed's Retry-After rides on the thrown BpUpstreamError", async () => {
  const { url, stop } = await shedThenServe(99, "7");
  try {
    await assert.rejects(
      // Budget 0: no wait fits, so the FIRST error surfaces immediately and
      // the assertion is about the error's payload, not the ladder.
      () => bpFetchJson(url, undefined, 0),
      (err: unknown) => {
        assert.ok(err instanceof BpUpstreamError);
        assert.equal(err.status, 503);
        assert.equal(err.retryAfterMs, 7_000);
        return true;
      },
    );
  } finally {
    await stop();
  }
});

test("E2E: the sleep budget STOPS the ladder instead of sleeping past a deadline", async () => {
  // A server that never recovers and asks for 3s each time, against a 2s
  // budget: the first wait (3s) does not fit, so the call must give up at once
  // rather than sleep. Without the budget this would take ~6s.
  const { url, hits, stop } = await shedThenServe(99, "3");
  try {
    const t0 = Date.now();
    await assert.rejects(() => bpFetchJson(url, undefined, 2_000));
    const elapsed = Date.now() - t0;
    assert.equal(hits(), 1, "the un-affordable wait must cost ZERO extra attempts");
    assert.ok(elapsed < 1_000, `must not sleep at all — took ${elapsed}ms`);
  } finally {
    await stop();
  }
});

test("E2E: a budget that DOES fit still retries (the budget is a ceiling, not an off switch)", async () => {
  const { url, hits, stop } = await shedThenServe(1, "1");
  try {
    await bpFetchJson(url, undefined, 5_000);
    assert.equal(hits(), 2, "an affordable wait must still be taken");
  } finally {
    await stop();
  }
});

test("E2E: the budget is CUMULATIVE — a second affordable-alone wait can still be refused", async () => {
  // The budget is spent, not re-offered. Each wait here is 2s (advice beats
  // the 1s/2s ladder) and fits on its own, but their SUM does not fit a 3s
  // budget — so exactly ONE retry is taken.
  //
  // This is the case that caught a real hole: with `sleptMs` never
  // accumulating, every wait is measured against an empty budget and the
  // ladder sleeps the full 4s. Every other test in this file stayed green
  // under that mutant.
  const { url, hits, stop } = await shedThenServe(99, "2");
  try {
    const t0 = Date.now();
    await assert.rejects(() => bpFetchJson(url, undefined, 3_000));
    const elapsed = Date.now() - t0;
    assert.equal(hits(), 2, "exactly one retry: 2s fits, 2s+2s does not");
    assert.ok(
      elapsed < 3_500,
      `total sleep must stay inside the 3s budget — took ${elapsed}ms`,
    );
  } finally {
    await stop();
  }
});
