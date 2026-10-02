import assert from "node:assert/strict";
import { register } from "node:module";
import { test } from "node:test";

// The budget is read from env at module load, and `node --test` runs each file
// in its own process, so this file can shrink the numbers before the import
// without touching the compiled defaults the other specs pin.
//
// TIMEOUT 1500 / WALL 2600 is the shape of the bug at a test-friendly scale:
// attempt 1 hangs and aborts at t=1.5s, the 1s backoff fits (t=2.5s < 2.6s), so
// attempt 2 STARTS 100ms before the wall. Unclamped it runs a full TIMEOUT_MS
// and the call returns at ~t=4.0s — WALL + TIMEOUT, the same arithmetic that
// makes a 45s wall answer at 60s in production.
process.env.BARKPARK_FETCH_TIMEOUT_MS = "1500";
process.env.BARKPARK_FETCH_TOTAL_BUDGET_MS = "2600";

register(new URL("./__test-stub-hooks.mjs", import.meta.url));

const { setFetch } = await import("./__test-stub-undici.mjs");
const { RETRY_BUDGET, bpFetchJson, BpUpstreamError } = await import(
  "./bp-fetch.ts"
);

/** An upstream that never answers: every call hangs until its signal aborts. */
function hangingUpstream() {
  const state = { calls: 0 };
  setFetch((_url: string, init: { signal: AbortSignal }) => {
    state.calls += 1;
    return new Promise((_resolve, reject) => {
      init.signal.addEventListener("abort", () => {
        const e = new Error("aborted");
        e.name = "AbortError";
        reject(e);
      });
    });
  });
  return state;
}

test("the env overrides took: this file runs the small budget", () => {
  assert.equal(RETRY_BUDGET.TIMEOUT_MS, 1500);
  assert.equal(RETRY_BUDGET.TOTAL_BUDGET_MS, 2600);
});

test("a retry started just before the wall is clamped to it, not run for a full TIMEOUT_MS", async () => {
  const state = hangingUpstream();
  const startedAt = Date.now();

  await assert.rejects(
    bpFetchJson("http://example.invalid/v1/search"),
    (err: unknown) => err instanceof BpUpstreamError && err.status === 0,
  );

  const elapsed = Date.now() - startedAt;
  // The load-bearing assertion: the observed worst case stays inside the wall.
  // Reverting the clamp makes this ~4000ms (WALL + TIMEOUT) and reds here.
  const slack = 300;
  assert.ok(
    elapsed <= RETRY_BUDGET.TOTAL_BUDGET_MS + slack,
    `call ran ${elapsed}ms against a ${RETRY_BUDGET.TOTAL_BUDGET_MS}ms wall`,
  );
  // And the second attempt really was started — the clamp shortened it, the
  // sleep guard did not skip it (that would be a different, weaker bound).
  assert.equal(state.calls, 2, `expected 2 attempts, made ${state.calls}`);
});
