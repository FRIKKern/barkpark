import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { createChatClient } from "../src/chat-client/client.js";
import { createConnectorRegistry } from "../src/connector/registry.js";
import type { ConnectorInstall, InboundEvent } from "../src/connector/types.js";
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
import { API_URL, createMockChat } from "./fixtures/chat-server.js";

/**
 * The CORE LOOP, end to end, against a faithful /v1/chat mock:
 *
 *   inbound -> resolveTenant -> resolveOrMint -> runTurn -> thread.post (ONCE)
 *
 * The real turn loop and the real ChatClient run here — only Postgres (faked at
 * the store seam) and the network (msw) are stood in for. The LIVE Telegram
 * round-trip is a human gate (docs/telegram-smoke.md), never a unit test.
 */

const BOT_ID = "123456789";
const BOT_TOKEN = `${BOT_ID}:AAHfake`;
const THREAD = "telegram:555";

const install: ConnectorInstall = {
  provider: TELEGRAM_PROVIDER,
  installKey: BOT_ID,
  workspaceId: "ws-alpha",
  credentialRef: BOT_TOKEN,
  // THIS install's own workspace-bound chat token (D35). The mock /v1/chat only
  // accepts this bearer, so a turn that went out on some other install's token
  // would 401 rather than pass — see cross-tenant-token.test.ts for the full proof.
  chatToken: "test-token",
};

const mock = createMockChat();

beforeAll(() => mock.server.listen({ onUnhandledRequest: "error" }));
afterEach(() => {
  mock.server.resetHandlers();
  mock.reset();
});
afterAll(() => mock.server.close());

/** An in-memory thread->session store: the map's logic, none of Postgres. */
function memoryStore(): ThreadSessionStore & { rows: Map<string, string> } {
  const rows = new Map<string, string>();
  // JSON, not a raw separator byte: no delimiter to collide on, and the file
  // stays TEXT (a NUL here makes git/grep treat the whole test as binary).
  const key = (w: string, t: string) => JSON.stringify([w, t]);
  return {
    rows,
    async get(workspaceId, threadId) {
      return rows.get(key(workspaceId, threadId)) ?? null;
    },
    async putIfAbsent(workspaceId, threadId, sessionUuid) {
      const k = key(workspaceId, threadId);
      const existing = rows.get(k);
      if (existing) return existing; // the racing winner keeps the thread
      rows.set(k, sessionUuid);
      return sessionUuid;
    },
  };
}

function harness(seedInstall = true) {
  const registry = createConnectorRegistry();
  registry.register(createTelegramConnector({ mode: "polling" }));

  const installs = createInMemoryInstallsLookup(seedInstall ? [install] : []);

  const store = memoryStore();
  const reply = vi.fn(async (_text: string) => {});

  const deps: DispatchDeps = {
    registry,
    installs: { installs },
    map: createThreadSessionMap(store),
    // The production wiring: the token is read off the install the event routed
    // to, never from a process-wide config value (D35).
    chatClientForInstall: (routed) =>
      createChatClient({ baseUrl: API_URL, token: routed.chatToken }),
    reply,
    timeoutMs: 5_000,
  };

  return { deps, reply, store, registry };
}

const inbound = (overrides: Partial<InboundEvent> = {}): InboundEvent => ({
  provider: TELEGRAM_PROVIDER,
  threadId: THREAD,
  text: "hi barkpark",
  installKey: BOT_ID,
  ...overrides,
});

describe("core dispatch — the loop that must not change when P3 adds channels", () => {
  it("drives inbound -> tenant -> session -> turn -> post exactly ONCE", async () => {
    const { deps, reply } = harness();
    mock.setReply("hello from barkpark");

    const outcome = await dispatchInbound(inbound(), deps);

    expect(outcome.status).toBe("posted");
    expect(outcome.workspaceId).toBe("ws-alpha");
    expect(outcome.sessionUuid).toBe("session-1");
    expect(outcome.minted).toBe(true);

    // Post-once-per-turn (D12/D26): exactly one message reaches the channel,
    // no matter how many SSE frames the turn produced.
    expect(reply).toHaveBeenCalledTimes(1);
    expect(reply).toHaveBeenCalledWith("hello from barkpark");

    // The user's text reached /v1/chat verbatim.
    expect(mock.sentMessages).toEqual([
      { sessionId: "session-1", content: "hi barkpark" },
    ]);
  });

  it("subscribes to the SSE stream BEFORE sending the turn", async () => {
    const { deps } = harness();

    await dispatchInbound(inbound(), deps);

    // Sending first would race the opening frames of every turn onto the floor.
    expect(mock.calls).toEqual(["create_session", "events", "messages"]);
    expect(mock.calls.indexOf("events")).toBeLessThan(
      mock.calls.indexOf("messages"),
    );
  });

  it("never leaks thinking or tool_use blocks into the channel", async () => {
    const { deps, reply } = harness();
    mock.setReply("the visible answer");

    await dispatchInbound(inbound(), deps);

    const posted = reply.mock.calls[0]?.[0] as string;
    expect(posted).toBe("the visible answer");
    // The fixture's turn carries a `thinking` block and a tool_use reading
    // /etc/passwd. Neither may ever reach a Telegram chat.
    expect(posted).not.toContain("I should greet them");
    expect(posted).not.toContain("/etc/passwd");
  });

  it("mints a Session on first contact and RESUMES it thereafter", async () => {
    const { deps, reply, store } = harness();

    const first = await dispatchInbound(inbound({ text: "first" }), deps);
    const second = await dispatchInbound(inbound({ text: "second" }), deps);

    expect(first.minted).toBe(true);
    expect(second.minted).toBe(false);
    // Same thread => same Session. This is the cross-surface memory (D6).
    expect(second.sessionUuid).toBe(first.sessionUuid);

    // Exactly ONE session was ever created on /v1/chat.
    expect(mock.createdSessions).toEqual(["session-1"]);
    expect(mock.calls.filter((c) => c === "create_session")).toHaveLength(1);

    expect(store.rows.get(JSON.stringify(["ws-alpha", THREAD]))).toBe("session-1");
    expect(reply).toHaveBeenCalledTimes(2);
  });

  it("keeps different threads on different Sessions", async () => {
    const { deps } = harness();

    const a = await dispatchInbound(inbound({ threadId: "telegram:1" }), deps);
    const b = await dispatchInbound(inbound({ threadId: "telegram:2" }), deps);

    expect(a.sessionUuid).toBe("session-1");
    expect(b.sessionUuid).toBe("session-2");
    expect(a.sessionUuid).not.toBe(b.sessionUuid);
  });

  it("FAILS CLOSED on an unresolvable tenant — no session, no post", async () => {
    const { deps, reply } = harness(/* seedInstall */ false);

    const outcome = await dispatchInbound(inbound(), deps);

    expect(outcome.status).toBe("dropped_no_tenant");
    expect(outcome.sessionUuid).toBeUndefined();
    // The event must not touch /v1/chat at all — no session minted for a
    // tenant we could not identify.
    expect(mock.calls).toEqual([]);
    expect(reply).not.toHaveBeenCalled();
  });

  it("drops an event for a provider nobody registered", async () => {
    const { deps, reply } = harness();

    const outcome = await dispatchInbound(inbound({ provider: "slack" }), deps);

    // Slack is P3. The core loop does not know it exists — and says so.
    expect(outcome.status).toBe("dropped_unknown_connector");
    expect(mock.calls).toEqual([]);
    expect(reply).not.toHaveBeenCalled();
  });

  it("drops an empty inbound message before spending a Session on it", async () => {
    const { deps, reply } = harness();

    const outcome = await dispatchInbound(inbound({ text: "   " }), deps);

    expect(outcome.status).toBe("dropped_empty_input");
    expect(mock.calls).toEqual([]);
    expect(reply).not.toHaveBeenCalled();
  });

  it("posts nothing when a turn produces no text", async () => {
    const { deps, reply } = harness();
    mock.setReply("");

    const outcome = await dispatchInbound(inbound(), deps);

    // An empty bubble is worse than silence, and Telegram rejects "" outright.
    expect(outcome.status).toBe("empty_reply");
    expect(reply).not.toHaveBeenCalled();
  });

  it("isolates tenants: the same thread id under two workspaces is two Sessions", async () => {
    const { deps } = harness();

    // A second bot, owned by a DIFFERENT workspace, on the same chat id. Both
    // installs live in one lookup, exactly as they would in connector_installs.
    const other = createInMemoryInstallsLookup([
      install,
      {
        provider: TELEGRAM_PROVIDER,
        installKey: "987654321",
        workspaceId: "ws-beta",
        credentialRef: "987654321:AAOther",
        // Same bearer here only because this mock accepts exactly one; the proof
        // that two tenants travel on two DIFFERENT tokens lives in
        // cross-tenant-token.test.ts, which records the wire.
        chatToken: "test-token",
      },
    ]);

    const alpha = await dispatchInbound(inbound(), deps);
    const beta = await dispatchInbound(inbound({ installKey: "987654321" }), {
      ...deps,
      installs: { installs: other },
    });

    expect(alpha.workspaceId).toBe("ws-alpha");
    expect(beta.workspaceId).toBe("ws-beta");
    // Same provider thread id, different tenant => never the same Session.
    expect(beta.sessionUuid).not.toBe(alpha.sessionUuid);
  });
});
