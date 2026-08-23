/**
 * pds — `/api/search-seed` must let its DECLARED consumer tell an engine
 * failure from an empty corpus.
 *
 * The route's own docblock declares who reads it: "an explicit fetchable
 * endpoint for tooling / diagnostics" — a consumer that sees the HTTP answer
 * and nothing else. It never sees the exception, so `{index:{},docs:[]}` served
 * 200 is, for that consumer, a healthy corpus with nothing in it. The keystroke
 * path is unaffected either way: it reads the seed as an SSR-inlined prop
 * (`app/(finder)/layout.tsx`), not by fetching this route.
 *
 * So the seed answers two things a diagnostics client can act on:
 *   - `error` in the body — null when the index descends from an engine answer,
 *     the reason when it descends from a failure;
 *   - the status line — 503 on failure, because `res.ok` is the first check a
 *     diagnostics client writes and it must not read green for a seed that was
 *     never built.
 *
 * The upstream is a REAL local HTTP server: `lib/bp-fetch.ts` dispatches
 * through undici's own fetch + keep-alive Agent, so a `globalThis.fetch` stub
 * would never be consulted.
 *
 * Run: `pnpm test` (from web/).
 */

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { DEFAULT_ENGINE } from "../lib/find.ts";

interface SeedBody {
  index?: Record<string, number[]>;
  docs?: { id: string; title: string; slug: string; type: string }[];
  error?: string | null;
}

let answer: { status: number; body: unknown } = { status: 200, body: {} };

/** The upstream URL of the LAST request the route issued — what the
 * engine-parity arm reads to prove which engine the seed descends from. */
let lastUrl: string | null = null;

let server: Server;
let GET: () => Promise<Response>;

before(async () => {
  server = createServer((req, res) => {
    lastUrl = req.url ?? null;
    res.writeHead(answer.status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(answer.body));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  // `lib/bp-env.ts` resolves the API base URL at MODULE LOAD.
  process.env.NEXT_PUBLIC_BARKPARK_API_URL = `http://127.0.0.1:${port}`;
  ({ GET } = await import("../app/api/search-seed/route.ts"));
});

after(() => {
  server.close();
});

async function seedOf(): Promise<{ status: number; body: SeedBody }> {
  const res = await GET();
  return { status: res.status, body: (await res.json()) as SeedBody };
}

/* ── the engine answered ───────────────────────────────────────────────── */

test("engine answered: the seed is built and `error` is null", async () => {
  answer = {
    status: 200,
    body: {
      documents: [
        { _id: "p1", _type: "post", title: "Alpha", slug: "alpha" },
        { _id: "p2", _type: "post", title: "Beta", slug: "beta" },
      ],
      count: 2,
      engineUsed: "indx",
    },
  };
  const { status, body } = await seedOf();

  assert.equal(status, 200);
  assert.equal(body.docs?.length, 2, "both browse hits must reach the seed");
  assert.ok(body.index?.["a"], "the index must carry the prefix buckets");
  assert.equal(body.error, null, "a built seed carries no error");
});

test("engine answered with an EMPTY corpus: 200 and `error` stays null", async () => {
  answer = { status: 200, body: { documents: [], count: 0, engineUsed: "indx" } };
  const { status, body } = await seedOf();

  assert.equal(status, 200, "an empty corpus is a healthy answer, not a failure");
  assert.deepEqual(body.docs, []);
  assert.deepEqual(body.index, {});
  assert.equal(
    body.error,
    null,
    "an empty corpus must not be dressed up as a failure — that is the same " +
      "fabrication in the opposite direction",
  );
});

/* ── the engine did not answer ─────────────────────────────────────────── */

test("engine down: the empty index says so, in the body AND on the status line", async () => {
  answer = {
    status: 500,
    body: { error: { message: "search engine is down", code: "engine_down" } },
  };
  const { status, body } = await seedOf();

  assert.equal(
    status,
    503,
    "the declared tooling/diagnostics consumer reads res.ok first — an " +
      "unbuilt seed must not answer green",
  );
  assert.deepEqual(body.docs, [], "nothing was built, so nothing is reported");
  assert.deepEqual(body.index, {});
  assert.match(
    String(body.error),
    /search engine is down/,
    "the reason must descend from the engine failure, not be invented here",
  );
  assert.match(
    String(body.error),
    /500/,
    "and it must name the upstream status the failure came from",
  );
});

test("engine down: the failure is NOT pinned in the hour-long edge cache", async () => {
  answer = {
    status: 500,
    body: { error: { message: "search engine is down", code: "engine_down" } },
  };
  const res = await GET();

  assert.equal(
    res.headers.get("cache-control"),
    "no-store",
    "s-maxage=3600 on a failed seed would serve a seconds-long outage for an hour",
  );
});

test("the success answer keeps its cache header", async () => {
  answer = {
    status: 200,
    body: {
      documents: [{ _id: "p1", _type: "post", title: "Alpha", slug: "alpha" }],
      count: 1,
      engineUsed: "indx",
    },
  };
  const res = await GET();

  assert.match(String(res.headers.get("cache-control")), /s-maxage=3600/);
});

/* ── engine parity with the (finder) layout's inlined seed ─────────────── */

test("engine parity: the fetchable seed browses DEFAULT_ENGINE, the engine the finder actually inlines", async () => {
  answer = { status: 200, body: { documents: [], count: 0 } };
  lastUrl = null;
  await GET();

  assert.ok(lastUrl, "the route must have issued an upstream browse");
  const engine = new URL(lastUrl!, "http://x").searchParams.get("engine");
  // The (finder) layout builds the seed it inlines from its own DEFAULT_ENGINE
  // browse (app/(finder)/layout.tsx). This route claims to serve the same
  // construction over HTTP, so a hardcoded different engine here (the drift
  // that sat unnoticed from birth to 2026-08-23: `engine: "indx"` vs the
  // landing's postgres) would make the fetchable seed carry a DIFFERENT
  // relevance ordering than the one the finder ships. Parity, not a hardcode:
  // if DEFAULT_ENGINE ever changes, both sides move together and this stays
  // green.
  assert.equal(
    engine,
    DEFAULT_ENGINE,
    `the seed browse must ride DEFAULT_ENGINE (${DEFAULT_ENGINE}) — got engine=${engine}; the fetchable seed and the layout's inlined seed must descend from the same engine ordering`,
  );
});
