import { describe, expect, it } from "vitest";

import { openEventStream, parseFrame } from "../src/chat-client/sse.js";
import { createChatClient } from "../src/chat-client/client.js";
import { runTurn } from "../src/turn/turn-loop.js";
import type { ChatEvent } from "../src/chat-client/types.js";
import { SESSION_ID, TEST_BASE, TOKEN_WS_BOUND } from "./fixtures/handlers.js";

/**
 * WIRE-TOLERANCE PIN — the connectors chat client must survive SSE event types
 * that were added to /v1/chat AFTER it froze (charter D278; wave
 * connectors-wave-35-2026-08-17).
 *
 * #6537 added two NEW server frames — `event: stable` / `event: stable_end`
 * (api/lib/barkpark_web/controllers/chat_controller.ex sse_stable_frame/1,
 * :758-762 — the mobile live-document snapshot frames, D59/D63) — AFTER the
 * bridge chat client froze at #6156. Nothing in this repo models them, and the
 * question this file settles is whether that silent-drop is REAL or a hope:
 *
 *   1. PARSER LAYER   — parseFrame hits its `default:` branch for an unmodelled
 *                       event and returns null (sse.ts:89-91), so a stable frame
 *                       never becomes a ChatEvent.
 *   2. STREAM LAYER   — frameIterable yields only truthy frames (sse.ts:222), so
 *                       a dropped (null) frame never surfaces to the consumer.
 *                       Interleaving stable frames THROUGH the assistant chunks
 *                       yields EXACTLY the 3 chat frames and no more. That exact
 *                       count is the structural non-vacuity: routing stable
 *                       through the chat branch (the build-time mutation) makes
 *                       it 5, reddening this file.
 *   3. RECONSTRUCTION — runTurn (turn-loop.ts:128 skips every non-chat frame)
 *                       accumulates "Hello world" and completes, unperturbed by
 *                       the interleaved stable frames.
 *   4. GLUED CHUNKS   — a stable frame's bytes arriving in the SAME network
 *                       chunk as the following chat frame still reconstruct: the
 *                       `\n\n` boundary parser is not confused by the adjacency.
 *
 * This is the DELETED W35 verifier probe, committed so CI owns the fact. It
 * drives the REAL openEventStream + runTurn (never a hand-built ChatClient) over
 * synthetic byte streams. The stable frames are emitted as their OWN SSE event
 * types, byte-for-byte as chat_controller.ex serializes them — never disguised
 * as `event: chat`.
 */

const config = { baseUrl: TEST_BASE, token: TOKEN_WS_BOUND };

// ── byte-exact frame builders ────────────────────────────────────────────────
// chat mirrors handlers.ts chatFrame; stable/stable_end mirror
// chat_controller.ex sse_stable_frame/1 VERBATIM.

const chatFrame = (streamJsonLine: string): string =>
  `event: chat\ndata: ${streamJsonLine}\n\n`;

const stableFrame = (payload: unknown): string =>
  `event: stable\ndata: ${JSON.stringify(payload)}\n\n`;

const stableEndFrame = (payload: unknown): string =>
  `event: stable_end\ndata: ${JSON.stringify(payload)}\n\n`;

// The stream-json lines the assistant/result deltas carry inside `event: chat`.
const ASSISTANT_HELLO = JSON.stringify({
  type: "assistant",
  message: { content: [{ type: "text", text: "Hello " }] },
});
const ASSISTANT_WORLD = JSON.stringify({
  type: "assistant",
  message: { content: [{ type: "text", text: "world" }] },
});
const RESULT_LINE = JSON.stringify({
  type: "result",
  subtype: "success",
  result: "Hello world",
});

// A representative live-document snapshot payload (shape is irrelevant to the
// bridge — it is dropped whole; only that it is emitted as its OWN event type
// matters).
const STABLE_PAYLOAD = { doc: { blocks: [{ type: "text", text: "Hello " }] } };
const STABLE_END_PAYLOAD = { doc: { blocks: [] }, final: true };

// The interleaved script exactly as the brief cuts it:
//   chat(assistant "Hello "), stable, chat(assistant "world"), stable_end,
//   chat(result "Hello world")
const INTERLEAVED: string[] = [
  chatFrame(ASSISTANT_HELLO),
  stableFrame(STABLE_PAYLOAD),
  chatFrame(ASSISTANT_WORLD),
  stableEndFrame(STABLE_END_PAYLOAD),
  chatFrame(RESULT_LINE),
];

/** Wrap frame strings (already chunked as provided) in an SSE ReadableStream Response. */
function sseStream(chunks: string[]): Response {
  const enc = new TextEncoder();
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      for (const c of chunks) controller.enqueue(enc.encode(c));
      controller.close();
    },
  });
  return new Response(body, {
    status: 200,
    headers: { "content-type": "text/event-stream" },
  });
}

/**
 * An injected fetch that answers the REAL client's two calls: the SSE GET with
 * the supplied chunked byte stream, and the turn POST with a 202. No msw — the
 * raw ReadableStream reaches the real parser directly.
 */
function fetchOver(chunks: string[]): typeof fetch {
  return (async (input: Parameters<typeof fetch>[0]) => {
    const url = typeof input === "string" ? input : input.toString();
    if (url.endsWith("/events")) return sseStream(chunks);
    if (url.endsWith("/messages")) {
      return new Response(JSON.stringify({ accepted: true }), {
        status: 202,
        headers: { "content-type": "application/json" },
      });
    }
    throw new Error(`unexpected fetch to ${url}`);
  }) as typeof fetch;
}

async function collect(chunks: string[]): Promise<ChatEvent[]> {
  const out: ChatEvent[] = [];
  const stream = await openEventStream(
    { ...config, fetch: fetchOver(chunks) },
    SESSION_ID,
  );
  for await (const frame of stream) out.push(frame);
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. PARSER LAYER — the unmodelled event types drop to null (never a frame).
// ─────────────────────────────────────────────────────────────────────────────

describe("parseFrame — stable/stable_end are unmodelled and drop to null", () => {
  it("parses a `stable` frame to null rather than throwing", () => {
    expect(
      parseFrame(`event: stable\ndata: ${JSON.stringify(STABLE_PAYLOAD)}`),
    ).toBeNull();
  });

  it("parses a `stable_end` frame to null rather than throwing", () => {
    expect(
      parseFrame(`event: stable_end\ndata: ${JSON.stringify(STABLE_END_PAYLOAD)}`),
    ).toBeNull();
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// 2. STREAM LAYER — openEventStream yields EXACTLY the 3 chat frames.
//
// THE COUNT IS THE PROOF. Interleaving two stable frames through the assistant
// chunks and getting back exactly 3 chat frames (not 5) is what would break if
// stable were routed through the chat branch — the build-time mutation that
// reds this file. See the moduledoc.
// ─────────────────────────────────────────────────────────────────────────────

describe("openEventStream — stable frames never surface to the consumer", () => {
  it("yields EXACTLY 3 chat frames from the interleaved stream — no stable frames", async () => {
    const frames = await collect(INTERLEAVED);

    // Every yielded frame is a chat frame — nothing else made it through.
    expect(frames).toHaveLength(3);
    expect(frames.every((f) => f.type === "chat")).toBe(true);

    // And explicitly: no `stable`/`stable_end` frame surfaced under any type.
    const types = frames.map((f) => (f as { type: string }).type);
    expect(types).not.toContain("stable");
    expect(types).not.toContain("stable_end");

    // The 3 chat frames are the assistant deltas + the result, in order.
    const chats = frames as Array<{ raw: string }>;
    expect(chats.map((c) => c.raw)).toEqual([
      ASSISTANT_HELLO,
      ASSISTANT_WORLD,
      RESULT_LINE,
    ]);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// 3. RECONSTRUCTION — the REAL runTurn accumulates "Hello world" and completes,
//    counting exactly 3 chat frames despite the interleaved stable frames.
// ─────────────────────────────────────────────────────────────────────────────

describe("runTurn — reconstruction is unperturbed by interleaved stable frames", () => {
  it('reconstructs "Hello world", completes, and counts exactly 3 chat frames', async () => {
    const client = createChatClient({ ...config, fetch: fetchOver(INTERLEAVED) });

    const turn = await runTurn(client, {
      sessionUuid: SESSION_ID,
      content: "hi",
    });

    expect(turn.text).toBe("Hello world");
    expect(turn.completed).toBe(true);
    // The structural non-vacuity: 2 assistant deltas + 1 result. Routing the 2
    // stable frames through the chat branch (the build-time mutation) makes this 5.
    expect(turn.chatFrames).toBe(3);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// 4. GLUED CHUNKS — a stable frame's bytes arriving in the SAME network chunk as
//    the following chat frame still reconstruct: the `\n\n` boundary parser is
//    not confused by the adjacency.
// ─────────────────────────────────────────────────────────────────────────────

describe("stable frames glued to the following chat frame in one network chunk", () => {
  // Each network chunk deliberately carries a stable frame's bytes IMMEDIATELY
  // followed by the next chat frame — the worst case for the boundary parser.
  const GLUED: string[] = [
    chatFrame(ASSISTANT_HELLO),
    stableFrame(STABLE_PAYLOAD) + chatFrame(ASSISTANT_WORLD),
    stableEndFrame(STABLE_END_PAYLOAD) + chatFrame(RESULT_LINE),
  ];

  it("still yields exactly 3 chat frames when stable+chat share a chunk", async () => {
    const frames = await collect(GLUED);
    expect(frames).toHaveLength(3);
    expect(frames.every((f) => f.type === "chat")).toBe(true);
    expect((frames as Array<{ raw: string }>).map((c) => c.raw)).toEqual([
      ASSISTANT_HELLO,
      ASSISTANT_WORLD,
      RESULT_LINE,
    ]);
  });

  it('still reconstructs "Hello world" and completes through runTurn', async () => {
    const client = createChatClient({ ...config, fetch: fetchOver(GLUED) });

    const turn = await runTurn(client, {
      sessionUuid: SESSION_ID,
      content: "hi",
    });

    expect(turn.text).toBe("Hello world");
    expect(turn.completed).toBe(true);
    expect(turn.chatFrames).toBe(3);
  });
});
