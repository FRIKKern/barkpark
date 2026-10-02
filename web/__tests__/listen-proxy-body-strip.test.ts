/**
 * r4a JQ4b: the listen proxy forwarded a passed (published, served-type)
 * mutation frame VERBATIM — `result` included. That body is rendered for the
 * SERVER token this proxy attaches, so a field hidden from anonymous readers on
 * a SERVED type (and, on the replay leg, the whole `:internal` snapshot) reached
 * the browser. Forwarded mutation frames now carry only
 * eventId / mutation / type / documentId / rev / previousRev / syncTags.
 *
 * The second half proves the consumer still works: the bytes the proxy emits
 * are fed through `@barkpark/core`'s REAL listen parser (the one
 * `<BarkparkLive/>` iterates), which must still yield the mutation event —
 * `BarkparkLive` ignores the payload and only needs the event to
 * `router.refresh()`, re-reading through the normal public read path.
 *
 * Run: `cd web && node ../scripts/node-test-floor.mjs --import
 * ./__tests__/support/stub-server-only.mjs -- '__tests__/listen-proxy-body-strip.test.ts'`
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { createClient } from "@barkpark/core";

type GetHandler = (
  req: Request,
  ctx: { params: Promise<{ dataset: string }> },
) => Promise<Response>;

let server: Server;
let GET: GetHandler;
let DATASET: string;

const originalFetch = globalThis.fetch;
let sentAuth: string | null = null;
let script: string[] = [];

const HIDDEN = "HIDDEN-FIELD-VALUE";
const INTERNAL = "INTERNAL-SNAPSHOT-NOTE";

function frame(eventId: number, documentId: string): string {
  const data = {
    eventId,
    mutation: "update",
    type: "post",
    documentId,
    rev: `rev-${eventId}`,
    previousRev: `rev-${eventId - 1}`,
    result: {
      _id: documentId,
      _type: "post",
      _rev: `rev-${eventId}`,
      _draft: false,
      _publishedId: documentId,
      title: "Visible title",
      internalNotes: HIDDEN,
      _internal: { note: INTERNAL },
    },
    syncTags: [`bp:ds:docs:doc:${documentId}`, "bp:ds:docs:type:post"],
    extraUpstreamKey: "EXTRA-KEY-VALUE",
  };
  return `id: ${eventId}\nevent: mutation\ndata: ${JSON.stringify(data)}\n\n`;
}

const WELCOME = 'event: welcome\ndata: {"type":"welcome"}\n\n';

before(async () => {
  server = createServer(async (_req, res) => {
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    for (const chunk of script) {
      res.write(chunk);
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    res.end();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;

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
  sentAuth = null;
  script = [];
  globalThis.fetch = ((...args: Parameters<typeof fetch>) => {
    const [, init] = args;
    const headers = (init?.headers ?? {}) as Record<string, string>;
    sentAuth = headers.Authorization ?? null;
    return originalFetch(...args);
  }) as typeof fetch;
});

async function clientStream(query = ""): Promise<string> {
  const res = await GET(
    new Request(`http://localhost/v1/data/listen/${DATASET}${query}`),
    { params: Promise.resolve({ dataset: DATASET }) },
  );
  assert.equal(res.status, 200);
  const body = await res.text();
  assert.equal(sentAuth, "Bearer test-secret-token", "anti-vacuity: the privileged request ran");
  return body;
}

function assertNoBody(body: string): void {
  for (const secret of [HIDDEN, INTERNAL, "Visible title", "EXTRA-KEY-VALUE", '"result"']) {
    assert.ok(!body.includes(secret), `${secret} reached the anonymous client:\n${body}`);
  }
}

test("LIVE leg: a forwarded mutation frame carries no document body", async () => {
  script = [WELCOME, frame(61, "p1")];
  const body = await clientStream();
  assertNoBody(body);
  assert.ok(body.includes('"documentId":"p1"'), body);
  assert.ok(body.includes("id: 61"), `the id: line must survive for Last-Event-ID resume:\n${body}`);
  assert.ok(body.includes("event: mutation"), body);
});

test("REPLAY leg (?lastEventId=0): the same frames are stripped the same way", async () => {
  script = [frame(62, "p2"), frame(63, "p3")];
  const body = await clientStream("?lastEventId=0");
  assertNoBody(body);
  assert.ok(body.includes('"documentId":"p2"') && body.includes('"documentId":"p3"'), body);
});

test("the slim frame keeps exactly the change keys", async () => {
  script = [frame(64, "p4")];
  const body = await clientStream();
  const dataLine = body.split("\n").find((l) => l.startsWith("data: "));
  assert.ok(dataLine, body);
  const payload = JSON.parse(dataLine.slice("data: ".length));
  assert.deepEqual(Object.keys(payload).sort(), [
    "documentId",
    "eventId",
    "mutation",
    "previousRev",
    "rev",
    "syncTags",
    "type",
  ]);
  assert.equal(payload.mutation, "update");
  assert.deepEqual(payload.syncTags, ["bp:ds:docs:doc:p4", "bp:ds:docs:type:post"]);
});

test("CONSUMER: @barkpark/core's real listen parser still yields the mutation event from the stripped bytes", async () => {
  script = [WELCOME, frame(65, "p5")];
  const proxied = await clientStream();

  const client = createClient({
    projectUrl: "http://localhost",
    dataset: DATASET,
    apiVersion: "2026-04-01",
    perspective: "published",
    fetch: (async () =>
      new Response(proxied, {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
      })) as typeof fetch,
  });

  const handle = client.listen();
  const events: Array<Record<string, unknown>> = [];
  const timeout = setTimeout(() => handle.unsubscribe(), 2000);
  try {
    for await (const evt of handle) {
      events.push(evt as unknown as Record<string, unknown>);
      if (evt.type === "mutation") break;
    }
  } finally {
    clearTimeout(timeout);
    handle.unsubscribe();
  }

  const mutation = events.find((e) => e.type === "mutation");
  assert.ok(mutation, `no mutation event reached the consumer: ${JSON.stringify(events)}`);
  assert.equal(mutation.documentId, "p5");
  assert.equal(mutation.mutation, "update");
  assert.equal(mutation.result, undefined, "the consumer receives no document body");
});

test("CONSUMER: <BarkparkLive/> refreshes on ANY event — it never reads the payload", () => {
  // The live bridge `web/` mounts is @barkpark/nextjs's BarkparkLive, whose
  // subscription loop discards the event (`for await (const _evt of handle)`)
  // and only bumps the router.refresh() debounce. Pin the web side of that.
  const here = path.dirname(fileURLToPath(import.meta.url));
  const bridge = readFileSync(path.resolve(here, "..", "components", "live-bridge.tsx"), "utf8");
  assert.ok(bridge.includes("<BarkparkLive client={client} />"), "web mounts BarkparkLive");
  assert.ok(!/\.result\b/.test(bridge), "the bridge never reads a frame's result");
});
