import { describe, expect, it, vi } from "vitest";

import { runTurn, TurnTimeoutError } from "../src/turn/turn-loop.js";
import type {
  ChatClient,
  ChatEvent,
  ChatSession,
  OpenEventStreamOptions,
  PostMessageResult,
} from "../src/chat-client/types.js";

/**
 * The per-turn glue (charter D12/D21/D26). These are the proofs W3-3 owed.
 *
 * The load-bearing claim is a NEGATIVE one: `event: exit` must NOT complete a
 * turn. `exit` means the claude subprocess died; /v1/chat deliberately keeps the
 * stream open for lazy resume, so treating exit as completion truncates the turn
 * — you post half an answer and drop the rest. The ONLY completion signal is the
 * stream-json `type:"result"` frame carried inside `event: chat`.
 *
 * Frames are driven through a hand-built ChatClient rather than msw: the point
 * here is the loop's reaction to a frame SEQUENCE, and a queue makes the ordering
 * explicit and pauseable.
 */

const SESSION = "11111111-2222-4333-8444-555555555555";

const session = (id: string): ChatSession => ({
  id,
  title: null,
  status: "idle",
  mode: "plan",
  model: null,
  cwd: "/tmp",
  message_count: 0,
});

/** A stream-json `assistant` frame, as it arrives verbatim inside `event: chat`. */
const assistant = (...texts: string[]): ChatEvent => ({
  type: "chat",
  raw: "",
  data: {
    type: "assistant",
    message: { content: texts.map((text) => ({ type: "text", text })) },
  },
});

/** The turn-completion frame. THIS ends a turn — nothing else does. */
const result = (text: string): ChatEvent => ({
  type: "chat",
  raw: "",
  data: { type: "result", subtype: "success", result: text },
});

/** The subprocess died. The stream stays open; the turn is NOT over. */
const exit = (reason: "clean" | "crashed" = "crashed"): ChatEvent => ({
  type: "exit",
  data: { status: reason === "clean" ? 0 : 1, reason },
});

interface Spy {
  client: ChatClient;
  order: string[];
  postedTurns: string[];
}

/**
 * A ChatClient over a fixed frame list. Records the WIRE ORDER so a regression to
 * send-before-subscribe is visible, and closes the stream when the frames run out.
 */
function spyClient(frames: ChatEvent[]): Spy {
  const order: string[] = [];
  const postedTurns: string[] = [];

  const client: ChatClient = {
    async createSession() {
      order.push("create_session");
      return session(SESSION);
    },
    async getSession(id) {
      return session(id);
    },
    async postMessage(_id, content): Promise<PostMessageResult> {
      order.push("messages");
      postedTurns.push(content);
      return { accepted: true };
    },
    async openEventStream(
      _id,
      _options?: OpenEventStreamOptions,
    ): Promise<AsyncIterable<ChatEvent>> {
      order.push("events");
      return {
        async *[Symbol.asyncIterator]() {
          for (const frame of frames) yield frame;
        },
      };
    },
  };

  return { client, order, postedTurns };
}

describe("runTurn — post-once-per-turn (D12/D26)", () => {
  it("subscribes to the stream BEFORE sending the turn", async () => {
    const spy = spyClient([result("ok")]);

    await runTurn(spy.client, { sessionUuid: SESSION, content: "hi" });

    // The stream is a SEPARATE GET from the send. Subscribe after sending and the
    // opening frames of the turn are gone.
    expect(spy.order).toEqual(["events", "messages"]);
  });

  it("accumulates assistant text and completes on the stream-json result frame", async () => {
    const spy = spyClient([
      assistant("Hello"),
      assistant(", "),
      assistant("world"),
      result("Hello, world"),
    ]);

    const turn = await runTurn(spy.client, {
      sessionUuid: SESSION,
      content: "hi",
    });

    expect(turn.completed).toBe(true);
    expect(turn.text).toBe("Hello, world");
    // The turn text is sent to /v1/chat exactly once — the reply is posted to the
    // channel exactly once by the caller (see dispatch).
    expect(spy.postedTurns).toEqual(["hi"]);
  });

  it("an event:exit with NO preceding result does NOT complete the turn (D26)", async () => {
    // The subprocess died mid-turn and then RESUMED — /v1/chat keeps the stream
    // open precisely so this can happen. If exit were treated as completion we
    // would post "Partial" and silently drop the rest of the answer.
    const spy = spyClient([
      assistant("Partial"),
      exit("crashed"),
      assistant(" then the rest"),
      result("Partial then the rest"),
    ]);

    const turn = await runTurn(spy.client, {
      sessionUuid: SESSION,
      content: "hi",
    });

    expect(turn.completed).toBe(true);
    expect(turn.text).toBe("Partial then the rest");
  });

  it("does not fabricate a completion when the stream ends with no result frame", async () => {
    const spy = spyClient([assistant("half an answer"), exit("crashed")]);

    const turn = await runTurn(spy.client, {
      sessionUuid: SESSION,
      content: "hi",
    });

    // Honest: we report what we heard and that the turn never completed. We do
    // NOT claim success — the caller decides what to do with a partial turn.
    expect(turn.completed).toBe(false);
    expect(turn.text).toBe("half an answer");
  });

  it("never leaks thinking or tool_use blocks into the channel", async () => {
    const spy = spyClient([
      {
        type: "chat",
        raw: "",
        data: {
          type: "assistant",
          message: {
            content: [
              { type: "thinking", thinking: "the user probably means..." },
              { type: "tool_use", name: "Bash", input: { cmd: "ls" } },
              { type: "text", text: "Here you go." },
            ],
          },
        },
      },
      result("Here you go."),
    ]);

    const turn = await runTurn(spy.client, {
      sessionUuid: SESSION,
      content: "hi",
    });

    expect(turn.text).toBe("Here you go.");
    expect(turn.text).not.toContain("thinking");
    expect(turn.text).not.toContain("Bash");
  });

  it("ignores message/permission frames — they are not turn text", async () => {
    const spy = spyClient([
      { type: "message", id: 1, data: { role: "user" } },
      { type: "permission", data: { tool: "Bash" } },
      assistant("clean"),
      result("clean"),
    ]);

    const turn = await runTurn(spy.client, {
      sessionUuid: SESSION,
      content: "hi",
    });

    expect(turn.text).toBe("clean");
    expect(turn.chatFrames).toBe(2); // the assistant frame + the result frame
  });
});

describe("runTurn — ack-first (D21)", () => {
  it("fires onAck on the 202, before any model output is consumed", async () => {
    const seen: string[] = [];
    const spy = spyClient([assistant("slow answer"), result("slow answer")]);
    const onAck = vi.fn(() => {
      seen.push("ack");
    });

    await runTurn(spy.client, {
      sessionUuid: SESSION,
      content: "hi",
      onAck,
    });

    expect(onAck).toHaveBeenCalledTimes(1);
    // The ack fires off the 202 — it never waits for the model to speak. That is
    // the whole point of D21's <=10s ack-latency target.
    expect(seen).toEqual(["ack"]);
    expect(spy.order).toEqual(["events", "messages"]);
  });

  /**
   * HONEST DEVIATION from W3-3's brief, recorded as a test rather than buried.
   *
   * The brief asked for a "canned ack POSTED" before the model output. The bridge
   * deliberately does NOT post an ack MESSAGE: posting an ack and then the reply
   * would be TWO posts per turn, breaking post-once-per-turn (D12/D26) — the very
   * cadence this wave exists to establish. `onAck` is a hook (typing indicator /
   * telemetry); the user-visible ack is the adapter's own typing indicator.
   *
   * Gap: a typing indicator is not guaranteed on every surface. Filed as
   * `connectors-ack-first-visible-indicator`.
   */
  it("does NOT post an ack message — the ack is a hook, not a second post (D12)", async () => {
    const spy = spyClient([assistant("answer"), result("answer")]);

    const turn = await runTurn(spy.client, {
      sessionUuid: SESSION,
      content: "hi",
      onAck: () => {},
    });

    // Exactly ONE thing was sent to /v1/chat: the user's turn. The ack produced no
    // extra outbound message, so the channel still gets exactly one reply.
    expect(spy.postedTurns).toEqual(["hi"]);
    expect(turn.text).toBe("answer");
  });
});

describe("runTurn — post-open teardown when postMessage rejects (leak fix)", () => {
  it("closes the iterator and aborts the controller before rethrowing", async () => {
    // The stream opens successfully (its HTTP connection now exists) but the
    // send that follows fails. Before the fix, the outer `finally` only
    // cleared the timeout — the open stream leaked forever, since nothing had
    // pulled a frame yet to notice the abort.
    const calls = { iteratorReturn: 0 };
    let capturedSignal: AbortSignal | undefined;

    const client: ChatClient = {
      async createSession() {
        return session(SESSION);
      },
      async getSession(id) {
        return session(id);
      },
      async postMessage(): Promise<PostMessageResult> {
        throw new Error("network down");
      },
      async openEventStream(_id, options?: OpenEventStreamOptions) {
        capturedSignal = options?.signal;
        return {
          [Symbol.asyncIterator]() {
            return {
              async next(): Promise<IteratorResult<ChatEvent>> {
                throw new Error("should never be pulled — postMessage fails first");
              },
              async return(value?: unknown): Promise<IteratorResult<ChatEvent>> {
                calls.iteratorReturn += 1;
                return { value, done: true } as IteratorResult<ChatEvent>;
              },
            };
          },
        };
      },
    };

    await expect(
      runTurn(client, { sessionUuid: SESSION, content: "hi" }),
    ).rejects.toThrow("network down");

    expect(calls.iteratorReturn).toBe(1);
    expect(capturedSignal?.aborted).toBe(true);
  });
});

describe("runTurn — timeouts", () => {
  it("converts a hung turn into a typed TurnTimeoutError", async () => {
    const client: ChatClient = {
      async createSession() {
        return session(SESSION);
      },
      async getSession(id) {
        return session(id);
      },
      async postMessage(): Promise<PostMessageResult> {
        return { accepted: true };
      },
      async openEventStream(_id, options?: OpenEventStreamOptions) {
        return {
          async *[Symbol.asyncIterator](): AsyncGenerator<ChatEvent> {
            // A stream that never produces a result frame and never closes —
            // exactly what a wedged runtime looks like from here.
            await new Promise((_resolve, reject) => {
              options?.signal?.addEventListener("abort", () =>
                reject(new Error("aborted")),
              );
            });
          },
        };
      },
    };

    await expect(
      runTurn(client, {
        sessionUuid: SESSION,
        content: "hi",
        timeoutMs: 50,
      }),
    ).rejects.toBeInstanceOf(TurnTimeoutError);
  });
});
