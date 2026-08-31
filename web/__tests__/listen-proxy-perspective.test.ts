/**
 * `/v1/data/listen/[dataset]` must PIN the upstream `perspective` to
 * `published`, whatever the browser asked for.
 *
 * The browser connects to this proxy with NO token and the handler attaches the
 * server-only `BARKPARK_TOKEN` before forwarding. The API clamps a caller to
 * the published perspective only because that caller is ANONYMOUS — a
 * token-bearing request is not clamped. So forwarding the query string verbatim
 * (`upstream.search = incoming.search`) let any caller ask for
 * `?perspective=drafts` and receive a drafts SSE stream under the server's
 * credentials. Every other read surface in `web/` pins `published`
 * (`lib/barkpark-client.ts`, `lib/find-search.ts`, `components/live-bridge.tsx`).
 *
 * These tests read the URL the handler actually sent upstream — asserting on
 * the response alone could not tell a pinned request from a forwarded one.
 * Each also asserts the Authorization header IS present, so a "pass" can never
 * come from the token silently going missing instead of the clamp working.
 *
 * Run: `cd web && node ../scripts/node-test-floor.mjs --import
 * ./__tests__/support/stub-server-only.mjs -- '__tests__/listen-proxy-perspective.test.ts'`
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";

type GetHandler = (
  req: Request,
  ctx: { params: Promise<{ dataset: string }> },
) => Promise<Response>;

let server: Server;
let GET: GetHandler;
let DATASET: string;

const originalFetch = globalThis.fetch;
let sentUrl: string | null = null;
let sentAuth: string | null = null;

before(async () => {
  server = createServer((_req, res) => {
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    res.write(": ok\n\n");
    res.end();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;

  // `lib/bp-env.ts` and `lib/config.ts` resolve these at MODULE LOAD.
  process.env.NEXT_PUBLIC_BARKPARK_API_URL = `http://127.0.0.1:${port}`;
  process.env.BARKPARK_TOKEN = "test-secret-token";
  process.env.BARKPARK_DATASET = "docs";

  ({ DATASET } = await import("../lib/config.ts"));
  ({ GET } = await import("../app/v1/data/listen/[dataset]/route.ts"));
});

after(() => {
  server.close();
  globalThis.fetch = originalFetch;
});

beforeEach(() => {
  sentUrl = null;
  sentAuth = null;
  globalThis.fetch = ((...args: Parameters<typeof fetch>) => {
    const [input, init] = args;
    sentUrl = typeof input === "string" ? input : String(input);
    const headers = (init?.headers ?? {}) as Record<string, string>;
    sentAuth = headers.Authorization ?? null;
    return originalFetch(...args);
  }) as typeof fetch;
});

/** The `perspective` values the handler actually put on the upstream URL. */
function upstreamPerspectives(): string[] {
  assert.ok(sentUrl, "the handler never reached upstream");
  return new URL(sentUrl).searchParams.getAll("perspective");
}

async function proxy(query: string): Promise<Response> {
  return GET(new Request(`http://localhost/v1/data/listen/${DATASET}${query}`), {
    params: Promise.resolve({ dataset: DATASET }),
  });
}

test("?perspective=drafts is overwritten with published before the token is attached", async () => {
  const res = await proxy("?perspective=drafts");

  assert.equal(res.status, 200);
  assert.deepEqual(
    upstreamPerspectives(),
    ["published"],
    "a browser-supplied drafts perspective must not reach upstream — the server token would not be clamped by the API",
  );
  assert.equal(
    sentAuth,
    "Bearer test-secret-token",
    "the clamp must hold on the PRIVILEGED request; a missing token would make this test vacuous",
  );
});

test("?perspective=raw is overwritten with published too", async () => {
  await proxy("?perspective=raw");

  assert.deepEqual(upstreamPerspectives(), ["published"]);
  assert.equal(sentAuth, "Bearer test-secret-token");
});

test("a repeated perspective param cannot smuggle drafts past the pin", async () => {
  await proxy("?perspective=published&perspective=drafts");

  assert.deepEqual(
    upstreamPerspectives(),
    ["published"],
    "set() must collapse every copy — a surviving second value would be the one the server reads",
  );
});

test("an omitted perspective is filled in, not left to the upstream default", async () => {
  await proxy("");

  assert.deepEqual(upstreamPerspectives(), ["published"]);
});

test("the other forwarded params still ride through untouched", async () => {
  await proxy("?types=post&filter%5Bstatus%5D=live&perspective=drafts");

  assert.ok(sentUrl);
  const params = new URL(sentUrl).searchParams;
  assert.equal(params.get("types"), "post", "types must still be forwarded");
  assert.equal(
    params.get("filter[status]"),
    "live",
    "filter[...] must still be forwarded",
  );
  assert.deepEqual(params.getAll("perspective"), ["published"]);
});
