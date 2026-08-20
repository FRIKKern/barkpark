// The `/v1/chat` HTTP client — the bridge's typed door onto Barkpark's chat
// engine. It holds NO per-conversation state; it just marshals create / read /
// send over the transport (charter D26/D33). SSE reads live in `sse.ts`.
//
// Contract transcribed from api/lib/barkpark_web/controllers/chat_controller.ex:
//   POST   /v1/chat/sessions            {provider?,execution_target?,execution_host_id?,mode?,model?,effort?} -> 201 full session
//   GET    /v1/chat/sessions/:id        [?since=<seq>]         -> 200 full session
//   POST   /v1/chat/sessions/:id/messages {content}            -> 202 {accepted:true}
// Auth: Bearer = a workspace-bound `chat`-permission ApiToken. A `chat` token
// with NO workspace binding is 403 `forbidden` (require_chat_access.ex) — never
// retried, surfaced verbatim.

import {
  ChatClientError,
  type ChatClient,
  type ChatClientConfig,
  type ChatEvent,
  type ChatSession,
  type CreateSessionInput,
  type OpenEventStreamOptions,
  type PostMessageResult,
} from "./types.js";
import { openEventStream } from "./sse.js";

/**
 * Codes that are safe to retry on ANY method. Keyed off the canonical
 * `error.code`, NOT the raw status (charter). Each is a 503 that arrives
 * as a REAL HTTP response, which proves the server refused the request before
 * doing any work — so replaying it cannot duplicate a side effect. The D26
 * reason split retired `chat_unavailable` in favor of `runtime_capacity` /
 * `runtime_unavailable` (transient) and `chat_create_failed`; `chat_unsupported`
 * (422) is deliberately absent — it is permanent, and retrying it forever is
 * the exact failure the split exists to prevent.
 */
const RETRYABLE_CODES: ReadonlySet<string> = new Set([
  "runtime_capacity",
  "runtime_unavailable",
  "chat_create_failed",
]);

/**
 * `network_error` is different: no response came back, so we CANNOT know whether
 * the server processed the request. Replaying a POST could mint a second session
 * or double-send a chat turn (there is no idempotency key on
 * /v1/chat/sessions/:id/messages). So a transport failure is only retried on
 * IDEMPOTENT methods; a POST surfaces it and lets the caller decide.
 */
const IDEMPOTENT_METHODS: ReadonlySet<string> = new Set(["GET", "HEAD"]);

/** Status codes that must NEVER be retried regardless of code (auth is terminal). */
const NEVER_RETRY_STATUS: ReadonlySet<number> = new Set([401, 403]);

/** The single retry predicate — method-aware, code-keyed, auth-terminal. */
function isRetryable(err: ChatClientError, method: string): boolean {
  if (NEVER_RETRY_STATUS.has(err.status)) return false;
  if (err.code === "network_error")
    return IDEMPOTENT_METHODS.has(method.toUpperCase());
  return RETRYABLE_CODES.has(err.code);
}

interface ErrorEnvelope {
  error?: { code?: unknown; message?: unknown; request_id?: unknown };
}

const sleep = (ms: number): Promise<void> =>
  ms > 0 ? new Promise((resolve) => setTimeout(resolve, ms)) : Promise.resolve();

/** Create a stateless client bound to one workspace token. */
export function createChatClient(config: ChatClientConfig): ChatClient {
  const base = config.baseUrl.replace(/\/+$/, "");
  const maxRetries = config.maxRetries ?? 2;
  const backoffMs = config.retryBackoffMs ?? 50;

  // Resolve fetch LAZILY, per request — never captured at construction. A client
  // built before an interceptor (msw, OpenTelemetry, a proxy shim) patches
  // `globalThis.fetch` must still go through it; capturing the reference up front
  // silently pins the un-intercepted original.
  function resolveFetch(): typeof fetch {
    const impl = config.fetch ?? globalThis.fetch;
    if (typeof impl !== "function") {
      throw new TypeError(
        "createChatClient: no fetch available (pass config.fetch)",
      );
    }
    return impl;
  }

  function authHeaders(extra?: Record<string, string>): Record<string, string> {
    return { authorization: `Bearer ${config.token}`, ...extra };
  }

  /** One HTTP round-trip; throws a typed ChatClientError on !ok or transport failure. */
  async function once(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<Response> {
    let res: Response;
    try {
      res = await resolveFetch()(`${base}${path}`, {
        method,
        headers: authHeaders(
          body === undefined ? undefined : { "content-type": "application/json" },
        ),
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
    } catch (cause) {
      // Transport-level failure (DNS, connection refused, aborted): a synthetic
      // retryable code so the retry loop can see it.
      const detail = cause instanceof Error ? `: ${cause.message}` : "";
      throw new ChatClientError({
        code: "network_error",
        status: 0,
        message: `chat request failed: ${method} ${path}${detail}`,
      });
    }

    if (res.ok) return res;

    // Parse the canonical error envelope: {error:{code,message,request_id}}.
    const envelope = (await res.json().catch(() => null)) as ErrorEnvelope | null;
    const err = envelope?.error;
    const code = typeof err?.code === "string" ? err.code : `http_${res.status}`;
    const message =
      typeof err?.message === "string"
        ? err.message
        : `chat request failed (${res.status})`;
    const requestId =
      typeof err?.request_id === "string" ? err.request_id : undefined;

    throw new ChatClientError({
      code,
      status: res.status,
      message: augmentMessage(code, res.status, message),
      ...(requestId === undefined ? {} : { requestId }),
    });
  }

  /** Retry wrapper: retries only retryable codes, and NEVER on 401/403. */
  async function request(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<Response> {
    let attempt = 0;
    for (;;) {
      try {
        return await once(method, path, body);
      } catch (err) {
        if (!(err instanceof ChatClientError)) throw err;
        if (!isRetryable(err, method) || attempt >= maxRetries) throw err;
        attempt += 1;
        await sleep(backoffMs * attempt);
      }
    }
  }

  return {
    /**
     * Mint a session. The server generates `id` + `cwd` (D22); we send only the
     * optional `{mode,model,effort}` — no id/cwd/workspace (workspace is derived
     * from the token). 201 → the full session JSON.
     */
    async createSession(input: CreateSessionInput = {}): Promise<ChatSession> {
      const payload: CreateSessionInput = {};
      if (input.provider !== undefined) payload.provider = input.provider;
      if (input.execution_target !== undefined)
        payload.execution_target = input.execution_target;
      if (input.execution_host_id !== undefined)
        payload.execution_host_id = input.execution_host_id;
      if (input.mode !== undefined) payload.mode = input.mode;
      if (input.model !== undefined) payload.model = input.model;
      if (input.effort !== undefined) payload.effort = input.effort;
      const res = await request("POST", "/v1/chat/sessions", payload);
      return (await res.json()) as ChatSession;
    },

    /**
     * Read a full session. `since` returns only rows with `seq > since` (the
     * turn-boundary tail refetch the bridge does after a stream settles).
     */
    async getSession(id: string, since?: number): Promise<ChatSession> {
      const query =
        since === undefined ? "" : `?since=${encodeURIComponent(String(since))}`;
      const res = await request(
        "GET",
        `/v1/chat/sessions/${encodeURIComponent(id)}${query}`,
      );
      return (await res.json()) as ChatSession;
    },

    /**
     * Send a user turn. 202 `{accepted:true}` — the server brings the runtime
     * up lazily; deltas arrive on the SSE stream, not in this response.
     */
    async postMessage(id: string, content: string): Promise<PostMessageResult> {
      const res = await request(
        "POST",
        `/v1/chat/sessions/${encodeURIComponent(id)}/messages`,
        { content },
      );
      return (await res.json()) as PostMessageResult;
    },

    /**
     * Open the SSE stream. NOT retried: a stream open is a long-lived
     * subscription, and silently reopening it under the caller would replay or
     * drop frames without the turn loop ever knowing. Resume is explicit, via
     * `lastEventId`.
     */
    openEventStream(
      id: string,
      options?: OpenEventStreamOptions,
    ): Promise<AsyncIterable<ChatEvent>> {
      return openEventStream(config, id, options);
    },
  };
}

/**
 * Make the workspace-less-token failure legible at the point it happens: the
 * transport returns a bare `forbidden`, but the operator's real problem is a
 * token minted without a workspace binding (require_chat_access.ex).
 */
function augmentMessage(code: string, status: number, message: string): string {
  if (status === 403 && code === "forbidden") {
    return `${message} — a chat token must be workspace-bound (mint it with a workspace_id and the \`chat\` permission, then seal it into that install's chat_token_ref).`;
  }
  return message;
}
