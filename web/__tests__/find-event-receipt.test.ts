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
 * The routing arms below assert WHAT was sent, not merely that something was:
 * a `recorded:true` that descends from a write to the WRONG endpoint, or from
 * one that dropped `X-BP-SEARCH-CLIENT` (the header the upstream attributes
 * sessions by, for anti-gaming), is a receipt that measured the wrong thing.
 * Counting calls alone would pass every one of those regressions.
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

/** One upstream write attempt, captured whole — url, headers AND payload. */
interface Attempt {
  url: string;
  headers: Record<string, string>;
  payload: Record<string, unknown>;
}

/** Every upstream call this route made during the test — the write attempts. */
let calls: Attempt[] = [];

function capture(input: RequestInfo | URL, init?: RequestInit): void {
  const headers: Record<string, string> = {};
  for (const [k, v] of Object.entries(
    (init?.headers ?? {}) as Record<string, string>,
  )) {
    headers[k.toLowerCase()] = v;
  }
  let payload: Record<string, unknown> = {};
  try {
    payload = JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>;
  } catch {
    payload = { unparsable: String(init?.body) };
  }
  calls.push({ url: String(input), headers, payload });
}

beforeEach(() => {
  calls = [];
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

/** Stub upstream: record the call, then answer with `status`. */
function upstreamAnswers(status: number): void {
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    capture(input, init);
    return new Response(JSON.stringify({ ok: status < 400 }), {
      status,
      headers: { "Content-Type": "application/json" },
    });
  }) as typeof fetch;
}

/**
 * Stub upstream: a 2xx carrying a verbatim body — the 200-with-bad-news case.
 * `body: null` is the genuinely body-less answer (204 rejects any body at all,
 * even an empty string — constructing one throws).
 */
function upstreamAnswersBody(status: number, body: unknown): void {
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    capture(input, init);
    const payload =
      body === null ? null : typeof body === "string" ? body : JSON.stringify(body);
    return new Response(payload, {
      status,
      headers: { "Content-Type": "application/json" },
    });
  }) as typeof fetch;
}

/** Stub upstream: record the call, then reject the way a dead host does. */
function upstreamUnreachable(): void {
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    capture(input, init);
    throw new TypeError("fetch failed");
  }) as typeof fetch;
}

/** Stub upstream that must never be reached — any call is itself the failure. */
function upstreamForbidden(): void {
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    capture(input, init);
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

const CORRECTION = JSON.stringify({
  kind: "correction",
  from: "helo",
  to: "hello",
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
  assert.match(
    calls[0].url,
    /\/v1\/data\/search\/[^/]+\/interaction$/,
    "a click must be written to the INTERACTION endpoint — a recorded:true that " +
      "descends from a write to the wrong endpoint measured the wrong thing",
  );
  assert.deepEqual(
    calls[0].payload,
    { queryEventId: "qe_1", objectId: "doc_1", position: 3 },
    "the click payload must carry the event, the object and the position",
  );
  assert.equal(
    calls[0].headers["x-bp-search-client"],
    "sid_1",
    "the session header the upstream attributes by (anti-gaming) must survive the hop",
  );
});

test("exit 1 — a correction is written to the CORRECTION endpoint, not the click one", async () => {
  upstreamAnswers(200);
  const { body } = await receiptOf(post(CORRECTION));

  assert.equal(body.recorded, true);
  assert.equal(calls.length, 1);
  assert.match(
    calls[0].url,
    /\/v1\/data\/search\/[^/]+\/correction$/,
    "the two signals must not be able to swap endpoints under a refactor",
  );
  assert.deepEqual(calls[0].payload, { from: "helo", to: "hello" });
  assert.equal(calls[0].headers["x-bp-search-client"], "sid_1");
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

/* ── 3b. a 2xx that recorded NOTHING — the cross-slice seam ─────────────── */

/**
 * BOTH upstream endpoints answer 200 for outcomes that wrote nothing, and put
 * the news in the BODY rather than on the status line:
 *
 *   /v1/data/search/…/interaction  → 200 {ok:true, recorded:false,
 *                                          reason:"recording_disabled"}
 *   /v1/data/search/…/correction   → 200 for ALL FIVE outcomes, a lost write
 *                                          included: {ok:false,
 *                                          status:"error", recorded:false}
 *
 * A proxy reading only `res.ok` overwrites that honest `recorded:false` with a
 * `true` of its own making — this route's original defect, re-entering one
 * layer up. These arms are its falsifiers, and they carry the upstream bodies
 * VERBATIM so they red if either endpoint's shape and this hop drift apart.
 */

test("exit 3b — upstream 200 with recorded:false is NOT relaid as a recorded write", async () => {
  upstreamAnswersBody(200, {
    ok: true,
    recorded: false,
    reason: "recording_disabled",
  });
  const { status, body } = await receiptOf(post(CLICK));

  assert.equal(status, 200);
  assert.equal(
    body.recorded,
    false,
    "a switched-off recorder answers 2xx and records nothing — relaying true would " +
      "re-launder the honest field the upstream went out of its way to send",
  );
  assert.match(String(body.reason), /recording_disabled/);
});

test("exit 3b — a LOST correction write (200, ok:false) is not relaid as recorded", async () => {
  // The correction endpoint's :error receipt, verbatim: a write that raised and
  // was swallowed, reported honestly on a 200 because the endpoint is
  // fire-and-forget. This is the one that costs a real signal.
  upstreamAnswersBody(200, {
    ok: false,
    status: "error",
    recorded: false,
    promoted: false,
    distinctSessions: 0,
  });
  const { status, body } = await receiptOf(post(CORRECTION));

  assert.equal(status, 200);
  assert.equal(body.recorded, false, "a lost write is not a recorded write");
  assert.match(String(body.reason), /error/);
});

test("exit 3b — a 2xx whose body says recorded:true, or says nothing, stays true", async () => {
  // The upstream's own success shape must not be downgraded…
  upstreamAnswersBody(200, { ok: true, recorded: true, interactionEventId: "e1" });
  assert.equal((await receiptOf(post(CLICK))).body.recorded, true);

  // …and neither must a 2xx we cannot parse. Inventing `recorded:false` out of
  // OUR parse failure is the same fabrication in the opposite direction: the
  // upstream said 2xx and said nothing against it.
  upstreamAnswersBody(200, "not json at all");
  assert.equal(
    (await receiptOf(post(CLICK))).body.recorded,
    true,
    "an unreadable 2xx body contradicts nothing — do not manufacture a failure",
  );

  // A genuinely body-less 2xx, the same way.
  upstreamAnswersBody(204, null);
  assert.equal((await receiptOf(post(CLICK))).body.recorded, true);
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
