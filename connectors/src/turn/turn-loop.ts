import type { ChatClient, ChatEvent } from "../chat-client/types.js";

/**
 * The per-turn glue (charter D12/D21/D26).
 *
 * Cadence is POST-ONCE-PER-TURN, not live-edit: accumulate the assistant text
 * off the SSE stream and hand back ONE final string. The caller posts it once.
 *
 * Two things the SDK does NOT give us, and this loop must get right:
 *
 *  1. There is NO `thread.stream()` (D26). Streaming to the channel is
 *     `thread.post(finalText)`, called exactly once.
 *
 *  2. Turn completion is the stream-json `type:"result"` frame — NOT
 *     `event: exit`. `exit` means the subprocess died; the /v1/chat stream
 *     deliberately stays open for lazy resume. Treating exit as completion
 *     truncates turns.
 *
 * Ordering matters: we OPEN the SSE stream before we POST the turn. The send
 * is a separate 202 call, so subscribing after it would race the first frames
 * onto the floor.
 */

export interface RunTurnInput {
  sessionUuid: string;
  /** The user's text for this turn. */
  content: string;
  /**
   * Ack hook (D21): fired the moment /v1/chat accepts the turn (202), long
   * before the model speaks. Deliberately NOT a channel post — posting an ack
   * message would break the post-once-per-turn contract. Wire it to a typing
   * indicator or a log.
   */
  onAck?: () => void | Promise<void>;
  /** Hard ceiling for a turn. Default 10 minutes. */
  timeoutMs?: number;
  signal?: AbortSignal;
}

export interface TurnResult {
  /** The final assistant text — post this ONCE. */
  text: string;
  /** Number of `event: chat` frames observed (diagnostics). */
  chatFrames: number;
  /** True when the turn ended on a stream-json `result` frame. */
  completed: boolean;
}

/** The runTurn signature — the seam core/dispatch injects in tests. */
export type RunTurnResultHook = (
  client: ChatClient,
  input: RunTurnInput,
) => Promise<TurnResult>;

export class TurnTimeoutError extends Error {
  constructor(sessionUuid: string, timeoutMs: number) {
    super(
      `turn on session ${sessionUuid} produced no result frame within ${timeoutMs}ms`,
    );
    this.name = "TurnTimeoutError";
  }
}

const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;

export async function runTurn(
  client: ChatClient,
  input: RunTurnInput,
): Promise<TurnResult> {
  const { sessionUuid, content, onAck, signal } = input;
  const timeoutMs = input.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  const controller = new AbortController();
  const abortOuter = () => controller.abort();
  signal?.addEventListener("abort", abortOuter);

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);

  try {
    // 1. Subscribe FIRST, and AWAIT the handshake. The stream is a separate
    //    GET; opening it after the send would drop the opening frames of the
    //    turn. (`openEventStream` returns a promise precisely so this await
    //    actually establishes the subscription — a lazy generator would not.)
    const stream = await client.openEventStream(sessionUuid, {
      signal: controller.signal,
    });
    const iterator = stream[Symbol.asyncIterator]();

    // 2. Send the turn. 202 = accepted, the model has not spoken yet.
    try {
      await client.postMessage(sessionUuid, content);
      if (onAck) await onAck();
    } catch (err) {
      // The stream is already open (its HTTP connection exists) but nothing
      // has iterated it yet, so it would otherwise leak: close the iterator
      // (a no-op if the underlying generator never started) and abort the
      // controller (the actual teardown — sse.ts wired this signal through to
      // the fetch that owns the connection) before rethrowing.
      await iterator.return?.().catch(() => {});
      controller.abort();
      throw err;
    }

    // 3. Drain until the stream-json `result` frame.
    let accumulated = "";
    let chatFrames = 0;

    for (;;) {
      let next: IteratorResult<ChatEvent>;
      try {
        next = await iterator.next();
      } catch (err) {
        // An abort surfaces here as an AbortError. If it was OUR timeout,
        // say so plainly instead of leaking a transport error.
        if (timedOut) throw new TurnTimeoutError(sessionUuid, timeoutMs);
        throw err;
      }
      if (next.done) break;

      const event = next.value;
      // Only `chat` frames carry turn text. `message` is the durable row echo,
      // `permission` is an approval ask, and `exit` means the subprocess died —
      // none of them complete a turn (D26).
      if (event.type !== "chat") continue;
      chatFrames += 1;

      const frame = event.data as Record<string, unknown> | null;
      if (!frame || typeof frame !== "object") continue;

      if (frame.type === "assistant") {
        accumulated += assistantText(frame);
        continue;
      }

      if (frame.type === "result") {
        // The result frame carries the authoritative final text. Fall back to
        // what we accumulated if it is absent.
        const final = typeof frame.result === "string" ? frame.result : accumulated;
        await iterator.return?.();
        return { text: final.trim(), chatFrames, completed: true };
      }
      // Every other frame type (system, user, tool_use echoes, ...) is not
      // turn-final text. `exit` never completes a turn (D26).
    }

    if (timedOut) throw new TurnTimeoutError(sessionUuid, timeoutMs);

    // The stream ended without a result frame. Return what we heard rather
    // than fabricating a completion — the caller decides whether to post.
    return { text: accumulated.trim(), chatFrames, completed: false };
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", abortOuter);
  }
}

/**
 * Pull the visible text out of a claude stream-json `assistant` frame.
 * `thinking` and `tool_use` blocks are internal — they never reach the channel.
 */
function assistantText(frame: Record<string, unknown>): string {
  const message = frame.message as { content?: unknown } | undefined;
  const content = message?.content;
  if (!Array.isArray(content)) return "";

  let text = "";
  for (const block of content) {
    if (
      block &&
      typeof block === "object" &&
      (block as { type?: unknown }).type === "text" &&
      typeof (block as { text?: unknown }).text === "string"
    ) {
      text += (block as { text: string }).text;
    }
  }
  return text;
}
