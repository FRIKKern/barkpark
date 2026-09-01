/**
 * `/v1/data/listen/[dataset]` must not stream UNPUBLISHED documents to the
 * browser — asserted on the bytes the CLIENT receives, not on the URL the
 * handler wrote.
 *
 * WHY A SECOND FILE NEXT TO `listen-proxy-perspective.test.ts`: that file
 * proves the handler PINS `?perspective=published` on the upstream URL. It does
 * — and the pin is INERT. Measured on the API:
 *
 *   grep -c perspective api/lib/barkpark_web/controllers/listen_controller.ex
 *   -> 0
 *
 * `ListenController.listen/2` reads exactly one thing off params
 * (`params["lastEventId"]`), and neither `Barkpark.Content.EventLog` nor
 * `Barkpark.Content.Broadcast` has a perspective concept. So the pinned param
 * is discarded upstream and the stream is whatever the SERVER TOKEN can see.
 * The browser connects here with no token and this handler attaches the
 * privileged one, so "the API clamps an anonymous caller" stops being true at
 * exactly the moment the credential is added. Drafts flow: the API's own
 * `listen_controller_test.exs` seeds `drafts.l1`, replays it, and asserts it IS
 * emitted.
 *
 * The REPLAY leg is the bigger half. `lastEventId` is forwarded untouched and
 * `EventLog.replay_since/4` has no publish filter at all, so `?lastEventId=0`
 * replays the dataset's whole `mutation_events` table — whose `document` column
 * is written as `Envelope.render(doc, nil, :internal)`, the FULL internal
 * snapshot.
 *
 * These tests therefore read the response BODY. Every one also asserts the
 * Authorization header WAS attached, because a pass obtained by
 * `BARKPARK_TOKEN` going missing would prove nothing: an anonymous upstream
 * request is clamped by the API on its own, so the filter under test would
 * never have run.
 *
 * Run: `cd web && node ../scripts/node-test-floor.mjs --import
 * ./__tests__/support/stub-server-only.mjs -- '__tests__/listen-proxy-draft-clamp.test.ts'`
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

/** The chunks the stub upstream writes, in order, one TCP write each. */
let script: string[] = [];

/**
 * SSE frames shaped exactly like `ListenController.format_event/2`:
 * `id:` / `event: mutation` / a single `data:` line holding the JSON envelope,
 * terminated by a blank line. `result` is an `Envelope.render/3` output, so it
 * carries the reserved keys `_id`, `_draft` and `_publishedId` — redaction
 * never drops those (they are in `@reserved`).
 */
function frame(
  eventId: number,
  documentId: string,
  extra: Record<string, unknown>,
): string {
  const draft = documentId.startsWith("drafts.");
  const publishedId = draft ? documentId.slice("drafts.".length) : documentId;
  const data = {
    eventId,
    mutation: "update",
    type: "post",
    documentId,
    rev: `rev-${eventId}`,
    previousRev: null,
    result: {
      _id: documentId,
      _type: "post",
      _rev: `rev-${eventId}`,
      _draft: draft,
      _publishedId: publishedId,
      _createdAt: "2026-01-01T00:00:00Z",
      _updatedAt: "2026-01-01T00:00:00Z",
      ...extra,
    },
    syncTags: [`bp:ds:docs:doc:${publishedId}`, `bp:ds:docs:type:post`],
  };
  return `id: ${eventId}\nevent: mutation\ndata: ${JSON.stringify(data)}\n\n`;
}

const PUBLISHED = frame(41, "p1", {
  title: "Published Post",
  body: "PUBLIC-BODY",
});
const DRAFT = frame(42, "drafts.l1", {
  title: "Secret Draft",
  body: "UNPUBLISHED-SECRET",
});
const WELCOME = 'event: welcome\ndata: {"type":"welcome"}\n\n';
const KEEPALIVE = ": keepalive\n\n";

before(async () => {
  server = createServer(async (_req, res) => {
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    for (const chunk of script) {
      res.write(chunk);
      // Force a real TCP boundary between scripted writes so a frame split
      // across `script` entries genuinely arrives in two reads.
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
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
  script = [];
  globalThis.fetch = ((...args: Parameters<typeof fetch>) => {
    const [input, init] = args;
    sentUrl = typeof input === "string" ? input : String(input);
    const headers = (init?.headers ?? {}) as Record<string, string>;
    sentAuth = headers.Authorization ?? null;
    return originalFetch(...args);
  }) as typeof fetch;
});

/**
 * THE ANTI-VACUITY GUARD. An upstream request with no token is ANONYMOUS, and
 * the API clamps an anonymous caller by itself — so a green obtained without
 * this assertion would be a green for the wrong reason and would survive
 * deleting the filter under test.
 */
function assertPrivileged(): void {
  assert.ok(sentUrl, "the handler never reached upstream");
  assert.equal(
    sentAuth,
    "Bearer test-secret-token",
    "the clamp must hold on the PRIVILEGED request — a missing token would make this test vacuous",
  );
}

/** Drive the handler and read every byte the CLIENT would receive. */
async function clientStream(query = ""): Promise<string> {
  const res = await GET(
    new Request(`http://localhost/v1/data/listen/${DATASET}${query}`),
    { params: Promise.resolve({ dataset: DATASET }) },
  );
  assert.equal(res.status, 200);
  return await res.text();
}

test("a drafts. document in the LIVE stream never reaches the client", async () => {
  script = [WELCOME, PUBLISHED, DRAFT];

  const body = await clientStream();
  assertPrivileged();

  assert.ok(
    !body.includes("UNPUBLISHED-SECRET"),
    `draft content reached the browser under the server token:\n${body}`,
  );
  assert.ok(
    !body.includes("drafts.l1"),
    `the draft document id reached the browser:\n${body}`,
  );
  assert.ok(
    body.includes("PUBLIC-BODY"),
    `the published document must still stream — the filter must not be a mute:\n${body}`,
  );
});

test("?lastEventId=0 REPLAY is filtered the same way as the live leg", async () => {
  // EventLog.replay_since/4 has no publish filter, so the whole
  // mutation_events table for the dataset comes back — drafts included.
  script = [WELCOME, DRAFT, PUBLISHED, DRAFT];

  const body = await clientStream("?lastEventId=0");
  assertPrivileged();

  assert.ok(
    sentUrl && new URL(sentUrl).searchParams.get("lastEventId") === "0",
    "the replay cursor is forwarded upstream — this test must exercise the replay leg",
  );
  assert.ok(
    !body.includes("UNPUBLISHED-SECRET"),
    `replayed draft content reached the browser:\n${body}`,
  );
  assert.ok(body.includes("PUBLIC-BODY"), body);
});

test("a draft frame SPLIT ACROSS TWO CHUNKS is still dropped whole", async () => {
  // Cut mid-JSON, so neither half is a parseable frame on its own. A filter
  // that does not buffer across chunk boundaries leaks the tail.
  const cut = Math.floor(DRAFT.length / 2);
  script = [WELCOME, DRAFT.slice(0, cut), DRAFT.slice(cut), PUBLISHED];

  const body = await clientStream();
  assertPrivileged();

  assert.ok(
    !body.includes("UNPUBLISHED-SECRET"),
    `a chunk-split draft frame leaked:\n${body}`,
  );
  assert.ok(
    !body.includes("drafts.l1"),
    `a chunk-split draft id leaked:\n${body}`,
  );
  assert.ok(body.includes("PUBLIC-BODY"), body);
});

test("a PUBLISHED frame split across two chunks still arrives intact", async () => {
  const cut = Math.floor(PUBLISHED.length / 2);
  script = [WELCOME, PUBLISHED.slice(0, cut), PUBLISHED.slice(cut)];

  const body = await clientStream();
  assertPrivileged();

  assert.ok(
    body.includes("PUBLIC-BODY"),
    `buffering must reassemble a split published frame, not swallow it:\n${body}`,
  );
  assert.ok(
    body.includes("id: 41"),
    `the SSE id: line must survive so Last-Event-ID resume still works:\n${body}`,
  );
});

test("a MALFORMED frame is dropped, not forwarded", async () => {
  const malformed = "id: 43\nevent: mutation\ndata: {not json at all\n\n";
  script = [WELCOME, malformed, PUBLISHED];

  const body = await clientStream();
  assertPrivileged();

  assert.ok(
    !body.includes("not json at all"),
    `an unparseable frame must fail CLOSED — it is exactly what an attacker aims for:\n${body}`,
  );
  assert.ok(body.includes("PUBLIC-BODY"), body);
});

test("a mutation frame with NO published/draft discriminator is dropped", async () => {
  // No documentId, no result._id, no result._draft: nothing on the wire says
  // this is published, so it must not be forwarded.
  const opaque =
    'id: 44\nevent: mutation\ndata: {"eventId":44,"mutation":"update","type":"post","body":"OPAQUE-PAYLOAD"}\n\n';
  script = [WELCOME, opaque, PUBLISHED];

  const body = await clientStream();
  assertPrivileged();

  assert.ok(
    !body.includes("OPAQUE-PAYLOAD"),
    `absent discriminator must DROP, not pass:\n${body}`,
  );
  assert.ok(body.includes("PUBLIC-BODY"), body);
});

test("welcome and keepalive frames still pass through", async () => {
  script = [WELCOME, KEEPALIVE, PUBLISHED, KEEPALIVE];

  const body = await clientStream();
  assertPrivileged();

  assert.ok(
    body.includes("event: welcome"),
    `the welcome frame carries no document and must survive:\n${body}`,
  );
  assert.ok(
    body.includes(": keepalive"),
    `heartbeat comment lines must survive or the connection is judged dead:\n${body}`,
  );
});

test("SSE framing is preserved: every forwarded frame ends in a blank line", async () => {
  script = [WELCOME, DRAFT, PUBLISHED, DRAFT];

  const body = await clientStream();
  assertPrivileged();

  // A dropped frame must not corrupt its neighbours: what is left must still
  // split cleanly into whole frames on the blank-line terminator.
  assert.ok(body.endsWith("\n\n"), `stream does not end on a frame boundary:\n${body}`);
  const blocks = body.split("\n\n").filter((b) => b.length > 0);
  for (const block of blocks) {
    for (const line of block.split("\n")) {
      assert.ok(
        /^(id|event|data|retry):/.test(line) || line.startsWith(":"),
        `not a legal SSE line — framing was corrupted by a drop: ${JSON.stringify(line)}`,
      );
    }
  }
  assert.equal(
    blocks.filter((b) => b.includes('"eventId"')).length,
    1,
    `exactly the one published mutation should remain:\n${body}`,
  );
});
