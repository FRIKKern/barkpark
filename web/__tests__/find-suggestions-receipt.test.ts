/**
 * pds — `/api/find?suggest=1` must say WHERE its empty list came from.
 *
 * The suggestions arm of `app/api/find/route.ts` answers two arrays. Empty
 * arrays are a legitimate answer (a corpus nobody has searched yet), which is
 * exactly why an upstream failure must not be allowed to produce the same
 * bytes: the caller cannot tell "nothing to suggest" from "the suggestions
 * endpoint is down" unless a field descends from the upstream call.
 *
 * The same file's search path has answered that way since #9599 (bind the
 * error, thread the message, keep the status deliberate at 200); these arms
 * hold the suggestions arm to it.
 *
 * The upstream is a REAL local HTTP server rather than a stubbed global
 * `fetch`, because `lib/bp-fetch.ts` dispatches through undici's own fetch +
 * keep-alive Agent — a `globalThis.fetch` stub would never be consulted, and a
 * test that green-lights the wrong transport proves nothing. It answers a
 * structured `{error:{…}}` envelope so `bpFetchJson` classifies the failure as
 * DEFINITIVE and does not spend its restart-window retries.
 *
 * Run: `pnpm test` (from web/).
 */

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";

interface Suggestions {
  popular?: { query?: string; count?: number }[];
  nohits?: { query?: string; count?: number }[];
  error?: string | null;
}

/** What the stub upstream answers on the next request — `raw` bypasses JSON
 * encoding so the unreadable-body case can be replayed verbatim. */
interface Answer {
  status: number;
  body?: unknown;
  raw?: string;
}
let answer: Answer = { status: 200, body: {} };

let server: Server;
/** The route module, imported only AFTER the API URL env var points at us. */
let GET: (request: Request) => Promise<Response>;

before(async () => {
  server = createServer((_req, res) => {
    res.writeHead(answer.status, { "Content-Type": "application/json" });
    res.end(answer.raw ?? JSON.stringify(answer.body));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  // `lib/bp-env.ts` resolves the API base URL at MODULE LOAD, so the env var
  // has to be set before the first import of anything downstream of it.
  process.env.NEXT_PUBLIC_BARKPARK_API_URL = `http://127.0.0.1:${port}`;
  ({ GET } = await import("../app/api/find/route.ts"));
});

after(() => {
  server.close();
});

function suggestRequest(): Request {
  return new Request("http://localhost/api/find?suggest=1");
}

async function suggestionsOf(): Promise<{ status: number; body: Suggestions }> {
  const res = await GET(suggestRequest());
  return { status: res.status, body: (await res.json()) as Suggestions };
}

/* ── the upstream answered ─────────────────────────────────────────────── */

test("upstream 200: the suggestions pass through and `error` is null", async () => {
  answer = {
    status: 200,
    body: { result: { popular: [{ query: "elixir", count: 4 }], nohits: [] } },
  };
  const { status, body } = await suggestionsOf();

  assert.equal(status, 200);
  assert.deepEqual(body.popular, [{ query: "elixir", count: 4 }]);
  assert.equal(
    body.error,
    null,
    "a list that descends from an upstream answer carries no error",
  );
});

test("upstream 200 with an EMPTY corpus: still null — empty is a real answer", async () => {
  answer = { status: 200, body: { result: { popular: [], nohits: [] } } };
  const { body } = await suggestionsOf();

  assert.deepEqual(body.popular, []);
  assert.deepEqual(body.nohits, []);
  assert.equal(
    body.error,
    null,
    "nobody has searched yet is not a failure — inventing a reason here would " +
      "be the same fabrication in the opposite direction",
  );
});

/* ── the upstream failed ───────────────────────────────────────────────── */

test("upstream 500: the empty list carries the reason it is empty", async () => {
  answer = {
    status: 500,
    body: { error: { message: "search engine is down", code: "engine_down" } },
  };
  const { status, body } = await suggestionsOf();

  assert.equal(
    status,
    200,
    "an optional suggestions panel must not turn the caller's res.ok red",
  );
  assert.deepEqual(body.popular, [], "a failed call suggests nothing");
  assert.equal(
    typeof body.error,
    "string",
    "the empty list must not be reportable as one the upstream sent",
  );
  assert.match(
    String(body.error),
    /search engine is down/,
    "the message must descend from the upstream failure, not be invented here",
  );
});

test("upstream 200 that is not JSON at all: the reason still descends", async () => {
  // The API-restart shape: the socket layer accepts, and an Nginx/LB page comes
  // back on a 200. `bpFetchJson` turns that into a structured error rather than
  // a bare SyntaxError — and it must reach the body, not be swallowed.
  // (This arm spends the restart-window backoff, ~3s, by design: it is the same
  // path production takes during a `make deploy`.)
  answer = { status: 200, raw: "<html>502 Bad Gateway</html>" };
  const { status, body } = await suggestionsOf();

  assert.equal(status, 200);
  assert.deepEqual(body.popular, []);
  assert.match(
    String(body.error),
    /non-JSON/,
    "an unreadable upstream body must name itself instead of vanishing into []",
  );
});
