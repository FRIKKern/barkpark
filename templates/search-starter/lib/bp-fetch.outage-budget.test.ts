import assert from "node:assert/strict";
import { register } from "node:module";
import { test } from "node:test";

// bp-fetch.ts is a server module (`server-only` + `undici`). These hooks make it
// importable in the dependency-free CI job; everything else in it runs for real.
register(new URL("./__test-stub-hooks.mjs", import.meta.url));

const { setFetch } = await import("./__test-stub-undici.mjs");
const { RETRY_BUDGET, bpFetchJson } = await import("./bp-fetch.ts");

/**
 * These tests pin the RETRY BUDGET as a compiled default.
 *
 * The failure they exist for: 129 DOC_ID_EMPTY deploy failures were a content
 * API that was down for MINUTES, met by a ladder sized for a ~3-second BEAM
 * bounce (3 attempts, ~1s + ~2s of backoff). The obvious mitigation — set
 * BARKPARK_FETCH_TIMEOUT_MS higher — is UNREACHABLE on a managed build: no
 * layer of the deploy chain passes that name (deploy.ex's env map, templates.ex
 * env_keys, BUILD_ALLOW, RUNTIME_ALLOW are all closed lists without it). So the
 * budget can only be widened HERE, and only a test over the compiled constants
 * can keep it widened.
 *
 * Note the framing: the deploy HEALTH gate that caught these is fail-closed and
 * correct. What was wrong is this ladder, not that gate.
 */

/** A stub upstream that 503s for `outageMs`, then serves a body. Counts calls. */
function outageFor(outageMs: number) {
  const startedAt = Date.now();
  const state = { calls: 0 };
  setFetch(async () => {
    state.calls += 1;
    if (Date.now() - startedAt < outageMs) {
      // Bodyless 503 — an infra blip, no envelope, therefore RETRYABLE. (An
      // enveloped 503 is `definitive` and deliberately never retried.)
      return { ok: false, status: 503, headers: new Headers(), text: async () => "" };
    }
    return { ok: true, status: 200, headers: new Headers(), text: async () => '{"ok":true}' };
  });
  return state;
}

test("the ladder rides out an outage that outlasts the old ~3s budget", async () => {
  // 8 seconds: comfortably past every backoff the OLD ladder had to spend
  // (1s + 2s = 3s, then it threw), comfortably inside the new one (30s).
  const state = outageFor(8_000);
  const startedAt = Date.now();

  const body = await bpFetchJson("http://example.invalid/v1/search");

  assert.deepEqual(body, { ok: true });
  const elapsed = Date.now() - startedAt;
  // The load-bearing assertion, stated so it FAILS on a reverted ladder: the
  // call could only succeed by waiting longer than the old budget existed for.
  assert.ok(elapsed > 3_000, `expected to outlast the old 3s budget, waited ${elapsed}ms`);
  assert.ok(state.calls > 3, `expected more than the old 3 attempts, made ${state.calls}`);
});

test("a permanent outage gives up inside the wall-clock budget, not the ladder's sum", async () => {
  // An upstream that never recovers. The ladder alone is 30s of backoff on top
  // of up to 6 timeouts; TOTAL_BUDGET_MS is what keeps a failing build from
  // sitting on that sum. Budget lowered for the test via the loop's own
  // deadline arithmetic being time-based: we assert the SHAPE (bounded, and
  // bounded below the naive additive worst case), not a wall-clock number.
  const ladderSum = RETRY_BUDGET.BACKOFF_MS.reduce((a, b) => a + b, 0);
  const additiveWorstCase =
    ladderSum + (RETRY_BUDGET.RETRIES + 1) * RETRY_BUDGET.TIMEOUT_MS;

  assert.ok(
    RETRY_BUDGET.TOTAL_BUDGET_MS < additiveWorstCase,
    `the wall must bind: budget ${RETRY_BUDGET.TOTAL_BUDGET_MS}ms vs additive ${additiveWorstCase}ms`,
  );
  // And the wall must still be wide enough for the whole fast-failing ladder —
  // a 503 answers instantly, so all six attempts cost only the backoff sum.
  // A wall below that would silently shorten the ladder it is meant to bound.
  assert.ok(
    RETRY_BUDGET.TOTAL_BUDGET_MS > ladderSum,
    `the wall must not truncate the ladder: ${RETRY_BUDGET.TOTAL_BUDGET_MS}ms vs ${ladderSum}ms`,
  );
});

test("the ladder has a backoff for every retry it promises", async () => {
  // A RETRIES bump without a matching BACKOFF_MS entry silently falls back to
  // the last rung — the arithmetic above would then describe a ladder that does
  // not exist.
  assert.equal(RETRY_BUDGET.BACKOFF_MS.length, RETRY_BUDGET.RETRIES);
  // Monotonic: each rung waits at least as long as the one before it.
  for (let i = 1; i < RETRY_BUDGET.BACKOFF_MS.length; i++) {
    assert.ok(
      RETRY_BUDGET.BACKOFF_MS[i] >= RETRY_BUDGET.BACKOFF_MS[i - 1],
      `backoff rung ${i} must not shrink`,
    );
  }
  // The whole point of the change: the ladder outlasts the ~3s it used to be.
  const ladderSum = RETRY_BUDGET.BACKOFF_MS.reduce((a, b) => a + b, 0);
  assert.ok(ladderSum >= 30_000, `expected >=30s of backoff, got ${ladderSum}ms`);
});
