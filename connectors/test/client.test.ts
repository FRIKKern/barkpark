import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { http, HttpResponse } from "msw";
import { createChatClient } from "../src/chat-client/client.js";
import { ChatClientError } from "../src/chat-client/types.js";
import { server } from "./fixtures/server.js";
import {
  SESSION_ID,
  TEST_BASE,
  TOKEN_NO_WORKSPACE,
  TOKEN_WS_BOUND,
  errorResponse,
  recorded,
  resetRecorded,
} from "./fixtures/handlers.js";

// retryBackoffMs: 0 keeps the retry tests instant.
const client = createChatClient({
  baseUrl: TEST_BASE,
  token: TOKEN_WS_BOUND,
  retryBackoffMs: 0,
});

beforeAll(() => server.listen({ onUnhandledRequest: "error" }));
afterEach(() => {
  server.resetHandlers();
  resetRecorded();
});
afterAll(() => server.close());

describe("createSession", () => {
  it("POSTs to /v1/chat/sessions and returns the 201 full session", async () => {
    const session = await client.createSession();
    expect(session.id).toBe(SESSION_ID);
    // The SERVER minted id + cwd (D22).
    expect(session.cwd).toBe("/opt/barkpark");
    expect(session.mode).toBe("plan");
  });

  it("sends ONLY {mode,model,effort} — never id, cwd or workspace", async () => {
    await client.createSession({
      mode: "acceptEdits",
      model: "opus",
      effort: "high",
    });
    expect(recorded.createBodies).toHaveLength(1);
    const body = recorded.createBodies[0] as Record<string, unknown>;
    expect(Object.keys(body).sort()).toEqual(["effort", "mode", "model"]);
    expect(body).not.toHaveProperty("id");
    expect(body).not.toHaveProperty("cwd");
    expect(body).not.toHaveProperty("workspace");
    expect(body).not.toHaveProperty("workspace_id");
  });

  it("omits absent options entirely (an empty body, not a body full of nulls)", async () => {
    await client.createSession();
    expect(recorded.createBodies[0]).toEqual({});
  });

  it("serializes provider and execution identity without launcher controls", async () => {
    server.use(
      http.post(`${TEST_BASE}/v1/chat/sessions`, async ({ request }) => {
        recorded.createBodies.push(await request.json());
        return HttpResponse.json({ id: SESSION_ID }, { status: 201 });
      }),
    );

    await client.createSession({
      provider: "codex",
      execution_target: "registered_host",
      execution_host_id: "0f9d8c7b-6a5e-4d3c-2b1a-0f9e8d7c6b5a",
      mode: "read-only",
    });

    expect(recorded.createBodies[0]).toEqual({
      provider: "codex",
      execution_target: "registered_host",
      execution_host_id: "0f9d8c7b-6a5e-4d3c-2b1a-0f9e8d7c6b5a",
      mode: "read-only",
    });
    expect(recorded.createBodies[0]).not.toHaveProperty("cwd");
    expect(recorded.createBodies[0]).not.toHaveProperty("provider_session_id");
  });

  it("carries the Bearer token", async () => {
    await client.createSession();
    expect(recorded.headers[0]?.get("authorization")).toBe(
      `Bearer ${TOKEN_WS_BOUND}`,
    );
  });
});

describe("getSession", () => {
  it("reads the full session with its message rows", async () => {
    const session = await client.getSession(SESSION_ID);
    expect(session.id).toBe(SESSION_ID);
    expect(session.messages?.map((m) => m.seq)).toEqual([1, 2]);
  });

  it("passes ?since= for the turn-boundary tail refetch", async () => {
    const session = await client.getSession(SESSION_ID, 1);
    expect(session.messages?.map((m) => m.seq)).toEqual([2]);
  });
});

describe("postMessage", () => {
  it("POSTs {content} and resolves the 202 {accepted:true}", async () => {
    const result = await client.postMessage(SESSION_ID, "count the files");
    expect(result).toEqual({ accepted: true });
    expect(recorded.messageBodies[0]).toEqual({ content: "count the files" });
  });
});

describe("auth failures", () => {
  it("403s a chat token with NO workspace binding, and says WHY", async () => {
    const bad = createChatClient({
      baseUrl: TEST_BASE,
      token: TOKEN_NO_WORKSPACE,
      retryBackoffMs: 0,
    });
    const err = await bad.createSession().catch((e: unknown) => e);

    expect(err).toBeInstanceOf(ChatClientError);
    expect((err as ChatClientError).status).toBe(403);
    expect((err as ChatClientError).code).toBe("forbidden");
    // The operator's real problem is legible from the message alone.
    expect((err as ChatClientError).message).toMatch(/workspace-bound/i);
    // …and it names WHERE the token lives now: the install's sealed column, not
    // a process-wide BARKPARK_CHAT_TOKEN (retired, D35).
    expect((err as ChatClientError).message).toMatch(/chat_token_ref/);
  });

  it("never retries a 403 (auth is terminal)", async () => {
    let hits = 0;
    server.use(
      http.post(`${TEST_BASE}/v1/chat/sessions`, () => {
        hits += 1;
        return errorResponse(403, "forbidden", "token lacks required permission");
      }),
    );
    await expect(client.createSession()).rejects.toBeInstanceOf(ChatClientError);
    expect(hits).toBe(1);
  });

  it("never retries a 401", async () => {
    let hits = 0;
    server.use(
      http.post(`${TEST_BASE}/v1/chat/sessions`, () => {
        hits += 1;
        return errorResponse(401, "unauthorized", "missing bearer token");
      }),
    );
    await expect(client.createSession()).rejects.toBeInstanceOf(ChatClientError);
    expect(hits).toBe(1);
  });

  it("surfaces the request_id from the error envelope", async () => {
    server.use(
      http.post(`${TEST_BASE}/v1/chat/sessions`, () =>
        HttpResponse.json(
          {
            error: { code: "forbidden", message: "nope", request_id: "req_abc123" },
          },
          { status: 403 },
        ),
      ),
    );
    const err = (await client
      .createSession()
      .catch((e: unknown) => e)) as ChatClientError;
    expect(err.requestId).toBe("req_abc123");
  });
});

describe("retry — keyed off error.code, not the raw status", () => {
  it("retries a transient runtime_capacity and then succeeds", async () => {
    let hits = 0;
    server.use(
      http.post(`${TEST_BASE}/v1/chat/sessions/:id/messages`, () => {
        hits += 1;
        if (hits < 3) {
          return errorResponse(
            503,
            "runtime_capacity",
            "chat runtime is at capacity",
          );
        }
        return HttpResponse.json({ accepted: true }, { status: 202 });
      }),
    );

    await expect(client.postMessage(SESSION_ID, "hi")).resolves.toEqual({
      accepted: true,
    });
    expect(hits).toBe(3); // 1 try + 2 retries
  });

  it("gives up after maxRetries and throws the typed error", async () => {
    let hits = 0;
    server.use(
      http.post(`${TEST_BASE}/v1/chat/sessions/:id/messages`, () => {
        hits += 1;
        return errorResponse(
          503,
          "runtime_unavailable",
          "chat runtime is unavailable",
        );
      }),
    );

    const err = (await client
      .postMessage(SESSION_ID, "hi")
      .catch((e: unknown) => e)) as ChatClientError;
    expect(err.code).toBe("runtime_unavailable");
    expect(hits).toBe(3); // maxRetries default 2
  });

  it("does NOT retry a 422 chat_unsupported (a permanent refusal is terminal)", async () => {
    // D26: chat_unsupported means this server/provider will never accept the
    // request — retrying it forever is the exact failure the reason split
    // exists to prevent.
    let hits = 0;
    server.use(
      http.post(`${TEST_BASE}/v1/chat/sessions/:id/messages`, () => {
        hits += 1;
        return errorResponse(
          422,
          "chat_unsupported",
          "chat is not supported on this instance",
        );
      }),
    );

    const err = (await client
      .postMessage(SESSION_ID, "hi")
      .catch((e: unknown) => e)) as ChatClientError;
    expect(err.code).toBe("chat_unsupported");
    expect(hits).toBe(1); // no retry
  });

  it("does NOT retry a 400 invalid_request (a client bug is terminal)", async () => {
    let hits = 0;
    server.use(
      http.post(`${TEST_BASE}/v1/chat/sessions/:id/messages`, () => {
        hits += 1;
        return errorResponse(400, "invalid_request", "content must be a string");
      }),
    );

    const err = (await client
      .postMessage(SESSION_ID, "hi")
      .catch((e: unknown) => e)) as ChatClientError;
    expect(err.code).toBe("invalid_request");
    expect(hits).toBe(1);
  });

  it("does NOT retry an unknown 5xx code (only known-transient codes retry)", async () => {
    let hits = 0;
    server.use(
      http.post(`${TEST_BASE}/v1/chat/sessions/:id/messages`, () => {
        hits += 1;
        return errorResponse(500, "internal_error", "boom");
      }),
    );

    await expect(client.postMessage(SESSION_ID, "hi")).rejects.toBeInstanceOf(
      ChatClientError,
    );
    expect(hits).toBe(1);
  });

  it("does NOT replay a POST after a transport failure (it may have already landed)", async () => {
    // No response came back, so we cannot know whether the server minted the
    // session. Replaying could mint a SECOND one — there is no idempotency key
    // on the chat writes. Surface it instead and let the caller decide.
    let hits = 0;
    server.use(
      http.post(`${TEST_BASE}/v1/chat/sessions`, () => {
        hits += 1;
        return HttpResponse.error();
      }),
    );

    const err = (await client
      .createSession()
      .catch((e: unknown) => e)) as ChatClientError;
    expect(err).toBeInstanceOf(ChatClientError);
    expect(err.code).toBe("network_error");
    expect(err.status).toBe(0);
    expect(hits).toBe(1); // tried exactly once — never replayed
  });

  it("does NOT replay a postMessage after a transport failure (no double-send)", async () => {
    let hits = 0;
    server.use(
      http.post(`${TEST_BASE}/v1/chat/sessions/:id/messages`, () => {
        hits += 1;
        return HttpResponse.error();
      }),
    );

    await expect(client.postMessage(SESSION_ID, "hi")).rejects.toBeInstanceOf(
      ChatClientError,
    );
    expect(hits).toBe(1); // a chat turn is never sent twice
  });

  it("DOES retry a transport failure on an idempotent GET", async () => {
    let hits = 0;
    server.use(
      http.get(`${TEST_BASE}/v1/chat/sessions/:id`, () => {
        hits += 1;
        return HttpResponse.error();
      }),
    );

    const err = (await client
      .getSession(SESSION_ID)
      .catch((e: unknown) => e)) as ChatClientError;
    expect(err.code).toBe("network_error");
    expect(hits).toBe(3); // 1 try + 2 retries — a re-read is always safe
  });

  it("still retries a chat_create_failed on a POST (the server proved it refused the work)", async () => {
    // A real 503 response means the request was rejected before any side effect,
    // so replaying it cannot duplicate a turn.
    let hits = 0;
    server.use(
      http.post(`${TEST_BASE}/v1/chat/sessions`, () => {
        hits += 1;
        if (hits < 2) return errorResponse(503, "chat_create_failed", "runtime down");
        return HttpResponse.json(
          { id: SESSION_ID, cwd: "/opt/barkpark" },
          { status: 201 },
        );
      }),
    );

    await expect(client.createSession()).resolves.toMatchObject({ id: SESSION_ID });
    expect(hits).toBe(2);
  });
});
