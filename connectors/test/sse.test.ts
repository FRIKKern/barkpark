import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { http } from "msw";
import { openEventStream, parseFrame } from "../src/chat-client/sse.js";
import { ChatClientError, type ChatEvent } from "../src/chat-client/types.js";
import { server } from "./fixtures/server.js";
import {
  SESSION_ID,
  TEST_BASE,
  TOKEN_NO_WORKSPACE,
  TOKEN_WS_BOUND,
  chatFrame,
  errorResponse,
  exitFrame,
  fixtureStreamJsonLines,
  keepaliveFrame,
  messageFrame,
  permissionFrame,
  resetRecorded,
  sseResponse,
} from "./fixtures/handlers.js";

const config = { baseUrl: TEST_BASE, token: TOKEN_WS_BOUND };

beforeAll(() => server.listen({ onUnhandledRequest: "error" }));
afterEach(() => {
  server.resetHandlers();
  resetRecorded();
});
afterAll(() => server.close());

async function collect(id: string, lastEventId?: number): Promise<ChatEvent[]> {
  const out: ChatEvent[] = [];
  const stream = await openEventStream(
    config,
    id,
    lastEventId === undefined ? {} : { lastEventId },
  );
  for await (const frame of stream) out.push(frame);
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// The EAGER-SUBSCRIBE invariant. This is a regression guard, not a nicety.
//
// openEventStream was once an `async *` generator. Generator bodies are LAZY —
// the fetch does not fire until the first `.next()`. The turn loop READ as
// though it subscribed before sending, but the GET had not happened yet, so
// against a real /v1/chat (where the stream is a SEPARATE GET from the POST)
// the opening frames of every turn landed on the floor.
//
// The fix is the return type: a Promise whose resolution IS the handshake. This
// test fails on any regression to a lazy generator, because it asserts the
// server was hit without a single frame being consumed.
// ─────────────────────────────────────────────────────────────────────────────

describe("eager subscribe (D26 — the stream is a separate GET from the send)", () => {
  it("completes the HTTP handshake on await, BEFORE any frame is read", async () => {
    let hits = 0;
    server.use(
      http.get(`${TEST_BASE}/v1/chat/sessions/:id/events`, () => {
        hits += 1;
        return sseResponse([chatFrame('{"type":"result","result":"hi"}')]);
      }),
    );

    expect(hits).toBe(0);
    const stream = await openEventStream(config, SESSION_ID);

    // The subscription exists NOW — nothing has been iterated. A lazy generator
    // would still read 0 here, and the turn loop would post into the void.
    expect(hits).toBe(1);

    // And the frames are still all there for the consumer that arrives later.
    const out: ChatEvent[] = [];
    for await (const frame of stream) out.push(frame);
    expect(out).toHaveLength(1);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// The byte-exact frame contract. These literals are the EXACT bytes
// chat_controller.ex emits — a change here is a wire break.
// ─────────────────────────────────────────────────────────────────────────────

describe("parseFrame — byte-exact wire contract", () => {
  it("parses a message frame and reads its `id:` (the only frame that carries one)", () => {
    const frame = parseFrame(
      'id: 5\nevent: message\ndata: {"seq":5,"role":"user"}',
    );
    expect(frame).toEqual({
      type: "message",
      id: 5,
      data: { seq: 5, role: "user" },
    });
  });

  it("parses a chat frame with NO id and passes the payload through VERBATIM", () => {
    const line = '{"type":"assistant","message":{"role":"assistant"}}';
    const frame = parseFrame(`event: chat\ndata: ${line}`);
    expect(frame).toMatchObject({ type: "chat", raw: line });
    expect(frame).not.toHaveProperty("id");
    // raw is byte-identical to what the server put on the wire.
    expect((frame as { raw: string }).raw).toBe(line);
  });

  it("parses a permission frame with NO id", () => {
    const frame = parseFrame(
      'event: permission\ndata: {"request_id":"r1","tool":"Bash"}',
    );
    expect(frame).toEqual({
      type: "permission",
      data: { request_id: "r1", tool: "Bash" },
    });
    expect(frame).not.toHaveProperty("id");
  });

  it("parses an exit frame with NO id into {status,reason}", () => {
    expect(parseFrame('event: exit\ndata: {"status":0,"reason":"clean"}')).toEqual({
      type: "exit",
      data: { status: 0, reason: "clean" },
    });
    expect(
      parseFrame('event: exit\ndata: {"status":null,"reason":"idle_reaped"}'),
    ).toEqual({
      type: "exit",
      data: { status: null, reason: "idle_reaped" },
    });
    expect(
      parseFrame('event: exit\ndata: {"status":1,"reason":"crashed"}'),
    ).toEqual({
      type: "exit",
      data: { status: 1, reason: "crashed" },
    });
  });

  it("coerces an out-of-enum exit reason to `unknown` and a non-int status to null", () => {
    expect(
      parseFrame('event: exit\ndata: {"status":"boom","reason":"weird"}'),
    ).toEqual({
      type: "exit",
      data: { status: null, reason: "unknown" },
    });
  });

  it("tolerates the `: keepalive` comment frame (yields nothing, never throws)", () => {
    expect(parseFrame(": keepalive")).toBeNull();
  });

  it("tolerates an unmodelled event type rather than throwing", () => {
    expect(parseFrame('event: future_thing\ndata: {"x":1}')).toBeNull();
  });

  it("NEVER schema-validates a chat payload — malformed JSON still passes through", () => {
    const frame = parseFrame("event: chat\ndata: {not json at all");
    expect(frame).toMatchObject({ type: "chat", raw: "{not json at all" });
    // Best-effort decode falls back to the raw string; nothing throws.
    expect((frame as { data: unknown }).data).toBe("{not json at all");
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// openEventStream against the msw mock built from those literal bytes.
// ─────────────────────────────────────────────────────────────────────────────

describe("openEventStream", () => {
  it("replays persisted message rows, then live chat, permission and exit frames", async () => {
    const frames = await collect(SESSION_ID);

    const messages = frames.filter((f) => f.type === "message");
    expect(messages.map((m) => (m as { id: number }).id)).toEqual([1, 2]);

    // Keepalive is tolerated — it never surfaces as a frame.
    expect(frames.some((f) => (f as { type: string }).type === "keepalive")).toBe(
      false,
    );

    const chats = frames.filter((f) => f.type === "chat");
    expect(chats).toHaveLength(3);

    expect(frames.filter((f) => f.type === "permission")).toHaveLength(1);

    const exit = frames.at(-1);
    expect(exit).toEqual({ type: "exit", data: { status: 0, reason: "clean" } });
  });

  it("resumes with Last-Event-ID: only rows with seq > lastEventId replay", async () => {
    const frames = await collect(SESSION_ID, 1);
    const messages = frames.filter((f) => f.type === "message");

    // seq 1 is already seen — the server must not replay it.
    expect(messages.map((m) => (m as { id: number }).id)).toEqual([2]);
    // The live tail still arrives.
    expect(frames.filter((f) => f.type === "chat")).toHaveLength(3);
  });

  it("sends the Last-Event-ID header only when a cursor is supplied", async () => {
    let seen: string | null | undefined;
    server.use(
      http.get(`${TEST_BASE}/v1/chat/sessions/:id/events`, ({ request }) => {
        seen = request.headers.get("last-event-id");
        expect(request.headers.get("accept")).toBe("text/event-stream");
        expect(request.headers.get("authorization")).toBe(
          `Bearer ${TOKEN_WS_BOUND}`,
        );
        return sseResponse([exitFrame(0, "clean")]);
      }),
    );

    await collect(SESSION_ID);
    expect(seen).toBeNull();

    await collect(SESSION_ID, 42);
    expect(seen).toBe("42");
  });

  it("drives REAL recorded claude stream-json lines through as verbatim chat payloads", async () => {
    // Provenance: copied md5-identical from
    // api/test/fixtures/claude_chat/foreground_task.ndjson (commit 9edfd5c1).
    const lines = fixtureStreamJsonLines("foreground_task.ndjson");
    expect(lines.length).toBe(22);

    server.use(
      http.get(`${TEST_BASE}/v1/chat/sessions/:id/events`, () =>
        sseResponse([...lines.map(chatFrame), exitFrame(0, "clean")]),
      ),
    );

    const frames = await collect(SESSION_ID);
    const chats = frames.filter((f) => f.type === "chat") as Array<{
      raw: string;
      data: unknown;
    }>;

    // Every recorded line arrives byte-identical — no re-encode, no validation.
    expect(chats).toHaveLength(lines.length);
    expect(chats.map((c) => c.raw)).toEqual(lines);

    // And the opaque payload still decodes to the real stream-json objects.
    const types = chats.map((c) => (c.data as { type?: string }).type);
    expect(types).toContain("assistant");
    expect(types).toContain("result");
    expect(types).toContain("system");
  });

  it("drives the mcp_tool_success recording through unchanged too", async () => {
    const lines = fixtureStreamJsonLines("mcp_tool_success.ndjson");
    expect(lines.length).toBe(6);

    server.use(
      http.get(`${TEST_BASE}/v1/chat/sessions/:id/events`, () =>
        sseResponse(lines.map(chatFrame)),
      ),
    );

    const chats = (await collect(SESSION_ID)) as Array<{
      type: string;
      raw: string;
    }>;
    expect(chats.map((c) => c.raw)).toEqual(lines);
  });

  it("reassembles frames split across chunk boundaries (the real network case)", async () => {
    const line = fixtureStreamJsonLines("foreground_task.ndjson", 1)[0] as string;
    const wire =
      messageFrame(1, { seq: 1, role: "user" }) +
      chatFrame(line) +
      exitFrame(0, "clean");

    server.use(
      http.get(`${TEST_BASE}/v1/chat/sessions/:id/events`, () => {
        const enc = new TextEncoder();
        const stream = new ReadableStream<Uint8Array>({
          start(controller) {
            // Slice the byte stream at 7-char boundaries — frames straddle chunks.
            for (let i = 0; i < wire.length; i += 7) {
              controller.enqueue(enc.encode(wire.slice(i, i + 7)));
            }
            controller.close();
          },
        });
        return new Response(stream, {
          status: 200,
          headers: { "content-type": "text/event-stream" },
        });
      }),
    );

    const frames = await collect(SESSION_ID);
    expect(frames).toHaveLength(3);
    expect(frames[0]).toEqual({
      type: "message",
      id: 1,
      data: { seq: 1, role: "user" },
    });
    expect(frames[1]).toMatchObject({ type: "chat", raw: line });
    expect(frames[2]).toEqual({
      type: "exit",
      data: { status: 0, reason: "clean" },
    });
  });

  it("tolerates a keepalive-only stream (no frames, no throw)", async () => {
    server.use(
      http.get(`${TEST_BASE}/v1/chat/sessions/:id/events`, () =>
        sseResponse([keepaliveFrame(), keepaliveFrame()]),
      ),
    );
    await expect(collect(SESSION_ID)).resolves.toEqual([]);
  });

  it("surfaces a workspace-less chat token as a 403 `forbidden` — and does not retry it", async () => {
    let hits = 0;
    server.use(
      http.get(`${TEST_BASE}/v1/chat/sessions/:id/events`, () => {
        hits += 1;
        return errorResponse(403, "forbidden", "token lacks required permission");
      }),
    );

    const err = await collect(SESSION_ID).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(ChatClientError);
    expect((err as ChatClientError).code).toBe("forbidden");
    expect((err as ChatClientError).status).toBe(403);
    expect(hits).toBe(1); // opened once, never retried
  });

  it("surfaces a missing bearer as 401 without retrying", async () => {
    let hits = 0;
    server.use(
      http.get(`${TEST_BASE}/v1/chat/sessions/:id/events`, () => {
        hits += 1;
        return errorResponse(401, "unauthorized", "missing bearer token");
      }),
    );

    const err = await collect(SESSION_ID).catch((e: unknown) => e);
    expect((err as ChatClientError).code).toBe("unauthorized");
    expect((err as ChatClientError).status).toBe(401);
    expect(hits).toBe(1);
  });

  it("403s the real workspace-less token against the default handler", async () => {
    // The open itself rejects — no need to pull a frame to discover the 403.
    const err = await openEventStream(
      { baseUrl: TEST_BASE, token: TOKEN_NO_WORKSPACE },
      SESSION_ID,
    ).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(ChatClientError);
    expect((err as ChatClientError).status).toBe(403);
  });

  it("cancels the underlying reader (not just releases it) when the consumer breaks early", async () => {
    // Regression guard for the teardown leak: the finally block used to call
    // ONLY reader.releaseLock(), which detaches the reader without canceling
    // the source — the underlying fetch (and the server-side subprocess
    // reading from it) stayed open forever on an early break. cancel()
    // reaches the ReadableStream's underlying source, so this test fails on
    // any regression back to releaseLock()-only teardown.
    //
    // Driven through an injected `config.fetch` (not msw) so the raw
    // ReadableStream's cancel() callback is observed directly, with no
    // service-worker passthrough in between.
    let cancelled = false;
    let cancelReason: unknown;
    const enc = new TextEncoder();
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(
          enc.encode(chatFrame('{"type":"result","result":"first"}')),
        );
        // Deliberately never closes — a live connection until torn down.
      },
      cancel(reason) {
        cancelled = true;
        cancelReason = reason;
      },
    });
    const fakeFetch = (async () =>
      new Response(body, {
        status: 200,
        headers: { "content-type": "text/event-stream" },
      })) as typeof fetch;

    const stream = await openEventStream(
      { baseUrl: TEST_BASE, token: TOKEN_WS_BOUND, fetch: fakeFetch },
      SESSION_ID,
    );
    const iterator = stream[Symbol.asyncIterator]();

    const first = await iterator.next();
    expect(first.done).toBe(false);
    expect(cancelled).toBe(false); // still consuming — nothing torn down yet

    // The turn loop's early-break case (turn-loop.ts, on a result frame):
    // stop iterating without draining the rest of the stream.
    await iterator.return?.();

    expect(cancelled).toBe(true);
    expect(cancelReason).toBeUndefined();
  });

  it("yields a permission frame verbatim without an id", async () => {
    server.use(
      http.get(`${TEST_BASE}/v1/chat/sessions/:id/events`, () =>
        sseResponse([
          permissionFrame({
            request_id: "toolu_9",
            tool: "Bash",
            input: { cmd: "ls" },
          }),
        ]),
      ),
    );
    const frames = await collect(SESSION_ID);
    expect(frames).toEqual([
      {
        type: "permission",
        data: { request_id: "toolu_9", tool: "Bash", input: { cmd: "ls" } },
      },
    ]);
  });
});
