// The `/v1/chat/sessions/:id/events` SSE reader — the streaming half of the
// bridge (charter D12/D26/D33). It opens the stream, drives a manual `\n\n`
// frame-boundary parser over `response.body.getReader()`, and yields typed
// frames as an AsyncIterable which the turn loop accumulates into ONE reply.
// (There is no `thread.stream()` to pipe into — D26. Streaming to a channel is
// `thread.post(finalText)`, called exactly once per turn.)
//
// EXACT wire (api/lib/barkpark_web/controllers/chat_controller.ex, verbatim):
//   message      => "id: <seq>\nevent: message\ndata: <json>\n\n"   (ONLY message carries id:)
//   chat         => "event: chat\ndata: <verbatim stream-json>\n\n" (NO id, opaque passthrough)
//   permission   => "event: permission\ndata: <json>\n\n"          (NO id)
//   exit         => "event: exit\ndata: {status,reason}\n\n"        (NO id)
//   keepalive    => ": keepalive\n\n"                                (comment — tolerate/ignore)

import {
  ChatClientError,
  type ChatClientConfig,
  type ChatEvent,
  type ExitFrame,
  type ExitReason,
  type OpenEventStreamOptions,
} from "./types.js";

const EXIT_REASONS: ReadonlySet<string> = new Set([
  "clean",
  "crashed",
  "idle_reaped",
  "failed_start",
  "unknown",
]);

/**
 * Parse ONE raw SSE block (the bytes between two `\n\n` boundaries, boundary
 * excluded) into a typed frame, or `null` when the block is a comment-only
 * keepalive / carries no recognized `event:` (tolerated, never thrown).
 *
 * SSE field grammar (WHATWG): a line is `field: value` (one optional leading
 * space after the colon is stripped) or a bare `field`; a line starting with
 * `:` is a comment. Multiple `data:` lines concatenate with `\n`.
 */
export function parseFrame(block: string): ChatEvent | null {
  let event: string | undefined;
  let id: string | undefined;
  const dataLines: string[] = [];
  let sawData = false;

  for (const line of block.split("\n")) {
    if (line === "") continue;
    if (line.startsWith(":")) continue; // comment (keepalive)

    const colon = line.indexOf(":");
    const field = colon === -1 ? line : line.slice(0, colon);
    let value = colon === -1 ? "" : line.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);

    switch (field) {
      case "event":
        event = value;
        break;
      case "id":
        id = value;
        break;
      case "data":
        dataLines.push(value);
        sawData = true;
        break;
      default:
        // Unknown field — ignore per SSE spec (forward-compatible).
        break;
    }
  }

  if (event === undefined) return null; // comment-only / no event line
  const dataStr = sawData ? dataLines.join("\n") : "";

  switch (event) {
    case "message": {
      // ONLY message frames carry id: — it is the Last-Event-ID resume cursor.
      const seq = id === undefined ? NaN : Number(id);
      return { type: "message", id: seq, data: tryParseJson(dataStr) };
    }
    case "chat":
      // OPAQUE passthrough — keep the verbatim bytes; decode is best-effort only.
      return { type: "chat", raw: dataStr, data: tryParseJson(dataStr) };
    case "permission":
      return { type: "permission", data: tryParseJson(dataStr) };
    case "exit":
      return { type: "exit", data: parseExit(dataStr) };
    default:
      // An event type we do not model yet — tolerate (do not throw).
      return null;
  }
}

/** Best-effort JSON decode; returns the raw string when it does not parse. */
function tryParseJson(s: string): unknown {
  try {
    return JSON.parse(s);
  } catch {
    return s;
  }
}

/** Coerce the exit payload to the fixed public contract {status:int|null, reason}. */
function parseExit(dataStr: string): ExitFrame["data"] {
  const parsed = tryParseJson(dataStr);
  const obj = (parsed && typeof parsed === "object" ? parsed : {}) as Record<
    string,
    unknown
  >;
  const rawStatus = obj["status"];
  const status = typeof rawStatus === "number" ? rawStatus : null;
  const rawReason = obj["reason"];
  const reason: ExitReason =
    typeof rawReason === "string" && EXIT_REASONS.has(rawReason)
      ? (rawReason as ExitReason)
      : "unknown";
  return { status, reason };
}

/**
 * Open the SSE stream and return an AsyncIterable of typed frames.
 *
 * EAGER ON PURPOSE. The HTTP handshake happens inside THIS promise, so once it
 * resolves, the server-side subscription exists and the caller can safely post
 * the turn.
 *
 * This is not a style preference — it is a bug fix. The first version was an
 * `async *` generator, and generator bodies are LAZY: the fetch did not fire
 * until the first `.next()`. The turn loop READ as though it subscribed first,
 * but actually posted the turn before the stream existed — dropping the opening
 * frames of every turn against a real /v1/chat, where the stream is a separate
 * GET. Returning a Promise makes "subscribed" an awaitable fact rather than an
 * assumption.
 *
 * `lastEventId` (a row `seq`) becomes the `Last-Event-ID` header, so the server
 * replays only persisted rows with `seq > lastEventId` as `event: message`
 * before going live. A non-2xx open throws a typed ChatClientError; 401/403 are
 * terminal and a stream open is never retried on them.
 */
export async function openEventStream(
  config: ChatClientConfig,
  id: string,
  options: OpenEventStreamOptions = {},
): Promise<AsyncIterable<ChatEvent>> {
  const base = config.baseUrl.replace(/\/+$/, "");
  const fetchImpl = config.fetch ?? globalThis.fetch;
  if (typeof fetchImpl !== "function") {
    throw new TypeError("openEventStream: no fetch available (pass config.fetch)");
  }

  const headers: Record<string, string> = {
    authorization: `Bearer ${config.token}`,
    accept: "text/event-stream",
  };
  if (options.lastEventId !== undefined) {
    headers["last-event-id"] = String(options.lastEventId);
  }

  const res = await fetchImpl(
    `${base}/v1/chat/sessions/${encodeURIComponent(id)}/events`,
    {
      method: "GET",
      headers,
      // Wired through so a turn timeout or a process shutdown actually tears the
      // HTTP request down. Without it, a long-lived bridge leaks one connection
      // per abandoned turn.
      ...(options.signal ? { signal: options.signal } : {}),
    },
  );

  if (!res.ok) {
    const envelope = (await res.json().catch(() => null)) as {
      error?: { code?: unknown; message?: unknown; request_id?: unknown };
    } | null;
    const err = envelope?.error;
    throw new ChatClientError({
      code: typeof err?.code === "string" ? err.code : `http_${res.status}`,
      status: res.status,
      message:
        typeof err?.message === "string"
          ? err.message
          : `chat event stream failed (${res.status})`,
      ...(typeof err?.request_id === "string" ? { requestId: err.request_id } : {}),
    });
  }

  if (!res.body) {
    throw new ChatClientError({
      code: "network_error",
      status: res.status,
      message: "chat event stream returned no body",
    });
  }

  return frameIterable(res.body);
}

/**
 * Drain the byte stream into typed SSE frames. Split out from the open above so
 * the handshake can be awaited independently of consumption — which is the whole
 * point of the eager `openEventStream`.
 */
function frameIterable(body: ReadableStream<Uint8Array>): AsyncIterable<ChatEvent> {
  return {
    async *[Symbol.asyncIterator](): AsyncGenerator<ChatEvent, void, unknown> {
      const reader = body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (value) buffer += decoder.decode(value, { stream: true });

          // Drain every COMPLETE frame (terminated by a blank line) from the buffer.
          let boundary = buffer.indexOf("\n\n");
          while (boundary !== -1) {
            const block = buffer.slice(0, boundary);
            buffer = buffer.slice(boundary + 2);
            const frame = parseFrame(block);
            if (frame) yield frame;
            boundary = buffer.indexOf("\n\n");
          }

          if (done) break;
        }
      } finally {
        // Cancel (not just release) the reader so an early break — the turn
        // loop calling iterator.return() after a result frame, or any other
        // consumer walking away mid-stream — actually tears the underlying
        // HTTP connection down. releaseLock() alone only detaches the reader
        // from the stream; it does not cancel the fetch, so the connection
        // (and the server-side subprocess reading from it) leaked open.
        await reader.cancel().catch(() => {});
      }
    },
  };
}
