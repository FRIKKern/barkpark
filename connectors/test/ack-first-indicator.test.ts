import { createMemoryState } from "@chat-adapter/state-memory";
import { createHmac } from "node:crypto";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { createChatClient } from "../src/chat-client/client.js";
import type { BridgeConfig } from "../src/config.js";
import { createConnectorRegistry } from "../src/connector/registry.js";
import type { ConnectorInstall } from "../src/connector/types.js";
import type { DispatchOutcome } from "../src/core/dispatch.js";
import {
  createWhatsappConnector,
  encodeWhatsappCredential,
  WHATSAPP_PROVIDER,
} from "../src/connectors/whatsapp.js";
import { mountInstall, type BridgeDeps } from "../src/index.js";
import {
  createThreadSessionMap,
  type ThreadSessionStore,
} from "../src/state/thread-session-map.js";
import { createInMemoryInstallsLookup } from "../src/tenant/installs.js";
import { API_URL, createMockChat } from "./fixtures/chat-server.js";

/**
 * ACK-FIRST GETS ITS FIRST USER-VISIBLE INDICATOR (charter D21/D170).
 *
 * D21 makes ack-latency <=10s a hard requirement, and W3-3 honestly shipped it as
 * a HOOK: `onAck` fires on the /v1/chat 202, but the bridge never posts an ack
 * message (that would be two posts per turn — D12/D26). The gap D170 closes: the
 * hook had NO guaranteed user-visible effect on any channel — `deps.onAck` is
 * never set by a production caller, so on a slow turn the user stares at silence.
 * The fix wires mountInstall's onAck wrapper to `adapter.startTyping(threadId)`,
 * fire-and-forget: a typing indicator is an adapter presence call, NEVER a
 * message post, so post-once-per-turn is untouched (turn-loop.test.ts pins that).
 *
 * WHY THIS HARNESS DRIVES THE REAL `mountInstall` EXPORT: the vacuous-green trap
 * (D170) is real — a test that spies dispatch.ts's `onAck` deps, or the turn
 * loop's hook, goes green WITHOUT index.ts changing at all, because those seams
 * already fire. The only honest proof is: mount a REAL connector through the real
 * `mountInstall`, deliver a REAL signed provider webhook, let the REAL runTurn
 * hit a faithful /v1/chat mock so the 202 fires the real onAck path, and assert
 * on `mounted.adapter.startTyping` — the exact object index.ts closes over.
 * (test/slack-connector.test.ts's inlined-handle block is a decoy for this
 * purpose: it copies the handler wiring and stubs runTurnImpl, so it cannot see
 * index.ts regress.)
 *
 * NO-ACK SURFACES, DOCUMENTED (acceptance criterion): tool-direction connectors
 * (github, linear) never reach this path AT ALL — they have no inbound channel,
 * `registry.channels()` never yields them, so no Chat is ever mounted for them
 * and no turn loop runs (charter D69/D71/D77). There is no ack surface to cover
 * there by construction, not by omission.
 *
 * The `.catch` on startTyping is LOAD-BEARING: the imessage adapter THROWS from
 * startTyping in local mode, and a typing indicator must never be able to fail a
 * turn. The second test pins that: startTyping rejects, the turn still posts.
 */

const DEAD_GRAPH = "http://127.0.0.1:1";

const PHONE = "111111111111111";
const APP_SECRET = "app-secret-alpha";
const WA_USER = "4799999999";
/** The SDK's whatsapp thread id: `whatsapp:{phoneNumberId}:{userWaId}`. */
const THREAD = `whatsapp:${PHONE}:${WA_USER}`;

const install: ConnectorInstall = {
  provider: WHATSAPP_PROVIDER,
  installKey: PHONE,
  workspaceId: "ws-alpha",
  credentialRef: encodeWhatsappCredential({
    accessToken: "system-user-token-alpha",
    appSecret: APP_SECRET,
    verifyToken: "verify-token-alpha",
  }),
  // The mock /v1/chat only accepts this bearer (see fixtures/chat-server.ts), so
  // the turn provably ran on THIS install's own token.
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

/** A Meta webhook body, exactly as the Cloud API posts it. */
function webhookBody(text: string): string {
  return JSON.stringify({
    object: "whatsapp_business_account",
    entry: [
      {
        id: "waba-id",
        changes: [
          {
            field: "messages",
            value: {
              messaging_product: "whatsapp",
              metadata: {
                display_phone_number: "4712345678",
                phone_number_id: PHONE,
              },
              contacts: [{ profile: { name: "Pelle" }, wa_id: WA_USER }],
              messages: [
                {
                  from: WA_USER,
                  id: "wamid.TEST",
                  timestamp: "1752451200",
                  type: "text",
                  text: { body: text },
                },
              ],
            },
          },
        ],
      },
    ],
  });
}

/** A POST signed with the install's own Meta App Secret — accepted, not stubbed. */
function signedRequest(body: string): Request {
  const signature =
    "sha256=" + createHmac("sha256", APP_SECRET).update(body).digest("hex");
  return new Request(
    `https://bridge.example/connectors/webhooks/whatsapp/${PHONE}`,
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-hub-signature-256": signature,
      },
      body,
    },
  );
}

/**
 * Mount ONE install through the REAL `mountInstall` — the production wiring,
 * with only the process edges stood in for: /v1/chat is the faithful msw mock
 * (so the real runTurn's 202 fires the real onAck), Postgres is the in-memory
 * store, and the Meta Graph base URL points at a dead local port.
 */
function mountRealInstall() {
  const connector = createWhatsappConnector({ apiUrl: DEAD_GRAPH });

  const registry = createConnectorRegistry();
  registry.register(connector);

  const config: BridgeConfig = {
    databaseUrl: "postgres://never-dialled.invalid/none",
    apiUrl: API_URL,
    credentialKey: "unused-by-mountInstall",
    previousCredentialKeys: [],
    userName: "barkpark",
    webhook: {
      enabled: false,
      host: "127.0.0.1",
      port: 0,
      pathPrefix: "/connectors",
      maxBodyBytes: 65_536,
    },
  };

  const outcomes: DispatchOutcome[] = [];

  const deps: BridgeDeps = {
    config,
    registry,
    installs: createInMemoryInstallsLookup([install]),
    map: createThreadSessionMap(memoryStore()),
    state: createMemoryState(),
    // The production wiring (D35): a real ChatClient on the routed install's
    // own token — NOT a stubbed runTurnImpl, so the 202 is a real 202.
    chatClientForInstall: (routed) =>
      createChatClient({ baseUrl: API_URL, token: routed.chatToken }),
    onOutcome: (outcome) => {
      outcomes.push(outcome);
    },
  };

  const mounted = mountInstall(connector, install, deps);

  // The webhook answers BEFORE the turn finishes (waitUntil semantics). Drain the
  // background work before asserting, or the assertions race the thing they prove.
  const background: Promise<unknown>[] = [];
  const waitUntil = (task: Promise<unknown>) => {
    background.push(task);
  };

  // The SDK types `chat.webhooks` per-adapter-key, which a generic mount cannot
  // narrow — fail loudly here rather than let TS force a silent `?.` no-op call.
  const fireWebhook = (request: Request): Promise<Response> => {
    const handler = mounted.chat.webhooks[WHATSAPP_PROVIDER];
    if (!handler) throw new Error("whatsapp webhook handler not mounted");
    return handler(request, { waitUntil });
  };

  return {
    mounted,
    outcomes,
    fireWebhook,
    settled: async () => {
      await Promise.allSettled(background);
    },
  };
}

describe("ack-first visible indicator — onAck starts the adapter's typing indicator (D170)", () => {
  it("calls mounted.adapter.startTyping(threadId) when /v1/chat accepts the turn, before the reply posts", async () => {
    const { mounted, outcomes, fireWebhook, settled } = mountRealInstall();

    const order: string[] = [];
    const startTyping = vi
      .spyOn(mounted.adapter, "startTyping")
      .mockImplementation(async (threadId: string) => {
        order.push(`typing:${threadId}`);
      });
    // Make the channel post observable (and keep it off the dead Graph URL) so
    // post-once and the typing-before-reply ordering are both provable.
    const postMessage = vi
      .spyOn(mounted.adapter, "postMessage")
      .mockImplementation(async (threadId: string) => {
        order.push(`post:${threadId}`);
        return {} as never;
      });

    mock.setReply("slow but real answer");
    const response = await fireWebhook(signedRequest(webhookBody("hei barkpark")));
    expect(response.status).toBe(200);
    await settled();

    // HARNESS SANITY, so a red below can only mean the indicator gap: the turn
    // genuinely ran end-to-end — the user's text reached /v1/chat on this
    // install's token, and the reply posted exactly once (D12/D26).
    expect(mock.sentMessages).toEqual([
      { sessionId: "session-1", content: "hei barkpark" },
    ]);
    expect(outcomes.map((o) => o.status)).toEqual(["posted"]);
    expect(postMessage).toHaveBeenCalledTimes(1);

    // THE INDICATOR (the assertion that is RED on pre-D170 main): the ack is now
    // user-visible — the adapter's typing indicator starts on THIS thread.
    expect(startTyping).toHaveBeenCalledTimes(1);
    expect(startTyping).toHaveBeenCalledWith(THREAD);
    // Ack-FIRST: the indicator starts before the reply lands, or it is not an ack.
    expect(order).toEqual([`typing:${THREAD}`, `post:${THREAD}`]);
  });

  it("a startTyping failure never fails the turn — the .catch is load-bearing (imessage throws in local mode)", async () => {
    const { mounted, outcomes, fireWebhook, settled } = mountRealInstall();

    const startTyping = vi
      .spyOn(mounted.adapter, "startTyping")
      .mockRejectedValue(new Error("startTyping is not supported in local mode"));
    const postMessage = vi
      .spyOn(mounted.adapter, "postMessage")
      .mockResolvedValue({} as never);

    mock.setReply("still answered");
    const response = await fireWebhook(signedRequest(webhookBody("hei igjen")));
    expect(response.status).toBe(200);
    await settled();

    // The indicator was attempted, rejected — and the turn did not care: the
    // reply still posted exactly once, and no failure notice was emitted.
    expect(startTyping).toHaveBeenCalledTimes(1);
    expect(outcomes.map((o) => o.status)).toEqual(["posted"]);
    expect(postMessage).toHaveBeenCalledTimes(1);
    expect(postMessage).toHaveBeenCalledWith(THREAD, "still answered");
  });
});
