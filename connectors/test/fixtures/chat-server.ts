import { http, HttpResponse } from "msw";
import { setupServer } from "msw/node";

import { turnStream } from "./chat-sse.js";

type MswServer = ReturnType<typeof setupServer>;

/**
 * A faithful msw mock of Barkpark's /v1/chat (charter D8 routes).
 *
 *   POST /v1/chat/sessions              -> 201 {id,...}
 *   POST /v1/chat/sessions/:id/messages -> 202 {accepted:true}
 *   GET  /v1/chat/sessions/:id/events   -> SSE, text/event-stream
 *
 * It records the ORDER of requests, which is how the tests prove the turn loop
 * subscribes to the stream BEFORE it sends the turn. (Send-then-subscribe
 * silently drops the opening frames of every turn against the real server; a
 * mock that answers regardless of order would never catch it.)
 *
 * The events stream does not emit until the turn has been sent — exactly like
 * the real server, where there is nothing to say until a turn is running.
 */

export const API_URL = "http://chat.test";

export interface MockChat {
  server: MswServer;
  /** Request log, in order, e.g. ["create_session", "events", "messages"]. */
  calls: string[];
  /** Session ids handed out by POST /v1/chat/sessions. */
  createdSessions: string[];
  /** Bodies posted to /messages. */
  sentMessages: { sessionId: string; content: string }[];
  /** Set the assistant's reply for the next turn. */
  setReply(text: string): void;
  reset(): void;
}

export function createMockChat(initialReply = "hello from barkpark"): MockChat {
  const state = {
    calls: [] as string[],
    createdSessions: [] as string[],
    sentMessages: [] as { sessionId: string; content: string }[],
    reply: initialReply,
    /**
     * Streams parked waiting for a turn to be sent. Each `events` request
     * parks here; each `messages` request wakes them all.
     *
     * This is what makes the mock protective rather than decorative: a client
     * that POSTs the turn BEFORE subscribing leaves no waiter to wake, so its
     * stream never emits and the test times out — which is exactly what would
     * happen against the real server, only there it would silently truncate
     * the turn instead.
     */
    waiters: [] as (() => void)[],
    counter: 0,
  };

  const server = setupServer(
    http.post(`${API_URL}/v1/chat/sessions`, ({ request }) => {
      if (request.headers.get("authorization") !== `Bearer test-token`) {
        return new HttpResponse(null, { status: 401 });
      }
      state.calls.push("create_session");
      const id = `session-${++state.counter}`;
      state.createdSessions.push(id);
      return HttpResponse.json({ id, title: null }, { status: 201 });
    }),

    http.post(
      `${API_URL}/v1/chat/sessions/:id/messages`,
      async ({ request, params }) => {
        state.calls.push("messages");
        const body = (await request.json()) as { content: string };
        state.sentMessages.push({
          sessionId: String(params.id),
          content: body.content,
        });
        // Wake every parked stream: the turn is now running.
        const waking = state.waiters.splice(0);
        for (const wake of waking) wake();
        return HttpResponse.json({ accepted: true }, { status: 202 });
      },
    ),

    http.get(`${API_URL}/v1/chat/sessions/:id/events`, () => {
      state.calls.push("events");

      const turnSent = new Promise<void>((resolve) => state.waiters.push(resolve));

      const stream = new ReadableStream<Uint8Array>({
        async start(controller) {
          const encode = (s: string) => new TextEncoder().encode(s);
          // Nothing to say until a turn is running — same as the real server.
          await turnSent;
          for (const frame of turnStream(state.reply)) {
            controller.enqueue(encode(frame));
          }
          controller.close();
        },
      });

      return new HttpResponse(stream, {
        status: 200,
        headers: { "content-type": "text/event-stream" },
      });
    }),
  );

  return {
    server,
    get calls() {
      return state.calls;
    },
    get createdSessions() {
      return state.createdSessions;
    },
    get sentMessages() {
      return state.sentMessages;
    },
    setReply(text: string) {
      state.reply = text;
    },
    reset() {
      state.calls.length = 0;
      state.createdSessions.length = 0;
      state.sentMessages.length = 0;
      state.counter = 0;
      // Release anything still parked so a failed test cannot hang the next.
      for (const wake of state.waiters.splice(0)) wake();
    },
  };
}
