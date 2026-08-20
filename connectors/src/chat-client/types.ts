/**
 * The shared contract for talking to Barkpark's /v1/chat HTTP+SSE API.
 *
 * The bridge is a CLIENT of /v1/chat (charter D4/D33) — the BEAM stays the
 * engine. This file is the ONE contract every other module codes against: the
 * thread<->session map mints through it, the turn loop consumes its frames, and
 * the connectors never see the transport at all.
 *
 * Transcribed from the real Elixir on main, not guessed:
 *   api/lib/barkpark_web/controllers/chat_controller.ex   (the sse_*_frame serializers)
 *   api/lib/barkpark_web/plugs/require_chat_access.ex     (the workspace-less-token 403)
 *
 *   POST /v1/chat/sessions              {provider?,execution_target?,execution_host_id?,mode?,model?,effort?} -> 201 full session
 *   GET  /v1/chat/sessions/:id          [?since=<seq>]         -> 200 full session
 *   POST /v1/chat/sessions/:id/messages {content}              -> 202 {accepted:true}
 *   GET  /v1/chat/sessions/:id/events                          -> SSE
 *
 * Auth: `Authorization: Bearer <ApiToken>` carrying the `chat` permission. The
 * workspace is derived from the TOKEN, never from a request body. A `chat` token
 * WITHOUT a workspace_id is 403 (D33).
 *
 * NOTE the shape of the wire: sending a turn and reading its output are TWO
 * calls — the SSE stream is a separate GET, not the POST's response. That is why
 * `openEventStream` returns a Promise (see below).
 */

/**
 * A Barkpark chat Session. The server mints `id` and `cwd` — a client NEVER
 * sends them. The shape stays open (`[key: string]`) so a server-side field
 * addition never breaks a bridge that only reads `id`.
 */
export interface ChatSession {
  id: string;
  /** Present on provider-aware servers; absent on legacy fixtures/responses. */
  provider?: "claude" | "codex";
  /** Present on provider-aware servers; absent on legacy fixtures/responses. */
  execution_target?: "managed" | "registered_host";
  execution_host_id?: string | null;
  provider_session_id?: string | null;
  title: string | null;
  title_source?: string | null;
  status: string;
  mode: string;
  model: string | null;
  model_choice?: string | null;
  effort_choice?: string | null;
  cwd: string;
  message_count: number;
  messages?: ChatSessionMessage[];
  [key: string]: unknown;
}

/** A settled message row (seq-ascending) on the full-session read. */
export interface ChatSessionMessage {
  seq: number;
  role: string;
  source_markdown: string | null;
  [key: string]: unknown;
}

/**
 * Body of `POST /v1/chat/sessions`. All optional — the server preserves legacy
 * `claude` + `managed` + `plan` defaults when the identity axes are omitted.
 * `id`, `cwd` and `workspace` are NOT accepted; workspace rides the token.
 */
export interface CreateSessionInput {
  provider?: "claude" | "codex";
  execution_target?: "managed" | "registered_host";
  execution_host_id?: string;
  mode?: string;
  model?: string;
  effort?: string;
}

/** `POST /v1/chat/sessions/:id/messages` -> 202 `{accepted:true}`. */
export interface PostMessageResult {
  accepted: boolean;
}

/* ── SSE frame union ────────────────────────────────────────────────────────
 * The frame shapes /v1/chat emits, discriminated on `type` (which mirrors the
 * SSE `event:` name). Only `message` carries an `id:` — it is the Last-Event-ID
 * resume cursor. `chat` is an OPAQUE verbatim passthrough of a claude
 * stream-json line and is NEVER schema-validated: `raw` keeps the exact bytes,
 * `data` is a best-effort decode. `: keepalive` comments are tolerated and
 * skipped by the parser.
 */

export interface MessageFrame {
  type: "message";
  /** The persisted row `seq` — resumable via Last-Event-ID. */
  id: number;
  data: unknown;
}

export interface ChatFrame {
  type: "chat";
  /** Verbatim stream-json payload bytes — forwarded unchanged (D12/D26). */
  raw: string;
  /** Best-effort decode of `raw`; the raw string when it does not parse. */
  data: unknown;
}

export interface PermissionFrame {
  type: "permission";
  data: unknown;
}

/** The fixed public exit contract — status + a closed reason enum. */
export type ExitReason =
  "clean" | "crashed" | "idle_reaped" | "failed_start" | "unknown";

export interface ExitFrame {
  type: "exit";
  data: { status: number | null; reason: ExitReason };
}

export type ChatEvent = MessageFrame | ChatFrame | PermissionFrame | ExitFrame;

/**
 * The claude stream-json `result` frame, carried verbatim inside `event: chat`.
 * THIS — not `event: exit` — is the turn-completion signal (D26): exit means the
 * subprocess died, and the stream deliberately stays open for lazy resume.
 */
export interface ClaudeResultFrame {
  type: "result";
  subtype?: string;
  is_error?: boolean;
  /** The authoritative final assistant text for the turn. */
  result?: string;
  [key: string]: unknown;
}

/**
 * A structured error from the /v1/chat transport. `code` is the canonical
 * envelope code (`forbidden`, `invalid_request`, `runtime_capacity`,
 * `runtime_unavailable`, `chat_unsupported`, `chat_create_failed`, …) or a
 * synthetic `network_error` for a transport-level failure. Retry decisions key
 * off `code`, NEVER the raw status; 401/403 are terminal.
 */
export class ChatClientError extends Error {
  readonly code: string;
  readonly status: number;
  readonly requestId: string | undefined;

  constructor(opts: {
    code: string;
    status: number;
    message: string;
    requestId?: string;
  }) {
    super(opts.message);
    this.name = "ChatClientError";
    this.code = opts.code;
    this.status = opts.status;
    this.requestId = opts.requestId;
  }

  /** Auth failures are a misconfigured token, not a transient blip. */
  get terminal(): boolean {
    return this.status === 401 || this.status === 403;
  }
}

/** Config shared by the HTTP client (client.ts) and the SSE reader (sse.ts). */
export interface ChatClientConfig {
  /** Barkpark API origin, e.g. `https://guerrilla.barkpark.cloud`. */
  baseUrl: string;
  /**
   * A workspace-bound `chat`-permission ApiToken — THIS install's own, opened
   * from `connector_installs.chat_token_ref` (D35). Never a process-wide
   * operator token: the bridge no longer has one.
   */
  token: string;
  /** Injectable fetch (tests/mocks); defaults to the global `fetch`. */
  fetch?: typeof fetch;
  /** Max RETRY attempts (beyond the first try) for retryable codes. Default 2. */
  maxRetries?: number;
  /** Base linear backoff in ms between retries. Default 50. Set 0 in tests. */
  retryBackoffMs?: number;
}

/** Options for opening the SSE event stream. */
export interface OpenEventStreamOptions {
  /**
   * Resume cursor (a row `seq`). Sent as `Last-Event-ID`; the server replays
   * persisted `message` rows with `seq > lastEventId`, then goes live.
   */
  lastEventId?: number;
  /** Abort the long-lived stream (turn timeout, process shutdown). */
  signal?: AbortSignal;
}

/** The transport the bridge depends on. `client.ts` is the implementation. */
export interface ChatClient {
  /** Mint a Session. The workspace is derived from this client's token. */
  createSession(input?: CreateSessionInput): Promise<ChatSession>;
  /** Read a full Session. `since` returns only rows with `seq > since`. */
  getSession(id: string, since?: number): Promise<ChatSession>;
  /** Send a user turn; resolves on the 202 ack (the model has not spoken yet). */
  postMessage(id: string, content: string): Promise<PostMessageResult>;
  /**
   * Open the SSE stream.
   *
   * Returns a PROMISE deliberately. Awaiting it completes the HTTP handshake, so
   * the subscription exists on the server BEFORE the caller sends the turn. An
   * `async *` generator would NOT do this: generator bodies are lazy, so the
   * fetch would not fire until the first `.next()` — by which time the turn has
   * been posted and its opening frames are on the floor. This bit us once; the
   * shape of the return type is what prevents it recurring.
   */
  openEventStream(
    id: string,
    options?: OpenEventStreamOptions,
  ): Promise<AsyncIterable<ChatEvent>>;
}
