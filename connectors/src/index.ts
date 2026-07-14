import { Chat, type Adapter, type StateAdapter } from "chat";
import type pg from "pg";
import { pathToFileURL } from "node:url";

import { createChatClient } from "./chat-client/client.js";
import type { ChatClient } from "./chat-client/types.js";
import { loadConfig, type BridgeConfig } from "./config.js";
import {
  createConnectorRegistry,
  type ConnectorRegistry,
} from "./connector/registry.js";
import type {
  AuthorizedInstall,
  Connector,
  ConnectorInstall,
  InboundEvent,
  InstallsLookup,
} from "./connector/types.js";
import { createCredentialCipher } from "./crypto/credential-cipher.js";
import {
  createTelegramConnector,
  TELEGRAM_PROVIDER,
} from "./connectors/telegram.js";
import { dispatchInbound, type DispatchOutcome } from "./core/dispatch.js";
import { createBridgePool, ensureBridgeSchema } from "./db/pool.js";
import { createWebhookMountIndex, type WebhookMountIndex } from "./http/mounts.js";
import { startWebhookServer, type WebhookServer } from "./http/webhook-server.js";
import { createBridgeState } from "./state/state-adapter.js";
import {
  createPgThreadSessionStore,
  createThreadSessionMap,
  type ThreadSessionMap,
} from "./state/thread-session-map.js";
import { createInstallsLookup } from "./tenant/installs.js";

/**
 * The Barkpark Connectors bridge (charter D4/D27/D32).
 *
 * A PERSISTENT Node process, not Vercel serverless functions: Telegram
 * getUpdates wants a long-lived poll loop, P3's Discord needs a persistent
 * gateway websocket, and the SSE glue is a long-lived streaming client. None
 * of that fits a function invocation.
 *
 * Multi-tenancy (D1) is structural: ONE Chat instance per INSTALL. Each Chat
 * is built from exactly one workspace's bot credential and talks to /v1/chat
 * with exactly that workspace's token — a tenant's adapter can never be
 * constructed from another tenant's secret.
 *
 * Both of those secrets are SEALED at rest (AES-256-GCM, AAD-bound to the
 * install row — D35) and opened only through `tenant/installs.ts`. The bridge
 * holds no process-wide chat token at all: there is nothing here that could
 * serve one tenant's traffic on another tenant's credential.
 */

/** P3 adds its channels HERE and nowhere else. */
export function registerBuiltinConnectors(registry: ConnectorRegistry): void {
  if (!registry.has(TELEGRAM_PROVIDER)) {
    registry.register(createTelegramConnector({ mode: "polling" }));
  }
  // P3: registry.register(createSlackConnector());   // payload-team-id
  // P3: registry.register(createDiscordConnector()); // credential-bound
}

export interface BridgeDeps {
  config: BridgeConfig;
  registry: ConnectorRegistry;
  installs: InstallsLookup;
  map: ThreadSessionMap;
  /** The Chat SDK's own state backend (subscriptions/locks), on chat_bridge. */
  state: StateAdapter;
  /**
   * Mint a ChatClient bound to THIS install's own chat token — the one sealed in
   * the same `connector_installs` row that routed the event (D35). Takes an
   * {@link AuthorizedInstall}, so a tokenless install cannot even be passed in.
   */
  chatClientForInstall(
    install: AuthorizedInstall,
  ): ChatClient | Promise<ChatClient>;
  onOutcome?: (outcome: DispatchOutcome, event: InboundEvent) => void;
  /** Fired when /v1/chat accepts the turn (D21) — NOT a channel post. */
  onAck?: (event: InboundEvent) => void;
}

export interface MountedInstall {
  connector: Connector;
  install: ConnectorInstall;
  chat: Chat;
  adapter: Adapter;
}

/**
 * Build one Chat for one install, with the core loop wired to every inbound
 * shape the SDK routes (DM, new mention, follow-up in a subscribed thread).
 *
 * The handlers are three thin wrappers around the SAME dispatchInbound call —
 * so a channel's routing quirks never leak into the core loop.
 */
export function mountInstall(
  connector: Connector,
  install: ConnectorInstall,
  deps: BridgeDeps,
): MountedInstall {
  const adapter = connector.adapterFactory(install);

  const chat = new Chat({
    userName: deps.config.userName,
    adapters: { [connector.id]: adapter },
    state: deps.state,
  });

  const handle = async (
    threadId: string,
    text: string,
    reply: (out: string) => Promise<unknown>,
    payload?: unknown,
  ): Promise<void> => {
    const event: InboundEvent = {
      provider: connector.id,
      threadId,
      text,
      // The transport knows which credential received this — that IS the
      // tenant binding for a credential-bound connector (D29).
      installKey: install.installKey,
      payload,
    };

    // Tracked so a failure AFTER the reply landed can never double-post.
    let posted = false;

    try {
      const outcome = await dispatchInbound(event, {
        registry: deps.registry,
        installs: { installs: deps.installs },
        map: deps.map,
        chatClientForInstall: deps.chatClientForInstall,
        reply: async (out) => {
          posted = true;
          await reply(out);
        },
        // Ack-first (D21): fires on the 202, long before the model speaks. The
        // user-visible ack is the adapter's own typing indicator (Telegram
        // starts one for DMs) — we deliberately do NOT post an ack message,
        // which would break post-once-per-turn.
        onAck: () => {
          deps.onAck?.(event);
        },
      });

      deps.onOutcome?.(outcome, event);
    } catch (err) {
      // An honest error state beats silence: the human sent a message and is
      // waiting. Only speak if the turn never got a reply out.
      console.error(`[bridge] turn failed on ${event.provider} ${threadId}:`, err);
      if (!posted) {
        try {
          await reply(
            "Something went wrong handling that message. It was not delivered to the agent.",
          );
        } catch (replyErr) {
          console.error("[bridge] could not deliver the failure notice:", replyErr);
        }
      }
    }
  };

  chat.onDirectMessage(async (thread, message) => {
    await thread.subscribe();
    await handle(thread.id, message.text, (out) => thread.post(out), message);
  });

  chat.onNewMention(async (thread, message) => {
    await thread.subscribe();
    await handle(thread.id, message.text, (out) => thread.post(out), message);
  });

  chat.onSubscribedMessage(async (thread, message) => {
    await handle(thread.id, message.text, (out) => thread.post(out), message);
  });

  return { connector, install, chat, adapter };
}

export interface Bridge {
  pool: pg.Pool;
  installs: InstallsLookup;
  mounted: MountedInstall[];
  /** The install-keyed webhook mount index (D39). Empty when no webhook channel is installed. */
  mounts: WebhookMountIndex;
  /** The inbound HTTP listener, or undefined when `config.webhook.enabled` is false. */
  webhookServer?: WebhookServer;
  /**
   * Mount an install AFTER boot — no restart. This is what makes an OAuth
   * "Add to Slack" callback work: upsertInstall (row) -> addInstall (Chat +
   * webhook mount) and the very next provider event routes. Without it the mount
   * index would be a boot snapshot and a freshly-installed workspace would 404
   * until someone restarted the process.
   */
  addInstall(install: ConnectorInstall): Promise<MountedInstall>;
  /** Stop routing an install — the disconnect half of the same promise. */
  removeInstall(provider: string, installKey: string): Promise<boolean>;
  shutdown(): Promise<void>;
}

/**
 * Injection seam for the composition root. Production passes nothing; a test
 * substitutes a registry of stub connectors so the boot path can be proven
 * end-to-end without a real bot token and a real provider on the other end.
 */
export interface StartBridgeOverrides {
  registry?: ConnectorRegistry;
  chatClientForInstall?: BridgeDeps["chatClientForInstall"];
}

/**
 * Boot the persistent bridge: schema, state, registry, then one Chat per
 * install found in `connector_installs`, then the inbound HTTP listener for the
 * webhook channels among them.
 */
export async function startBridge(
  config: BridgeConfig = loadConfig(),
  overrides: StartBridgeOverrides = {},
): Promise<Bridge> {
  // Built FIRST, before anything touches the network or the database: a missing
  // or malformed CONNECTORS_CREDENTIAL_KEY is a boot failure, and it should be
  // the fastest, loudest one. There is no plaintext fallback to fall into.
  const cipher = createCredentialCipher({
    key: config.credentialKey,
    previousKeys: config.previousCredentialKeys,
  });

  const pool = createBridgePool({ connectionString: config.databaseUrl });
  // Idempotent, and FAIL-CLOSED: refuses to boot if the pool's search_path is not
  // pinned to chat_bridge, because state-pg's unqualified DDL would then land in
  // Barkpark's Ecto-owned `public` schema (D28). No Ecto migration (D33).
  await ensureBridgeSchema(pool);

  const state = createBridgeState(pool);
  const installs = createInstallsLookup(pool, cipher);
  const map = createThreadSessionMap(createPgThreadSessionStore(pool));

  const registry = overrides.registry ?? createConnectorRegistry();
  if (!overrides.registry) registerBuiltinConnectors(registry);

  const deps: BridgeDeps = {
    config,
    registry,
    installs,
    map,
    state,
    // Each tenant's traffic travels on ITS OWN workspace-bound `chat` ApiToken,
    // opened from the very install row that routed the event (D35). The token
    // and the routing key are two columns of one row — the bridge holds no
    // process-wide token that could stand in for a missing one.
    chatClientForInstall:
      overrides.chatClientForInstall ??
      ((install: AuthorizedInstall) =>
        createChatClient({ baseUrl: config.apiUrl, token: install.chatToken })),
    onOutcome: (outcome, event) => {
      console.log(
        `[bridge] ${event.provider} thread=${event.threadId} -> ${outcome.status}` +
          (outcome.sessionUuid
            ? ` session=${outcome.sessionUuid}${outcome.minted ? " (minted)" : ""}`
            : ""),
      );
    },
  };

  // The webhook routing table (D39). Keyed by the INSTALL row, so a provider's
  // request can only ever reach the Chat built from THAT tenant's credential.
  const mounts = createWebhookMountIndex();
  const mounted: MountedInstall[] = [];

  /**
   * Mount one install and start its inbound transport. The SAME path is used at
   * boot and at runtime (an OAuth callback), so a freshly-installed workspace is
   * routable the moment its row exists — never "after the next restart".
   */
  const bringUp = async (
    connector: Connector,
    install: ConnectorInstall,
  ): Promise<MountedInstall> => {
    const entry = mountInstall(connector, install, deps);
    await entry.chat.initialize();
    // The core never learns the channel: Telegram starts a poll loop here,
    // Discord starts a gateway socket, and a webhook channel does nothing at all
    // — its transport IS the HTTP request, so it mounts into the index instead.
    await connector.listen?.(entry.adapter);
    if (connector.webhook) {
      mounts.mount({ connector, install, chat: entry.chat });
    }
    mounted.push(entry);
    console.log(
      `[bridge] listening: ${connector.id} install=${install.installKey} ` +
        `workspace=${install.workspaceId}` +
        (connector.webhook ? " (webhook)" : ""),
    );
    return entry;
  };

  const takeDown = async (
    provider: string,
    installKey: string,
  ): Promise<boolean> => {
    const index = mounted.findIndex(
      (entry) =>
        entry.connector.id === provider && entry.install.installKey === installKey,
    );
    if (index === -1) return false;
    const [entry] = mounted.splice(index, 1);
    if (!entry) return false;
    // Unroute FIRST: an in-flight webhook must not reach a Chat we are tearing down.
    mounts.unmount(provider, installKey);
    await entry.connector.stopListening?.(entry.adapter);
    await entry.chat.shutdown();
    console.log(`[bridge] unmounted: ${provider} install=${installKey}`);
    return true;
  };

  for (const connector of registry.channels()) {
    for (const install of await installs.listInstalls(connector.id)) {
      await bringUp(connector, install);
    }
  }

  if (mounted.length === 0) {
    console.warn(
      "[bridge] no connector installs found in chat_bridge.connector_installs — " +
        "nothing to listen on. See connectors/docs/telegram-smoke.md to register a bot.",
    );
  }

  // The listener comes up even with zero webhook installs today: the whole point
  // of dynamic mounting is that the FIRST install must not need a restart.
  let webhookServer: WebhookServer | undefined;
  if (config.webhook.enabled) {
    webhookServer = await startWebhookServer({
      registry,
      installs,
      mounts,
      port: config.webhook.port,
      pathPrefix: config.webhook.pathPrefix,
      publicBaseUrl: config.webhook.publicBaseUrl,
      maxBodyBytes: config.webhook.maxBodyBytes,
    });
    console.log(
      `[bridge] webhooks on :${webhookServer.port}${config.webhook.pathPrefix}/webhooks/… ` +
        `(${mounts.size()} mounted)`,
    );
  }

  return {
    pool,
    installs,
    mounted,
    mounts,
    webhookServer,

    async addInstall(install: ConnectorInstall) {
      const connector = registry.get(install.provider);
      if (!connector) {
        throw new Error(
          `bridge.addInstall: no connector registered for provider "${install.provider}"`,
        );
      }
      // Replace rather than duplicate: a re-install (OAuth re-authorised, new
      // credential) must not leave the old Chat running against the old secret.
      await takeDown(install.provider, install.installKey);
      return bringUp(connector, install);
    },

    async removeInstall(provider: string, installKey: string) {
      return takeDown(provider, installKey);
    },

    async shutdown() {
      await webhookServer?.close();
      for (const install of mounted) {
        await install.connector.stopListening?.(install.adapter);
        await install.chat.shutdown();
      }
      mounts.clear();
      mounted.length = 0;
      await pool.end();
    },
  };
}

/** Persistent entrypoint (`npm start`). */
async function main(): Promise<void> {
  const bridge = await startBridge();

  const stop = async (signal: string) => {
    console.log(`[bridge] ${signal} — shutting down`);
    await bridge.shutdown();
    process.exit(0);
  };
  process.on("SIGINT", () => void stop("SIGINT"));
  process.on("SIGTERM", () => void stop("SIGTERM"));

  console.log("[bridge] up — persistent process (D32). Ctrl-C to stop.");
}

// Only run when executed directly, never on import (tests import this module).
// pathToFileURL, not string concat: a path with a space or a non-ASCII char
// would not compare equal otherwise, and the process would silently no-op.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error("[bridge] fatal:", err);
    process.exit(1);
  });
}
