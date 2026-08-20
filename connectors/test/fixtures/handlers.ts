// Test-only MSW 2.x handlers for the `/v1/chat` transport. PATTERN copied (not
// imported — connectors/ is outside the js/ pnpm workspace) from
// js/packages/core/tests/fixtures/handlers.ts: same setupServer + ReadableStream
// SSE shape.
//
// Every SSE frame is emitted as the LITERAL bytes the Phoenix controller emits
// (api/lib/barkpark_web/controllers/chat_controller.ex sse_*_frame/1), so a
// parser regression here is a real wire regression:
//   message    "id: <seq>\nevent: message\ndata: <json>\n\n"   <- ONLY frame with id:
//   chat       "event: chat\ndata: <verbatim stream-json>\n\n"
//   permission "event: permission\ndata: <json>\n\n"
//   exit       "event: exit\ndata: {\"status\":…,\"reason\":…}\n\n"
//   keepalive  ": keepalive\n\n"

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { http, HttpResponse } from "msw";

export const TEST_BASE = "http://test.barkpark.local";

/** A workspace-bound `chat`-permission ApiToken — the happy path. */
export const TOKEN_WS_BOUND = "bp_chat_ws_bound_token";
/** A `chat` token with NO workspace_id — RequireChatAccess 403s it (never retried). */
export const TOKEN_NO_WORKSPACE = "bp_chat_no_workspace_token";

export const SESSION_ID = "0f9d8c7b-6a5e-4d3c-2b1a-0f9e8d7c6b5a";

const HERE = dirname(fileURLToPath(import.meta.url));

/**
 * REAL recorded claude stream-json lines, copied byte-for-byte from
 * api/test/fixtures/claude_chat/*.ndjson (md5-identical). These are driven
 * through the wire as `event: chat` payloads VERBATIM — no synthesis.
 */
export function fixtureStreamJsonLines(
  file = "foreground_task.ndjson",
  limit?: number,
): string[] {
  const raw = readFileSync(join(HERE, "claude_chat", file), "utf8");
  const lines = raw.split("\n").filter((l) => l.trim() !== "");
  return limit === undefined ? lines : lines.slice(0, limit);
}

// ── byte-exact frame builders (mirror chat_controller.ex serializers) ─────────

export const messageFrame = (seq: number, data: unknown): string =>
  `id: ${seq}\nevent: message\ndata: ${JSON.stringify(data)}\n\n`;

/** The stream-json line is passed through VERBATIM — never re-encoded. */
export const chatFrame = (streamJsonLine: string): string =>
  `event: chat\ndata: ${streamJsonLine}\n\n`;

export const permissionFrame = (ask: unknown): string =>
  `event: permission\ndata: ${JSON.stringify(ask)}\n\n`;

export const exitFrame = (status: number | null, reason: string): string =>
  `event: exit\ndata: ${JSON.stringify({ status, reason })}\n\n`;

export const keepaliveFrame = (): string => ": keepalive\n\n";

// ── session JSON (the controller's full_session_json/2 projection) ───────────

export interface MockMessage {
  seq: number;
  role: string;
  source_markdown: string | null;
}

export const MOCK_MESSAGES: MockMessage[] = [
  { seq: 1, role: "user", source_markdown: "count the files" },
  { seq: 2, role: "assistant", source_markdown: "The directory contains 9 files." },
];

export function fullSessionJson(overrides: Record<string, unknown> = {}) {
  return {
    id: SESSION_ID,
    title: null,
    title_source: null,
    status: "idle",
    mode: "plan",
    model: null,
    model_choice: null,
    effort_choice: null,
    draft: null,
    rail_snapshot: {},
    summary: null,
    // Server-minted (D22) — a client never sends cwd.
    cwd: "/opt/barkpark",
    message_count: MOCK_MESSAGES.length,
    pending_approvals: 0,
    messages: MOCK_MESSAGES,
    ...overrides,
  };
}

/** The canonical error envelope: {error:{code,message,request_id}}. */
export function errorResponse(status: number, code: string, message: string) {
  const requestId = `req_${Math.random().toString(36).slice(2, 8)}`;
  return HttpResponse.json(
    { error: { code, message, request_id: requestId } },
    { status, headers: { "x-request-id": requestId } },
  );
}

/**
 * Auth gate mirroring RequireToken + RequireChatAccess: no bearer => 401; a
 * chat token with no workspace binding => 403 `forbidden` (the exact envelope
 * from Content.Errors.build({:error, :forbidden})).
 */
function authError(request: Request) {
  const auth = request.headers.get("authorization");
  if (!auth || !/^Bearer\s+/.test(auth)) {
    return errorResponse(401, "unauthorized", "missing bearer token");
  }
  const token = auth.replace(/^Bearer\s+/, "");
  if (token === TOKEN_NO_WORKSPACE) {
    return errorResponse(403, "forbidden", "token lacks required permission");
  }
  return null;
}

/** Bodies the tests inspect (asserting we never send id/cwd/workspace). */
export const recorded: {
  createBodies: unknown[];
  messageBodies: unknown[];
  headers: Headers[];
} = {
  createBodies: [],
  messageBodies: [],
  headers: [],
};

export function resetRecorded() {
  recorded.createBodies = [];
  recorded.messageBodies = [];
  recorded.headers = [];
}

/** The default SSE script: replay -> real chat lines -> permission -> keepalive -> exit. */
function defaultSseBody(lastEventId: number | null): string[] {
  const since = lastEventId ?? 0;
  const chunks: string[] = [];

  // Replay persisted rows with seq > Last-Event-ID as `event: message` (D5).
  for (const m of MOCK_MESSAGES) {
    if (m.seq > since) chunks.push(messageFrame(m.seq, m));
  }

  // Live deltas: REAL stream-json lines, verbatim, as `event: chat` (no id).
  for (const line of fixtureStreamJsonLines("foreground_task.ndjson", 3)) {
    chunks.push(chatFrame(line));
  }

  chunks.push(
    permissionFrame({ request_id: "toolu_01D6qn3yUCXRUktVqBGAzE8o", tool: "Bash" }),
  );
  chunks.push(keepaliveFrame()); // must be tolerated, never yielded
  chunks.push(exitFrame(0, "clean"));
  return chunks;
}

/** Wrap a list of frame strings in an SSE ReadableStream response. */
export function sseResponse(chunks: string[]): Response {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      const enc = new TextEncoder();
      for (const c of chunks) controller.enqueue(enc.encode(c));
      controller.close();
    },
  });
  return new HttpResponse(stream, {
    status: 200,
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "keep-alive",
    },
  });
}

export const defaultHandlers = [
  // POST /v1/chat/sessions -> 201 full session (server mints id + cwd)
  http.post(`${TEST_BASE}/v1/chat/sessions`, async ({ request }) => {
    const denied = authError(request);
    if (denied) return denied;
    const body = await request.json().catch(() => null);
    recorded.createBodies.push(body);
    recorded.headers.push(request.headers);

    // The controller rejects ANY key outside {mode,model,effort} with a 400
    // BEFORE any store call — id/cwd/workspace included (D22).
    const keys = Object.keys((body ?? {}) as Record<string, unknown>);
    const unknown = keys.filter((k) => !["mode", "model", "effort"].includes(k));
    if (unknown.length > 0) {
      return errorResponse(
        400,
        "invalid_request",
        `unrecognized keys: ${unknown.sort().join(", ")}`,
      );
    }

    const b = (body ?? {}) as { mode?: string; model?: string; effort?: string };
    return HttpResponse.json(
      fullSessionJson({
        mode: b.mode ?? "plan",
        model_choice: b.model ?? null,
        effort_choice: b.effort ?? null,
        message_count: 0,
        messages: [],
      }),
      { status: 201 },
    );
  }),

  // GET /v1/chat/sessions/:id[?since=] -> 200
  http.get(`${TEST_BASE}/v1/chat/sessions/:id`, ({ request, params }) => {
    const denied = authError(request);
    if (denied) return denied;
    const url = new URL(request.url);
    const since = url.searchParams.get("since");
    const messages =
      since === null
        ? MOCK_MESSAGES
        : MOCK_MESSAGES.filter((m) => m.seq > Number(since));
    return HttpResponse.json(
      fullSessionJson({
        id: String(params["id"]),
        messages,
        message_count: messages.length,
      }),
      { status: 200 },
    );
  }),

  // POST /v1/chat/sessions/:id/messages -> 202 {accepted:true}
  http.post(`${TEST_BASE}/v1/chat/sessions/:id/messages`, async ({ request }) => {
    const denied = authError(request);
    if (denied) return denied;
    const body = (await request.json().catch(() => null)) as {
      content?: unknown;
    } | null;
    recorded.messageBodies.push(body);
    if (typeof body?.content !== "string") {
      return errorResponse(400, "invalid_request", "content must be a string");
    }
    return HttpResponse.json({ accepted: true }, { status: 202 });
  }),

  // GET /v1/chat/sessions/:id/events -> SSE
  http.get(`${TEST_BASE}/v1/chat/sessions/:id/events`, ({ request }) => {
    const denied = authError(request);
    if (denied) return denied;
    recorded.headers.push(request.headers);
    const raw = request.headers.get("last-event-id");
    const lastEventId = raw === null ? null : Number.parseInt(raw, 10);
    return sseResponse(
      defaultSseBody(Number.isNaN(lastEventId as number) ? null : lastEventId),
    );
  }),
];
