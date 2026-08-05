/**
 * pds — the find-event proxy's receipt must DESCEND from the upstream write.
 *
 * `app/api/find-event/route.ts` is the only live caller of the search
 * feedback endpoints. It has SIX exits, and every one of them must answer a
 * receipt whose `recorded` field is a measurement of what actually happened
 * upstream — never an assertion made in advance:
 *
 *   1. upstream 2xx                  → recorded:true
 *   2. upstream 422                  → recorded:false, reason names the status
 *   3. upstream 500                  → recorded:false, reason names the status
 *   4. fetch rejects (network)       → recorded:false
 *   5. request body unparsable       → recorded:false, NO write attempted
 *   6. body parsed but unroutable    → recorded:false, NO write attempted
 *
 * The status line stays 200 at all six (PDS-D695): a dropped analytics signal
 * must never break search UX, and putting the receipt on the status line for
 * only some exits would make `res.ok` read GREEN for an upstream 500 and RED
 * for a malformed body — the exact inversion this work exists to kill.
 *
 * Exits 5 and 6 additionally assert the NEGATIVE — that `fetch` was never
 * called — because "we did not even try" and "we tried and it failed" are
 * different facts and only one of them is a client bug.
 *
 * This is the first route-handler test in web/; two bundler-only resolutions
 * (`@/…` and `next/server`) are replayed in `support/server-only-loader.mjs`.
 *
 * Run: `pnpm test` (or, from web/, `node --test --test-reporter=spec \
 *   --import ./__tests__/support/stub-server-only.mjs \
 *   __tests__/find-event-receipt.test.ts`).
 */

import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";

import { POST } from "../app/api/find-event/route.ts";

interface Receipt {
  ok?: boolean;
  recorded?: boolean;
  reason?: string;
}

const realFetch = globalThis.fetch;
/** Every upstream call this route made during the test — the write attempts. */
let calls: string[] = [];

beforeEach(() => {
  calls = [];
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

/** Stub upstream: record the call, then answer with `status`. */
function upstreamAnswers(status: number): void {
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    calls.push(String(input));
    return new Response(JSON.stringify({ ok: status < 400 }), {
      status,
      headers: { "Content-Type": "application/json" },
    });
  }) as typeof fetch;
}

/** Stub upstream: record the call, then reject the way a dead host does. */
function upstreamUnreachable(): void {
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    calls.push(String(input));
    throw new TypeError("fetch failed");
  }) as typeof fetch;
}

/** Stub upstream that must never be reached — any call is itself the failure. */
function upstreamForbidden(): void {
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    calls.push(String(input));
    return new Response("{}", { status: 200 });
  }) as typeof fetch;
}

function post(body: string): Request {
  return new Request("http://localhost/api/find-event", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
  });
}

const CLICK = JSON.stringify({
  kind: "click",
  queryEventId: "qe_1",
  objectId: "doc_1",
  position: 3,
  sid: "sid_1",
});

async function receiptOf(request: Request): Promise<{
  status: number;
  body: Receipt;
}> {
  const res = await POST(request);
  return { status: res.status, body: (await res.json()) as Receipt };
}

/* ── 1. the write succeeded ────────────────────────────────────────────── */

test("exit 1 — upstream 2xx: the receipt records the write that happened", async () => {
  upstreamAnswers(200);
  const { status, body } = await receiptOf(post(CLICK));

  assert.equal(status, 200);
  assert.equal(body.ok, true);
  assert.equal(body.recorded, true, "a 2xx write must be recorded:true");
  assert.equal(calls.length, 1, "the click must reach the interaction endpoint");
});

/* ── 2/3. the upstream refused — the honest status must survive the hop ── */

test("exit 2 — upstream 422: recorded:false and the reason names the status", async () => {
  upstreamAnswers(422);
  const { status, body } = await receiptOf(post(CLICK));

  assert.equal(status, 200, "a dropped signal must not break search UX");
  assert.equal(
    body.recorded,
    false,
    "the API's honest 422 must not be laundered into a recorded signal",
  );
  assert.match(
    String(body.reason),
    /422/,
    "the reason must name the upstream status it descends from",
  );
});

test("exit 3 — upstream 500: recorded:false and the reason names the status", async () => {
  upstreamAnswers(500);
  const { status, body } = await receiptOf(post(CLICK));

  assert.equal(status, 200);
  assert.equal(body.recorded, false, "a 500 is not a recorded write");
  assert.match(String(body.reason), /500/);
});

/* ── 4. the network failed ─────────────────────────────────────────────── */

test("exit 4 — fetch rejects: recorded:false, and the route still answers 200", async () => {
  upstreamUnreachable();
  const { status, body } = await receiptOf(post(CLICK));

  assert.equal(status, 200);
  assert.equal(body.ok, true);
  assert.equal(body.recorded, false, "an unreachable upstream recorded nothing");
});

/* ── 5/6. nothing was ever sent — a different fact from a failed send ──── */

test("exit 5 — unparsable body: recorded:false AND no write was attempted", async () => {
  upstreamForbidden();
  const { status, body } = await receiptOf(post("not json at all"));

  assert.equal(status, 200);
  assert.equal(body.recorded, false, "an unparsed body recorded nothing");
  assert.equal(calls.length, 0, "nothing may be sent upstream for a body we could not read");
});

test("exit 6 — parsed but unroutable: recorded:false AND no write was attempted", async () => {
  upstreamForbidden();
  // Three shapes reach this exit: an unknown kind, a correction missing `to`,
  // and a click missing `queryEventId`. All three recorded exactly nothing.
  for (const body of [
    JSON.stringify({ kind: "sideways" }),
    JSON.stringify({ kind: "correction", from: "helo" }),
    JSON.stringify({ kind: "click", objectId: "doc_1" }),
  ]) {
    const receipt = await receiptOf(post(body));

    assert.equal(receipt.status, 200, `status for ${body}`);
    assert.equal(
      receipt.body.recorded,
      false,
      `no write was attempted for ${body}, so the receipt must not claim one`,
    );
  }
  assert.equal(calls.length, 0, "an unroutable signal must never reach the upstream");
});
