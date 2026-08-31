/**
 * `/v1/data/listen/[dataset]` must refuse a `dataset` path segment that
 * differs from `lib/config.ts`'s configured `DATASET` — BEFORE the
 * privileged server token is attached and BEFORE any upstream fetch. Every
 * sibling route in `web/` fixes the dataset from `lib/config.ts`; this proxy
 * is the one route that used to take it straight from the browser's URL.
 *
 * `fetch` is spied (not replaced with a stub) so the disallowed-dataset case
 * proves the upstream was never touched, while the configured-dataset case
 * still exercises the proxy against a REAL local HTTP server.
 *
 * Run: `cd web && node ../scripts/node-test-floor.mjs --import
 * ./__tests__/support/stub-server-only.mjs -- '__tests__/listen-proxy-dataset.test.ts'`
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
let fetchCallCount = 0;

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
  fetchCallCount = 0;
  globalThis.fetch = ((...args: Parameters<typeof fetch>) => {
    fetchCallCount += 1;
    return originalFetch(...args);
  }) as typeof fetch;
});

function listenRequest(dataset: string): Request {
  return new Request(`http://localhost/v1/data/listen/${dataset}`);
}

test("disallowed dataset: refused with 404, fetch is NEVER called", async () => {
  const res = await GET(listenRequest("some-other-dataset"), {
    params: Promise.resolve({ dataset: "some-other-dataset" }),
  });

  assert.equal(res.status, 404, "a dataset outside the configured one must be refused, not proxied");
  assert.equal(
    fetchCallCount,
    0,
    "the refusal must happen before any upstream fetch — the privileged server token must never be attached for a disallowed dataset",
  );
});

test("configured dataset: still proxies to upstream", async () => {
  const res = await GET(listenRequest(DATASET), {
    params: Promise.resolve({ dataset: DATASET }),
  });

  assert.equal(res.status, 200, "the configured dataset must still reach the upstream listen endpoint");
  assert.equal(fetchCallCount, 1, "exactly one upstream fetch for the configured dataset");
  assert.equal(res.headers.get("content-type"), "text/event-stream; charset=utf-8");
});
