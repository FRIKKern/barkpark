import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { http, HttpResponse } from "msw";
import { setupServer } from "msw/node";

import { createChatClient } from "../src/chat-client/client.js";
import { createConnectorRegistry } from "../src/connector/registry.js";
import type {
  AuthorizedInstall,
  ConnectorInstall,
  InboundEvent,
} from "../src/connector/types.js";
import {
  createTelegramConnector,
  TELEGRAM_PROVIDER,
} from "../src/connectors/telegram.js";
import { dispatchInbound, type DispatchDeps } from "../src/core/dispatch.js";
import {
  createThreadSessionMap,
  type ThreadSessionStore,
} from "../src/state/thread-session-map.js";
import { createInMemoryInstallsLookup } from "../src/tenant/installs.js";
import { turnStream } from "./fixtures/chat-sse.js";

/**
 * THE HONESTY GATE OF THIS WAVE (charter D35).
 *
 * P2's bridge routed inbound events per tenant and then sent every one of them
 * to /v1/chat on ONE operator token: `chatClientFor(workspaceId)` ignored its
 * argument entirely. A `:global` token would have read every workspace's
 * Sessions. The routing was multi-tenant; the credential was not.
 *
 * These tests do not check that the seam EXISTS. They check what actually goes
 * out on the wire: two installs, two workspaces, two tokens, driven through the
 * REAL dispatch path with the REAL ChatClient and the REAL turn loop, with msw
 * recording the Authorization header of every single HTTP request /v1/chat sees.
 *
 * PROTECTIVE (distrust vacuous green): reverting dispatch to the P2 shape —
 * a single-token closure that ignores the install — turns "ws-beta's turn is
 * carried by token-B" and "token-A appears in ZERO of ws-beta's requests" RED.
 * Verified by mutation, not asserted by prose; see the wave paper for the RED
 * output.
 */

const TOKEN_A = "bp_chat_ws_alpha_TOKEN_A";
const TOKEN_B = "bp_chat_ws_beta_TOKEN_B";

const BOT_A = "111111111";
const BOT_B = "222222222";

const API_URL = "http://cross-tenant.chat.test";

const installAlpha: ConnectorInstall = {
  provider: TELEGRAM_PROVIDER,
  installKey: BOT_A,
  workspaceId: "ws-alpha",
  credentialRef: `${BOT_A}:AA-alpha-bot`,
  chatToken: TOKEN_A,
};

const installBeta: ConnectorInstall = {
  provider: TELEGRAM_PROVIDER,
  installKey: BOT_B,
  workspaceId: "ws-beta",
  credentialRef: `${BOT_B}:AA-beta-bot`,
  chatToken: TOKEN_B,
};

/** An install that exists and routes, but has no Barkpark chat token yet. */
const installNoToken: ConnectorInstall = {
  provider: TELEGRAM_PROVIDER,
  installKey: "333333333",
  workspaceId: "ws-gamma",
  credentialRef: "333333333:AA-gamma-bot",
  chatToken: null,
};

/* ── the recording /v1/chat ────────────────────────────────────────────────── */

interface Seen {
  path: string;
  authorization: string | null;
}

const seen: Seen[] = [];
let sessionCounter = 0;

/** Streams parked until the turn is sent — same shape as the real server. */
let waiters: Array<() => void> = [];

const bearer = (request: Request): string | null =>
  request.headers.get("authorization");

const server = setupServer(
  http.post(`${API_URL}/v1/chat/sessions`, ({ request }) => {
    seen.push({ path: "create_session", authorization: bearer(request) });
    return HttpResponse.json(
      { id: `session-${++sessionCounter}`, title: null },
      { status: 201 },
    );
  }),

  http.post(`${API_URL}/v1/chat/sessions/:id/messages`, ({ request }) => {
    seen.push({ path: "messages", authorization: bearer(request) });
    for (const wake of waiters.splice(0)) wake();
    return HttpResponse.json({ accepted: true }, { status: 202 });
  }),

  http.get(`${API_URL}/v1/chat/sessions/:id/events`, ({ request }) => {
    seen.push({ path: "events", authorization: bearer(request) });

    const turnSent = new Promise<void>((resolve) => waiters.push(resolve));
    const stream = new ReadableStream<Uint8Array>({
      async start(controller) {
        const encode = (s: string) => new TextEncoder().encode(s);
        await turnSent;
        for (const frame of turnStream("ok")) controller.enqueue(encode(frame));
        controller.close();
      },
    });

    return new HttpResponse(stream, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    });
  }),
);

beforeAll(() => server.listen({ onUnhandledRequest: "error" }));
afterEach(() => {
  server.resetHandlers();
  seen.length = 0;
  sessionCounter = 0;
  for (const wake of waiters.splice(0)) wake();
  waiters = [];
});
afterAll(() => server.close());

/* ── the real dispatch path, with both tenants in ONE installs table ───────── */

function memoryStore(): ThreadSessionStore {
  const rows = new Map<string, string>();
  const key = (w: string, t: string) => JSON.stringify([w, t]);
  return {
    async get(workspaceId, threadId) {
      return rows.get(key(workspaceId, threadId)) ?? null;
    },
    async putIfAbsent(workspaceId, threadId, sessionUuid) {
      const k = key(workspaceId, threadId);
      const existing = rows.get(k);
      if (existing) return existing;
      rows.set(k, sessionUuid);
      return sessionUuid;
    },
  };
}

/**
 * One bridge, both tenants — exactly as production runs it. The ONLY thing that
 * distinguishes the two turns below is which install row the event routed to.
 */
function harness(installs: ConnectorInstall[] = [installAlpha, installBeta]) {
  const registry = createConnectorRegistry();
  registry.register(createTelegramConnector({ mode: "polling" }));

  const reply = vi.fn(async (_text: string) => {});
  const minted: AuthorizedInstall[] = [];

  const deps: DispatchDeps = {
    registry,
    installs: { installs: createInMemoryInstallsLookup(installs) },
    map: createThreadSessionMap(memoryStore()),
    // The REAL composition root's wiring (src/index.ts): the token comes from
    // the install, and from nowhere else. No process-wide token exists to leak.
    chatClientForInstall: (install) => {
      minted.push(install);
      return createChatClient({ baseUrl: API_URL, token: install.chatToken });
    },
    reply,
    timeoutMs: 5_000,
  };

  return { deps, reply, minted };
}

const inbound = (installKey: string, text: string): InboundEvent => ({
  provider: TELEGRAM_PROVIDER,
  threadId: "telegram:555", // deliberately THE SAME thread id for both tenants
  text,
  installKey,
});

const authsFor = (token: string) =>
  seen.filter((s) => s.authorization === `Bearer ${token}`);

describe("cross-tenant token isolation — what actually goes on the wire (D35)", () => {
  it("carries ws-beta's turn on token-B, and token-A on ZERO of its requests", async () => {
    const { deps } = harness();

    await dispatchInbound(inbound(BOT_B, "beta speaking"), deps);

    // Every request this turn made — session create, SSE subscribe, message send.
    expect(seen.map((s) => s.path)).toEqual([
      "create_session",
      "events",
      "messages",
    ]);

    // …and EVERY one of them carried ws-beta's own token.
    for (const request of seen) {
      expect(request.authorization).toBe(`Bearer ${TOKEN_B}`);
    }

    // The assertion that P2 fails: ws-alpha's token appears nowhere at all.
    expect(authsFor(TOKEN_A)).toHaveLength(0);
    expect(seen.some((s) => s.authorization?.includes(TOKEN_A))).toBe(false);
  });

  it("gives each tenant its OWN token across interleaved turns on the same thread id", async () => {
    const { deps } = harness();

    await dispatchInbound(inbound(BOT_A, "alpha 1"), deps);
    await dispatchInbound(inbound(BOT_B, "beta 1"), deps);
    await dispatchInbound(inbound(BOT_A, "alpha 2"), deps);

    // Alpha: 3 requests on turn 1 (create+events+messages) + 2 on turn 2 (the
    // Session is resumed, so no create). Beta: 3. Nothing crosses.
    expect(authsFor(TOKEN_A)).toHaveLength(5);
    expect(authsFor(TOKEN_B)).toHaveLength(3);
    expect(seen).toHaveLength(8);

    // Not one request went out on a token that was not its install's own.
    const foreign = seen.filter(
      (s) =>
        s.authorization !== `Bearer ${TOKEN_A}` &&
        s.authorization !== `Bearer ${TOKEN_B}`,
    );
    expect(foreign).toEqual([]);
  });

  it("mints the client from the install ROW that routed the event (same PK)", async () => {
    const { deps, minted } = harness();

    await dispatchInbound(inbound(BOT_B, "beta speaking"), deps);

    // The token is not derived from the workspace by some second lookup — it is
    // read off the very row (provider, install_key) the routing decision used.
    expect(minted).toHaveLength(1);
    expect(minted[0]?.installKey).toBe(BOT_B);
    expect(minted[0]?.workspaceId).toBe("ws-beta");
    expect(minted[0]?.chatToken).toBe(TOKEN_B);
  });

  it("keeps two workspaces on two Sessions even on an identical thread id", async () => {
    const { deps } = harness();

    const alpha = await dispatchInbound(inbound(BOT_A, "hi"), deps);
    const beta = await dispatchInbound(inbound(BOT_B, "hi"), deps);

    expect(alpha.workspaceId).toBe("ws-alpha");
    expect(beta.workspaceId).toBe("ws-beta");
    expect(beta.sessionUuid).not.toBe(alpha.sessionUuid);
  });
});

describe("no chat token => fail closed, with ZERO HTTP calls (D35)", () => {
  it("drops an install whose chat_token_ref is blank — no operator-token fallback", async () => {
    const { deps, reply, minted } = harness([installNoToken]);

    const outcome = await dispatchInbound(inbound("333333333", "hello"), deps);

    expect(outcome.status).toBe("dropped_no_chat_token");
    expect(outcome.workspaceId).toBe("ws-gamma");
    // THE assertion. Not "it used the wrong token" — it did not call at all.
    expect(seen).toEqual([]);
    expect(minted).toEqual([]);
    expect(reply).not.toHaveBeenCalled();
  });

  it("drops a tokenless install even when a TOKENED install of the same provider exists", async () => {
    // The tempting bug: fall back to "any chat token we happen to have". If the
    // bridge ever does that, ws-gamma's turn runs on ws-alpha's credential.
    const { deps } = harness([installAlpha, installNoToken]);

    const outcome = await dispatchInbound(inbound("333333333", "hello"), deps);

    expect(outcome.status).toBe("dropped_no_chat_token");
    expect(seen).toEqual([]);
    expect(authsFor(TOKEN_A)).toHaveLength(0);
  });

  it("still serves the tokened install in the same table (the drop is per-install)", async () => {
    const { deps } = harness([installAlpha, installNoToken]);

    const dropped = await dispatchInbound(inbound("333333333", "hello"), deps);
    const served = await dispatchInbound(inbound(BOT_A, "hello"), deps);

    expect(dropped.status).toBe("dropped_no_chat_token");
    expect(served.status).toBe("posted");
    for (const request of seen) {
      expect(request.authorization).toBe(`Bearer ${TOKEN_A}`);
    }
  });

  it("drops an unknown install before any HTTP call (no tenant, no token)", async () => {
    const { deps, reply } = harness();

    const outcome = await dispatchInbound(inbound("999999999", "hello"), deps);

    expect(outcome.status).toBe("dropped_no_tenant");
    expect(seen).toEqual([]);
    expect(reply).not.toHaveBeenCalled();
  });

  it("drops a connector that resolves a tenant WITHOUT consulting the installs lookup", async () => {
    // A connector cannot conjure a workspace out of thin air and expect the core
    // to find it a credential: there is no row to take one from, and "any token
    // for that workspace" is exactly the fallback this wave deleted.
    const registry = createConnectorRegistry();
    registry.register({
      id: "rogue",
      direction: "channel",
      auth: "token",
      tenantResolution: "credential-bound",
      adapterFactory: () => ({}) as never,
      resolveTenant: async () => "ws-alpha", // never touches ctx.installs
    });

    const reply = vi.fn(async (_text: string) => {});
    const deps: DispatchDeps = {
      registry,
      installs: {
        installs: createInMemoryInstallsLookup([installAlpha, installBeta]),
      },
      map: createThreadSessionMap(memoryStore()),
      chatClientForInstall: (install) =>
        createChatClient({ baseUrl: API_URL, token: install.chatToken }),
      reply,
      timeoutMs: 5_000,
    };

    const outcome = await dispatchInbound(
      { provider: "rogue", threadId: "t1", text: "hello", installKey: BOT_A },
      deps,
    );

    expect(outcome.status).toBe("dropped_no_install");
    expect(seen).toEqual([]);
    expect(authsFor(TOKEN_A)).toHaveLength(0);
  });
});
