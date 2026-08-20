/**
 * Recorded /v1/chat SSE frames — byte-faithful to the real wire.
 *
 * Frame shapes copied from the Phoenix controller
 * (api/lib/barkpark_web/controllers/chat_controller.ex):
 *
 *   sse_chat_frame:  "event: chat\ndata: <json>\n\n"
 *   sse_exit_frame:  "event: exit\ndata: <json>\n\n"
 *   sse_keepalive:   ": keepalive\n\n"
 *
 * The claude stream-json payloads inside `event: chat` are shaped like the
 * recorded fixtures in api/test/fixtures/claude_chat/*.ndjson — including the
 * `thinking` and `tool_use` blocks that must NEVER reach a Telegram chat.
 *
 * If these drift from the real controller, the mock is lying and the tests are
 * vacuous. That is the whole reason they are transcribed, not invented.
 */

export const KEEPALIVE = ": keepalive\n\n";

export function chatFrame(payload: unknown): string {
  return `event: chat\ndata: ${JSON.stringify(payload)}\n\n`;
}

export function exitFrame(payload: unknown): string {
  return `event: exit\ndata: ${JSON.stringify(payload)}\n\n`;
}

/** An assistant frame carrying internal-only blocks — nothing user-visible. */
export const ASSISTANT_THINKING = {
  type: "assistant",
  message: {
    model: "claude-haiku-4-5-20251001",
    id: "msg_011Ccs5iZuvCLtBKe3MQ7QSo",
    type: "message",
    role: "assistant",
    content: [
      { type: "thinking", thinking: "The user said hi. I should greet them." },
      {
        type: "tool_use",
        id: "toolu_01J4",
        name: "Read",
        input: { file: "/etc/passwd" },
      },
    ],
    stop_reason: null,
  },
};

/** An assistant frame with real visible text. */
export function assistantText(text: string) {
  return {
    type: "assistant",
    message: {
      model: "claude-haiku-4-5-20251001",
      id: "msg_011Ccs5j6QURdXs663WGTPus",
      type: "message",
      role: "assistant",
      content: [{ type: "text", text }],
      stop_reason: null,
    },
  };
}

/** The terminal frame. `result` is the authoritative final text (D26). */
export function resultFrame(result: string, sessionId = "fixture-session") {
  return {
    type: "result",
    subtype: "success",
    is_error: false,
    terminal_reason: "completed",
    result,
    session_id: sessionId,
    uuid: "turn-1-result",
  };
}

/**
 * One complete turn on the wire: keepalive, internal-only blocks, streamed
 * text, then the result frame that ends the turn.
 */
export function turnStream(finalText: string): string[] {
  return [
    KEEPALIVE,
    chatFrame(ASSISTANT_THINKING),
    chatFrame(assistantText(finalText)),
    chatFrame(resultFrame(finalText)),
  ];
}

/**
 * A turn whose subprocess exits AFTER the result. `exit` must never be treated
 * as turn-completion (D26) — the turn already completed on `result`.
 */
export function turnStreamWithTrailingExit(finalText: string): string[] {
  return [...turnStream(finalText), exitFrame({ status: 0, reason: "completed" })];
}
