/**
 * r4a: `/v1/data/listen/[dataset]` dropped DRAFT frames but forwarded every
 * PUBLISHED frame — whatever its type. The upstream stream is rendered for the
 * SERVER token this proxy attaches (a `read`-tier or stronger token: the API
 * 403s `public-read` on listen), so a published document of a PRIVATE type
 * reached the anonymous browser with every field that token can see. Verified
 * by driving the real handler against a stub upstream: on main a published
 * `contact` frame (the starters' private submission type, carrying an email)
 * streams to the client.
 *
 * The proxy now forwards only types the site serves (`lib/find.ts` DOC_TYPES —
 * the same list search and the reader routes use). The browser only uses a
 * frame as a refresh signal, so nothing it renders is lost.
 *
 * Run: `cd web && node ../scripts/node-test-floor.mjs --import
 * ./__tests__/support/stub-server-only.mjs -- '__tests__/listen-proxy-type-clamp.test.ts'`
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
let SERVED: string[];

const originalFetch = globalThis.fetch;
let sentAuth: string | null = null;
let script: string[] = [];

function frame(
  eventId: number,
  type: string,
  documentId: string,
  extra: Record<string, unknown>,
  resultType: string = type,
): string {
  const data = {
    eventId,
    mutation: "create",
    type,
    documentId,
    rev: `rev-${eventId}`,
    previousRev: null,
    result: {
      _id: documentId,
      _type: resultType,
      _rev: `rev-${eventId}`,
      _draft: false,
      _publishedId: documentId,
      ...extra,
    },
    syncTags: [`bp:ds:docs:doc:${documentId}`, `bp:ds:docs:type:${type}`],
  };
  return `id: ${eventId}\nevent: mutation\ndata: ${JSON.stringify(data)}\n\n`;
}

const POST = frame(51, "post", "p1", { title: "Hello", body: "PUBLIC-BODY" });
const CONTACT = frame(52, "contact", "c1", {
  email: "visitor@private.example",
  message: "PRIVATE-SUBMISSION",
});
const MISLABELLED = frame(53, "post", "c2", { email: "MISLABELLED-SECRET" }, "contact");
const UNTYPED =
  `id: 54\nevent: mutation\ndata: ${JSON.stringify({
    eventId: 54,
    mutation: "create",
    documentId: "x1",
    result: { _id: "x1", _draft: false, secret: "UNTYPED-SECRET" },
  })}\n\n`;

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
  const { DOC_TYPES } = await import("../lib/find.ts");
  SERVED = DOC_TYPES.map((t: { type: string }) => t.type);
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
  // Anti-vacuity: the request upstream carried the privileged token.
  assert.equal(sentAuth, "Bearer test-secret-token");
  return body;
}

test("fixture sanity: post is a served type, contact is not", () => {
  assert.ok(SERVED.includes("post"));
  assert.ok(!SERVED.includes("contact"));
});

test("a PUBLISHED document of a type the site does not serve never reaches the client", async () => {
  script = [POST, CONTACT];
  const body = await clientStream();
  assert.ok(!body.includes("PRIVATE-SUBMISSION"), `private-type content streamed:\n${body}`);
  assert.ok(!body.includes("visitor@private.example"), `private-type field streamed:\n${body}`);
  assert.ok(body.includes("PUBLIC-BODY"), `a served type must still stream:\n${body}`);
});

test("the replay leg (?lastEventId=0) is filtered the same way", async () => {
  script = [CONTACT, POST, CONTACT];
  const body = await clientStream("?lastEventId=0");
  assert.ok(!body.includes("PRIVATE-SUBMISSION"), body);
  assert.ok(body.includes("PUBLIC-BODY"), body);
});

test("a frame whose result _type disagrees with its type, or that names no type, is dropped", async () => {
  script = [MISLABELLED, UNTYPED, POST];
  const body = await clientStream();
  assert.ok(!body.includes("MISLABELLED-SECRET"), body);
  assert.ok(!body.includes("UNTYPED-SECRET"), body);
  assert.ok(body.includes("PUBLIC-BODY"), body);
});
