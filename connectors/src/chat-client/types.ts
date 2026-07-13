/**
 * The shared contract for talking to Barkpark's /v1/chat HTTP+SSE API.
 *
 * The bridge is a CLIENT of /v1/chat (charter D33) — the BEAM stays the engine.
 * This slice defines the INTERFACE and the SSE frame union; the concrete HTTP
 * implementation is W3-2 (connectors-p2-chat-client-sse) and the turn loop that
 * consumes the stream is W3-3 (connectors-p2-turn-loop). Defining the contract
 * here lets the thread<->session map (this slice) mint sessions through an
 * injected ChatClient without importing the transport, keeping the map testable
 * against a faithful mock rather than a live BEAM.
 *
 * Proven /v1/chat surface (verified against the merged ChatController, 8 routes
 * behind RequireChatAccess; wave-3 DECIDE):
 *   - POST   /v1/chat/sessions              {mode?,model?,effort?} -> {id, ...}
 *       Workspace is derived from the bearer TOKEN, never the body. Create
 *       ALWAYS mints a fresh Session UUID — there is no find-or-create, so
 *       mint-on-first / resume-thereafter is the bridge's own responsibility
 *       (see thread-session-map.ts).
 *   - GET    /v1/chat/sessions/:id          -> the session (404 if wrong tenant,
 *       indistinguishable from missing — reads are fail-closed).
 *   - POST   /v1/chat/sessions/:id/messages {content} -> 202 {accepted:true}
 *   - GET    /v1/chat/sessions/:id/events   -> the SSE stream.
 */

/** Session creation knobs. Workspace is NOT here — it rides the token. */
export interface CreateSessionInput {
  mode?: string;
  model?: string;
  effort?: string;
}

/** A Barkpark chat Session. `id` is the UUID the thread map persists. */
export interface ChatSession {
  id: string;
  mode?: string;
  model?: string;
  [key: string]: unknown;
}

/** Body of POST /v1/chat/sessions/:id/messages. */
export interface PostMessageInput {
  content: string;
}

/** 202 acknowledgement of a posted user turn. */
export interface PostMessageAck {
  accepted: true;
}

/** Options for opening the SSE event stream. */
export interface StreamEventsInput {
  /**
   * Resume cursor. The server replays `message` frames after this SSE id
   * (Last-Event-ID), then switches to the live stream. Only `message` frames
   * carry an id and are replayable; `chat`/`permission`/`exit` are not.
   */
  lastEventId?: string;
  /** Abort the long-lived stream (process shutdown, turn interrupt). */
  signal?: AbortSignal;
}

/*
 * ── SSE frame union ─────────────────────────────────────────────────────────
 * The five frame shapes /v1/chat emits. The discriminant `type` mirrors the
 * SSE `event:` name. `message` is the only id-bearing, replayable frame; `chat`
 * is the RAW Claude stream-json passthrough (no Barkpark schema); `keepalive`
 * is the `:`-comment heartbeat (~every 30s) surfaced as a typed frame so the
 * reader can distinguish a live-but-quiet stream from a stalled one.
 */

/** A durable, replayable Barkpark message row. Carries the SSE `id`. */
export interface ChatMessageFrame {
  type: "message";
  /** SSE event id — the Last-Event-ID resume cursor. */
  id: string;
  data: Record<string, unknown>;
}

/** Raw Claude stream-json delta (no Barkpark schema, not replayable). */
export interface ChatChatFrame {
  type: "chat";
  data: Record<string, unknown>;
}

/** A tool/permission approval request awaiting a decision. */
export interface ChatPermissionFrame {
  type: "permission";
  data: Record<string, unknown>;
}

/** The turn/session has ended. */
export interface ChatExitFrame {
  type: "exit";
  data: Record<string, unknown>;
}

/** The `:` keepalive comment, surfaced as a frame. */
export interface ChatKeepaliveFrame {
  type: "keepalive";
}

export type ChatSseFrame =
  | ChatMessageFrame
  | ChatChatFrame
  | ChatPermissionFrame
  | ChatExitFrame
  | ChatKeepaliveFrame;

/**
 * The transport the bridge depends on. W3-2 provides the HTTP+SSE
 * implementation; tests and the thread map depend only on this interface.
 */
export interface ChatClient {
  /** Mint a fresh Session (workspace derived from this client's token). */
  createSession(input?: CreateSessionInput): Promise<ChatSession>;
  /** Fetch a Session by id; null when missing or not this tenant's. */
  getSession(id: string): Promise<ChatSession | null>;
  /** Post a user turn; resolves on the 202 ack. */
  postMessage(sessionId: string, input: PostMessageInput): Promise<PostMessageAck>;
  /** Open the SSE event stream as an async iterable of typed frames. */
  streamEvents(sessionId: string, input?: StreamEventsInput): AsyncIterable<ChatSseFrame>;
}
