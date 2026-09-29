/**
 * A 429 IS A THROTTLE, NOT A VERDICT — the template fork's side of it.
 *
 * The web/lib origin and this fork are two hand-maintained copies with no
 * shared fixture, so this file is the deliberate MIRROR of
 * `web/__tests__/bp-fetch-429.test.ts`: the same four claims, asserted against
 * this tree's own constants, because a green suite over there proves nothing
 * about the code that actually ships in the scaffold.
 *
 * The failure: `bpFetchJson` mapped every 429 to a hard `BpUpstreamError`, so a
 * hold on the shared token bucket became a build that rendered nothing. And the
 * obvious fix would not have worked — Barkpark's limiters answer with a
 * parseable `{error:{code:"rate_limited",details:{retry_after}}}` envelope,
 * which `errorEnvelope` marks `definitive`, and `isTransient` bailed on
 * `definitive` BEFORE it consulted `TRANSIENT_STATUS`. The ORDER is the fix.
 *
 * The budget is narrowed to 6s through this tree's own
 * `BARKPARK_FETCH_TOTAL_BUDGET_MS` override, set BEFORE the module is imported
 * (the constant is read at module load). That is what makes the bound provable
 * in a suite that finishes in seconds instead of forty-five.
 */

import assert from "node:assert/strict";
import { register } from "node:module";
import { test } from "node:test";

process.env.BARKPARK_FETCH_TOTAL_BUDGET_MS = "6000";

register(new URL("./__test-stub-hooks.mjs", import.meta.url));

const { setFetch } = await import("./__test-stub-undici.mjs");
const { bpFetchJson, BpUpstreamError, isRateLimited, isTransient } =
  await import("./bp-fetch.ts");
const { MAX_RETRY_AFTER_MS, envelopeRetryAfterMs } = await import("./retry-after.ts");

/** The real limiter envelope: `retry_after` in SECONDS inside `details` —
 * exactly what `api/lib/barkpark_web/plugs/rate_limit.ex` emits. */
function rateLimitBody(retryAfterSeconds: number): string {
  return JSON.stringify({
    error: {
      code: "rate_limited",
      message: "too many requests",
      details: { retry_after: retryAfterSeconds },
    },
  });
}

/** Installs a stub upstream that 429s for its first `throttled` calls, then
 * serves a body. `sendHeader:false` models a proxy that stripped the header. */
function throttleFor(opts: {
  throttled: number;
  retryAfterSeconds: number;
  sendHeader?: boolean;
}) {
  const state = { calls: 0 };
  setFetch(async () => {
    state.calls += 1;
    if (state.calls <= opts.throttled) {
      const headers = new Headers({ "content-type": "application/json" });
      if (opts.sendHeader !== false) {
        headers.set("retry-after", String(opts.retryAfterSeconds));
      }
      return {
        ok: false,
        status: 429,
        headers,
        text: async () => rateLimitBody(opts.retryAfterSeconds),
      };
    }
    return {
      ok: true,
      status: 200,
      headers: new Headers(),
      text: async () => '{"ok":true}',
    };
  });
  return state;
}

test("ARM 1: a 429 carrying retry_after is retried and succeeds, waiting as long as the SERVER asked", async () => {
  // 2s of advice against this tree's 1s first rung: a build that took its own
  // ladder would come back at ~1s, so the elapsed check is what separates
  // "honours retry_after" from "happens to retry".
  const state = throttleFor({ throttled: 1, retryAfterSeconds: 2 });
  const startedAt = Date.now();
  const body = await bpFetchJson("http://example.invalid/v1/search");
  const elapsed = Date.now() - startedAt;

  assert.deepEqual(body, { ok: true });
  assert.equal(state.calls, 2, "expected exactly one retry after the throttle");
  assert.ok(
    elapsed >= 1_900,
    `expected to honour the server's 2s hold, waited only ${elapsed}ms — that is the hardcoded 1s rung`,
  );
});

test("ARM 1b: the hold is read from the BODY when a proxy strips the header", async () => {
  const state = throttleFor({ throttled: 1, retryAfterSeconds: 2, sendHeader: false });
  const startedAt = Date.now();
  const body = await bpFetchJson("http://example.invalid/v1/search");
  const elapsed = Date.now() - startedAt;

  assert.deepEqual(body, { ok: true });
  assert.equal(state.calls, 2);
  assert.ok(
    elapsed >= 1_900,
    `details.retry_after was ignored: waited ${elapsed}ms, expected the 2s the body named`,
  );
});

test("ARM 2: a 403 is still a HARD error and is requested exactly ONCE", async () => {
  // The arm a naive retry-everything fix breaks: a forbidden answer does not
  // become allowed by waiting, so retrying it only burns the build's budget.
  const state = { calls: 0 };
  setFetch(async () => {
    state.calls += 1;
    return {
      ok: false,
      status: 403,
      headers: new Headers(),
      text: async () => JSON.stringify({ error: { code: "forbidden", message: "nope" } }),
    };
  });

  await assert.rejects(
    () => bpFetchJson("http://example.invalid/v1/search"),
    (err: unknown) => {
      assert.ok(err instanceof BpUpstreamError);
      assert.equal(err.status, 403);
      assert.equal(err.code, "forbidden");
      return true;
    },
  );
  assert.equal(state.calls, 1, `a 403 must not be retried, but it was requested ${state.calls} times`);
});

test("ARM 2b: an ENVELOPED 500 is hard too — the hard arm is about the ANSWER, not the digit", async () => {
  const state = { calls: 0 };
  setFetch(async () => {
    state.calls += 1;
    return {
      ok: false,
      status: 500,
      headers: new Headers(),
      text: async () =>
        JSON.stringify({ error: { code: "internal_error", message: "boom" } }),
    };
  });

  await assert.rejects(() => bpFetchJson("http://example.invalid/v1/search"));
  assert.equal(state.calls, 1, `an enveloped 500 is definitive; requested ${state.calls} times`);
});

test("BOUND 1: advice that does not fit the wall-clock budget is REFUSED, not truncated", async () => {
  // `retry_after: 30` clamps to MAX_RETRY_AFTER_MS (20s), which does not fit the
  // 6s budget this file compiled in. A truncated wait would land back inside the
  // hold the server just named, so the call gives up NOW, after one attempt.
  const state = throttleFor({ throttled: Infinity, retryAfterSeconds: 30 });
  const startedAt = Date.now();

  await assert.rejects(
    () => bpFetchJson("http://example.invalid/v1/search"),
    (err: unknown) => {
      assert.ok(err instanceof BpUpstreamError);
      assert.equal(err.status, 429);
      return true;
    },
  );
  const elapsed = Date.now() - startedAt;
  assert.equal(state.calls, 1, "an unaffordable wait must not be taken at all");
  assert.ok(elapsed < 2_000, `expected an immediate refusal, took ${elapsed}ms`);
});

test("BOUND 2: a single hold is CLAMPED — the header is advice, never a hostage", async () => {
  // The pure half of the bound, so the ceiling is pinned against a numeric
  // LITERAL and not merely against itself.
  assert.equal(MAX_RETRY_AFTER_MS, 20_000);
  assert.equal(envelopeRetryAfterMs(rateLimitBody(3_600)), 20_000);
  assert.equal(envelopeRetryAfterMs(rateLimitBody(2)), 2_000);
  // Not advice: a hostile or malformed value degrades to "no advice", which
  // leaves the caller on its own ladder rather than on the attacker's.
  assert.equal(envelopeRetryAfterMs(rateLimitBody(-1)), undefined);
  assert.equal(envelopeRetryAfterMs('{"error":{"code":"rate_limited"}}'), undefined);
  assert.equal(envelopeRetryAfterMs("<html>429</html>"), undefined);
});

test("the classifier itself: a rate limit is transient DESPITE being definitive", async () => {
  // The unit-level statement of the ordering bug. `definitive` is true here —
  // the upstream answered on purpose — and the error must still be retryable.
  const throttled = new BpUpstreamError(429, "too many requests", "", true, "rate_limited", 2_000);
  assert.equal(throttled.definitive, true);
  assert.equal(isRateLimited(throttled), true);
  assert.equal(isTransient(throttled), true);

  const forbidden = new BpUpstreamError(403, "nope", "", true, "forbidden");
  assert.equal(isRateLimited(forbidden), false);
  assert.equal(isTransient(forbidden), false);
});
