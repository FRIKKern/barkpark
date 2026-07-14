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
  Connector,
  ConnectorInstall,
  InboundEvent,
  InstallsLookup,
} from "./connector/types.js";
import { createSlackConnector, SLACK_PROVIDER } from "./connectors/slack.js";
import {
  createTelegramConnector,
  TELEGRAM_PROVIDER,
} from "./connectors/telegram.js";
import { dispatchInbound, type DispatchOutcome } from "./core/dispatch.js";
import { createBridgePool, ensureBridgeSchema } from "./db/pool.js";
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
 */

/**
 * What a builtin connector may ask the bridge for at REGISTRATION time.
 *
 * Telegram needs nothing (its credential arrives per-install, in
 * `adapterFactory`). A `payload-team-id` connector needs more: Slack resolves a
 * team's bot token from `connector_installs` on EVERY inbound event, so its
 * `installationProvider` has to close over the installs lookup before any adapter
 * exists. That is a GENERIC need of the strategy, not a Slack quirk — Teams will
 * want the same — so it is a deps bag, never an `if (provider === "slack")`.
 *
 * Deliberately optional: `registerBuiltinConnectors(registry)` with no deps still
 * works and registers every connector that needs nothing. A connector whose deps
 * are absent is SKIPPED LOUDLY (warn), because half-registering it would mean an
 * adapter that cannot resolve a token — silence there would look like "Slack is
 * broken" instead of "Slack is not configured".
 */
export interface BuiltinConnectorDeps {
  /** `chat_bridge.connector_installs` — the tenant map. */
  installs?: InstallsLookup;
  /** Slack app credentials. Absent ⇒ Slack is not registered. */
  slack?: {
    signingSecret: string;
    clientId: string;
    clientSecret: string;
  };
  /**
   * Open a sealed `credential_ref`. Identity today — the column still holds the
   * raw secret (KNOWN GAP, see `tenant/installs.ts`). The credential cipher plugs
   * in HERE, at one call site, and no connector changes.
   */
  decryptCredential?: (credentialRef: string) => string | Promise<string>;
}

/** P3 adds its channels HERE and nowhere else. */
export function registerBuiltinConnectors(
  registry: ConnectorRegistry,
  deps: BuiltinConnectorDeps = {},
): void {
  if (!registry.has(TELEGRAM_PROVIDER)) {
    registry.register(createTelegramConnector({ mode: "polling" }));
  }

  if (!registry.has(SLACK_PROVIDER)) {
    if (deps.slack && deps.installs) {
      registry.register(
        createSlackConnector({
          ...deps.slack,
          installs: deps.installs,
          ...(deps.decryptCredential
            ? { decryptCredential: deps.decryptCredential }
            : {}),
        }),
      );
    } else if (deps.slack) {
      console.warn(
        "[bridge] slack: app credentials present but no installs lookup — not registered. " +
          "A Slack adapter with no install table could not resolve any tenant's bot token.",
      );
    }
  }
  // P3: registry.register(createDiscordConnector()); // credential-bound
}

export interface BridgeDeps {
  config: BridgeConfig;
  registry: ConnectorRegistry;
  installs: InstallsLookup;
  map: ThreadSessionMap;
  /** The Chat SDK's own state backend (subscriptions/locks), on chat_bridge. */
  state: StateAdapter;
  /** Mint a per-workspace ChatClient. Override to give each tenant its token. */
  chatClientFor(workspaceId: string): ChatClient | Promise<ChatClient>;
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
        chatClientFor: deps.chatClientFor,
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
  registry: ConnectorRegistry;
  installs: InstallsLookup;
  mounted: MountedInstall[];
  /**
   * Mount an install that appeared AFTER boot — the OAuth path. Initializes its
   * Chat and starts its transport, so the tenant can message the bot the second
   * the connect flow returns. No restart, no deploy.
   *
   * Provider-agnostic on purpose: it takes a `ConnectorInstall` and looks the
   * connector up in the registry. Slack's OAuth callback uses it; Discord's and
   * Teams' will use the SAME function, unchanged.
   */
  mount(install: ConnectorInstall): Promise<MountedInstall>;
  shutdown(): Promise<void>;
}

/** Slack app credentials from the environment. Absent ⇒ Slack simply isn't registered. */
function slackDepsFromEnv(
  env: NodeJS.ProcessEnv,
): BuiltinConnectorDeps["slack"] | undefined {
  const signingSecret = env["SLACK_SIGNING_SECRET"]?.trim();
  const clientId = env["SLACK_CLIENT_ID"]?.trim();
  const clientSecret = env["SLACK_CLIENT_SECRET"]?.trim();
  if (!signingSecret || !clientId || !clientSecret) return undefined;
  return { signingSecret, clientId, clientSecret };
}

/**
 * Boot the persistent bridge: schema, state, registry, then one Chat per
 * Telegram install found in `connector_installs`.
 */
export async function startBridge(
  config: BridgeConfig = loadConfig(),
): Promise<Bridge> {
  const pool = createBridgePool({ connectionString: config.databaseUrl });
  // Idempotent, and FAIL-CLOSED: refuses to boot if the pool's search_path is not
  // pinned to chat_bridge, because state-pg's unqualified DDL would then land in
  // Barkpark's Ecto-owned `public` schema (D28). No Ecto migration (D33).
  await ensureBridgeSchema(pool);

  const state = createBridgeState(pool);
  const installs = createInstallsLookup(pool);
  const map = createThreadSessionMap(createPgThreadSessionStore(pool));

  const registry = createConnectorRegistry();
  registerBuiltinConnectors(registry, {
    installs,
    ...(slackDepsFromEnv(process.env)
      ? { slack: slackDepsFromEnv(process.env) }
      : {}),
  });

  const deps: BridgeDeps = {
    config,
    registry,
    installs,
    map,
    state,
    // KNOWN GAP — one operator token serves every tenant today (D33): this
    // ignores `workspaceId`. Tenant isolation is therefore only as strong as
    // this single token, and a `:global` one would read every workspace's
    // sessions. The seam is right; the token store is not built.
    // Backlog: task `connectors-per-workspace-chat-token`.
    chatClientFor: (_workspaceId: string) =>
      createChatClient({ baseUrl: config.apiUrl, token: config.chatToken }),
    onOutcome: (outcome, event) => {
      console.log(
        `[bridge] ${event.provider} thread=${event.threadId} -> ${outcome.status}` +
          (outcome.sessionUuid
            ? ` session=${outcome.sessionUuid}${outcome.minted ? " (minted)" : ""}`
            : ""),
      );
    },
  };

  const mounted: MountedInstall[] = [];

  /**
   * Mount ONE install and bring it live. The boot loop and the OAuth callback run
   * the SAME code path, so an install that arrives at 3pm behaves exactly like one
   * that was in the table at boot — there is no "restart to pick it up" state.
   *
   * Re-mounting an install we already serve (a team that re-installs the app, or a
   * rotated token) REPLACES it: the old Chat is stopped first, so two adapters can
   * never listen for the same install with two different credentials.
   */
  const mount = async (install: ConnectorInstall): Promise<MountedInstall> => {
    const connector = registry.get(install.provider);
    if (!connector) {
      // Fail closed and loudly: an install with no connector has credentials and
      // no code to use them safely.
      throw new Error(
        `[bridge] cannot mount install ${install.provider}/${install.installKey}: ` +
          `no connector registered for "${install.provider}"`,
      );
    }

    const existing = mounted.findIndex(
      (m) =>
        m.install.provider === install.provider &&
        m.install.installKey === install.installKey,
    );
    if (existing !== -1) {
      const stale = mounted[existing] as MountedInstall;
      await stale.connector.stopListening?.(stale.adapter);
      await stale.chat.shutdown();
      mounted.splice(existing, 1);
    }

    const next = mountInstall(connector, install, deps);
    await next.chat.initialize();
    // The core never learns the channel: Telegram starts a poll loop here,
    // Discord will start a gateway socket, Slack does nothing at all (its
    // transport IS the inbound HTTP request).
    await next.connector.listen?.(next.adapter);
    mounted.push(next);

    console.log(
      `[bridge] listening: ${next.connector.id} install=${next.install.installKey} ` +
        `workspace=${next.install.workspaceId}`,
    );
    return next;
  };

  for (const connector of registry.channels()) {
    for (const install of await installs.listInstalls(connector.id)) {
      await mount(install);
    }
  }

  if (mounted.length === 0) {
    console.warn(
      "[bridge] no connector installs found in chat_bridge.connector_installs — " +
        "nothing to listen on. See connectors/docs/telegram-smoke.md to register a bot, " +
        "or connectors/docs/slack-install.md to install a Slack app.",
    );
  }

  return {
    pool,
    registry,
    installs,
    mounted,
    mount,
    async shutdown() {
      for (const install of mounted) {
        await install.connector.stopListening?.(install.adapter);
        await install.chat.shutdown();
      }
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
