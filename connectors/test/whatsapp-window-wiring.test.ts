import { createMemoryState } from "@chat-adapter/state-memory";
import { createHmac } from "node:crypto";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import pg from "pg";

import { createChatClient } from "../src/chat-client/client.js";
import type { BridgeConfig } from "../src/config.js";
import { createConnectorRegistry } from "../src/connector/registry.js";
import type { ConnectorInstall } from "../src/connector/types.js";
import type { DispatchOutcome } from "../src/core/dispatch.js";
import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import {
  createWhatsappConnector,
  encodeWhatsappCredential,
  WHATSAPP_PROVIDER,
} from "../src/connectors/whatsapp.js";
import { mountInstall, type BridgeDeps } from "../src/index.js";
import { createPgWhatsappWindowStore } from "../src/state/whatsapp-window-store.js";
import {
  createThreadSessionMap,
  type ThreadSessionStore,
} from "../src/state/thread-session-map.js";
import { createInMemoryInstallsLookup } from "../src/tenant/installs.js";
import { API_URL, createMockChat } from "./fixtures/chat-server.js";

const DEAD_GRAPH = "http://127.0.0.1:1";
const PHONE = "111111111111111";
const APP_SECRET = "app-secret-alpha";
const WA_USER = "4799999999";
const THREAD = `whatsapp:${PHONE}:${WA_USER}`;
const INBOUND_TS_SECONDS = "1752451200";
const INBOUND_TS_MS = 1_752_451_200_000;

const install: ConnectorInstall = {
  provider: WHATSAPP_PROVIDER,
  installKey: PHONE,
  workspaceId: "ws-alpha",
  credentialRef: encodeWhatsappCredential({
    accessToken: "system-user-token-alpha",
    appSecret: APP_SECRET,
    verifyToken: "verify-token-alpha",
  }),
  chatToken: "test-token",
};

const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";
const TEST_DB = `connectors_wa_wiring_probe_${process.pid}_${Date.now()}`;

function urlForDatabase(base: string, database: string): string {
  const url = new URL(base);
  url.pathname = `/${database}`;
  return url.toString();
}

async function postgresReachable(): Promise<boolean> {
  const client = new pg.Client({ connectionString: ADMIN_URL });
  try {
    await client.connect();
    await client.end();
    return true;
  } catch {
    return false;
  }
}

const reachable = await postgresReachable();
const mock = createMockChat();

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
                  timestamp: INBOUND_TS_SECONDS,
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

function mountRealInstall(depsOverride?: Partial<BridgeDeps>) {
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
    chatClientForInstall: (routed) =>
      createChatClient({ baseUrl: API_URL, token: routed.chatToken }),
    onOutcome: (outcome) => {
      outcomes.push(outcome);
    },
    ...depsOverride,
  };
  const mounted = mountInstall(connector, install, deps);
  const background: Promise<unknown>[] = [];
  const waitUntil = (task: Promise<unknown>) => {
    background.push(task);
  };
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

let pool: pg.Pool;
let admin: pg.Client | undefined;
let testUrl: string;

beforeAll(async () => {
  if (!reachable) {
    if (REQUIRE_DB)
      throw new Error(
        `CONNECTORS_REQUIRE_DB=1 but no Postgres is reachable at ${ADMIN_URL}`,
      );
    return;
  }
  admin = new pg.Client({ connectionString: ADMIN_URL });
  await admin.connect();
  await admin.query(`CREATE DATABASE ${TEST_DB}`);
  testUrl = urlForDatabase(ADMIN_URL, TEST_DB);
  pool = createBridgePool({ connectionString: testUrl });
  await ensureBridgeSchema(pool);
  mock.server.listen({ onUnhandledRequest: "error" });
}, 30_000);

afterEach(() => {
  mock.server.resetHandlers();
  mock.reset();
});

afterAll(async () => {
  mock.server.close();
  await pool?.end();
  if (admin) {
    await admin.query(`DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)`);
    await admin.end();
  }
}, 30_000);

describe.skipIf(!reachable && !REQUIRE_DB)(
  "whatsapp-window wiring (D178): the inbound webhook feeds the durable window store",
  () => {
    it("records the inbound timestamp under the resolved workspace + thread id", async () => {
      const store = createPgWhatsappWindowStore(pool);
      const { mounted, outcomes, fireWebhook, settled } = mountRealInstall({
        recordInbound: (workspaceId, threadId, atMs) =>
          store.recordInbound(workspaceId, threadId, atMs),
      });
      vi.spyOn(mounted.adapter, "startTyping").mockResolvedValue(undefined);
      vi.spyOn(mounted.adapter, "postMessage").mockResolvedValue({} as never);
      mock.setReply("a real answer");
      const response = await fireWebhook(
        signedRequest(webhookBody("hei barkpark")),
      );
      expect(response.status).toBe(200);
      await settled();
      expect(mock.sentMessages).toEqual([
        { sessionId: "session-1", content: "hei barkpark" },
      ]);
      expect(outcomes.map((o) => o.status)).toEqual(["posted"]);
      // A fresh store on the SAME pool proves the row is durable, not in-flight
      // memory: the window survives a restart (charter D169/D178).
      const freshStore = createPgWhatsappWindowStore(pool);
      expect(await freshStore.getLastInboundAt("ws-alpha", THREAD)).toBe(
        INBOUND_TS_MS,
      );
    });

    it("still posts the reply when recordInbound rejects — persistence never takes down the reply path (D188)", async () => {
      const { mounted, outcomes, fireWebhook, settled } = mountRealInstall({
        recordInbound: () =>
          Promise.reject(new Error("whatsapp_window write exploded")),
      });
      vi.spyOn(mounted.adapter, "startTyping").mockResolvedValue(undefined);
      vi.spyOn(mounted.adapter, "postMessage").mockResolvedValue({} as never);
      mock.setReply("answered despite the store failing");
      const response = await fireWebhook(
        signedRequest(webhookBody("still there?")),
      );
      expect(response.status).toBe(200);
      await settled();
      expect(outcomes.map((o) => o.status)).toEqual(["posted"]);
    });
  },
);
