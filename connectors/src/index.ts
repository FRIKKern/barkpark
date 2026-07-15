import { Chat, type Adapter, type StateAdapter } from "chat";
import type pg from "pg";
import { pathToFileURL } from "node:url";

import { createChatClient } from "./chat-client/client.js";
import type { ChatClient } from "./chat-client/types.js";
import {
  consumePendingConnect,
  stagePendingConnect,
} from "./connect/pending-connect.js";
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
import { createDiscordConnector, DISCORD_PROVIDER } from "./connectors/discord.js";
import { createGithubConnector, GITHUB_PROVIDER } from "./connectors/github.js";
import {
  createIMessageConnector,
  IMESSAGE_PROVIDER,
  isSelfHostedProfile,
} from "./connectors/imessage.js";
import { createSlackConnector, SLACK_PROVIDER } from "./connectors/slack.js";
import { createTeamsConnector, TEAMS_PROVIDER } from "./connectors/teams.js";
import {
  createTelegramConnector,
  TELEGRAM_PROVIDER,
} from "./connectors/telegram.js";
import {
  createWhatsappConnector,
  WHATSAPP_PROVIDER,
} from "./connectors/whatsapp.js";
import { dispatchInbound, type DispatchOutcome } from "./core/dispatch.js";
import { createBridgePool, ensureBridgeSchema } from "./db/pool.js";
import type { ConnectDeps } from "./http/connect.js";
import type { SlackOAuthCallbackDeps } from "./oauth/slack-oauth.js";
import { createWebhookMountIndex, type WebhookMountIndex } from "./http/mounts.js";
import { startWebhookServer, type WebhookServer } from "./http/webhook-server.js";
import { createBridgeState } from "./state/state-adapter.js";
import {
  createPgThreadSessionStore,
  createThreadSessionMap,
  type ThreadSessionMap,
} from "./state/thread-session-map.js";
import {
  createInstallsLookup,
  deleteInstall,
  upsertInstall,
} from "./tenant/installs.js";

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
  /**
   * `chat_bridge.connector_installs` — the tenant map, with both secrets ALREADY
   * OPENED (`createInstallsLookup(pool, cipher)`, D35/D37). A connector that
   * reads a credential reads it from here and never learns the cipher.
   */
  installs?: InstallsLookup;
  /** Slack app credentials. Absent ⇒ Slack is not registered. */
  slack?: {
    signingSecret: string;
    clientId: string;
    clientSecret: string;
  };
  /** Read for the operator-profile gate (`CONNECTORS_PROFILE=self-hosted`, D44). */
  env?: NodeJS.ProcessEnv;
}

/**
 * P3 adds its channels HERE and nowhere else.
 *
 * Six channels, five shapes, ONE core loop — and the diff below is the whole of
 * the epic's acceptance bar (D30): `core/dispatch.ts`, `tenant/resolve.ts`,
 * `connector/registry.ts` and `turn/turn-loop.ts` are untouched by every one of
 * them. Between them they exercise BOTH tenant strategies (credential-bound and
 * payload-team-id), BOTH credential models (per-install and one-operator-app) and
 * BOTH transports (webhook and socket), which is what makes the invariant real
 * rather than asserted.
 */
export function registerBuiltinConnectors(
  registry: ConnectorRegistry,
  deps: BuiltinConnectorDeps = {},
): void {
  const env = deps.env ?? process.env;

  // Telegram — credential-bound BYO-bot, getUpdates poll loop (D29).
  if (!registry.has(TELEGRAM_PROVIDER)) {
    registry.register(createTelegramConnector({ mode: "polling" }));
  }

  // Slack — payload-team-id, webhook + Add-to-Slack OAuth, per-install bot token
  // via installationProvider (D40). Needs the installs table BEFORE any adapter
  // exists, which is why the deps bag exists at all: that is a GENERIC need of
  // the strategy, never an `if (provider === "slack")`.
  if (!registry.has(SLACK_PROVIDER)) {
    if (deps.slack && deps.installs) {
      registry.register(
        createSlackConnector({ ...deps.slack, installs: deps.installs }),
      );
    } else if (deps.slack) {
      console.warn(
        "[bridge] slack: app credentials present but no installs lookup — not registered. " +
          "A Slack adapter with no install table could not resolve any tenant's bot token.",
      );
    }
  }

  // Discord — credential-bound BYO-bot, Gateway socket, no webhook (D41). A
  // shared app would mean ONE bot token serving every tenant: the headline bug.
  if (!registry.has(DISCORD_PROVIDER)) {
    registry.register(createDiscordConnector());
  }

  // Teams — ONE operator Azure app (MultiTenant), payload-tenant routing, NO
  // per-workspace provider credential (D42).
  if (!registry.has(TEAMS_PROVIDER)) {
    registry.register(createTeamsConnector());
  }

  // WhatsApp — credential-bound BYO Meta app; all four creds per-install, so the
  // webhook key rides the PATH (the body must not choose the secret that verifies
  // the body) (D43).
  if (!registry.has(WHATSAPP_PROVIDER)) {
    registry.register(createWhatsappConnector());
  }

  // GitHub — the FIRST tool connector (D69/D71), the epic's OTHER direction. The
  // agent ACTS on GitHub via its hosted MCP server; there is no inbound channel,
  // so this is `direction:"tool"` and `registry.channels()` never mounts it. It
  // needs nothing at registration (the PAT arrives per-install on /connect) — one
  // registry entry, ZERO core-loop change, exactly like every channel before it. A
  // second tool connector (Linear) is a second line here.
  if (!registry.has(GITHUB_PROVIDER)) {
    registry.register(createGithubConnector());
  }

  // iMessage is a self-hosted OPERATOR PROFILE, never a Cloud product (D3/D44):
  // it needs a dedicated Mac signed into an Apple ID, so it has no multi-tenant
  // story at all. FAIL-CLOSED — an unset/other/misspelled profile does not get
  // it, so a Cloud deployment can never offer iMessage by accident.
  if (isSelfHostedProfile(env) && !registry.has(IMESSAGE_PROVIDER)) {
    registry.register(createIMessageConnector());
  }
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
  registry: ConnectorRegistry;
  installs: InstallsLookup;
  mounted: MountedInstall[];
  /** The install-keyed webhook mount index (D39). Empty when no webhook channel is installed. */
  mounts: WebhookMountIndex;
  /** The inbound HTTP listener, or undefined when `config.webhook.enabled` is false. */
  webhookServer?: WebhookServer;
  /**
   * Mount an install that appeared AFTER boot — no restart. This is what makes
   * an OAuth "Add to Slack" callback work: upsertInstall (row) -> addInstall
   * (Chat + webhook mount) and the very next provider event routes. Without it
   * the mount index would be a boot snapshot and a freshly-installed workspace
   * would 404 until someone restarted the process.
   *
   * Provider-agnostic: it takes a `ConnectorInstall` and looks the connector up
   * in the registry. Slack's OAuth callback uses it; Discord's and Teams' will
   * use the SAME function, unchanged.
   */
  addInstall(install: ConnectorInstall): Promise<MountedInstall>;
  /** Stop routing an install — the disconnect half of the same promise. */
  removeInstall(provider: string, installKey: string): Promise<boolean>;
  /** @deprecated alias of {@link Bridge.addInstall} — kept for the OAuth callsites. */
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

  const pool = createBridgePool({
    connectionString: config.databaseUrl,
    // A terminated idle backend (Postgres restart/failover) is survivable — the
    // pool drops the dead client and opens a fresh one — but it must be VISIBLE.
    onIdleClientError: (err) =>
      console.warn(
        `[bridge] idle Postgres client dropped by the server (pool recovers): ${err.message}`,
      ),
  });
  // Idempotent, and FAIL-CLOSED: refuses to boot if the pool's search_path is not
  // pinned to chat_bridge, because state-pg's unqualified DDL would then land in
  // Barkpark's Ecto-owned `public` schema (D28). No Ecto migration (D33).
  await ensureBridgeSchema(pool);

  const state = createBridgeState(pool);
  const installs = createInstallsLookup(pool, cipher);
  const map = createThreadSessionMap(createPgThreadSessionStore(pool));

  // The Slack app credentials, read ONCE — the registry needs them to build the
  // adapter, and the OAuth callback deps below need them to exchange the code.
  const slackApp = slackDepsFromEnv(process.env);

  const registry = overrides.registry ?? createConnectorRegistry();
  if (!overrides.registry) {
    registerBuiltinConnectors(registry, {
      installs,
      env: process.env,
      // Absent SLACK_* env ⇒ Slack is simply not registered. Spreading rather than
      // passing `undefined` keeps `exactOptionalPropertyTypes` happy.
      ...(slackApp ? { slack: slackApp } : {}),
    });
  }

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

  /**
   * ONE BAD TOKEN MUST NOT TAKE THE FLEET DOWN (charter D53).
   *
   * `bringUp` awaits `chat.initialize()`, and a revoked Telegram token throws
   * `AuthenticationError` straight out of it. Before this wave nothing caught it:
   * the rejection escaped `startBridge`, `main()` called `process.exit(1)`, systemd
   * `Restart=on-failure` crash-looped the unit, and `instance-deploy.sh` eventually
   * ran `systemctl disable --now barkpark-connectors` — at which point `/connectors`
   * was the maintenance 503 FOR EVERY TENANT. And because `listInstalls` is
   * `ORDER BY install_key`, the LOWEST-SORTING bad row poisoned every install after
   * it: the healthy tenant never mounted at all.
   *
   * This ships WITH the connect loop rather than as later hardening, and that is
   * the whole argument for its urgency: paste-a-token makes bad tokens ROUTINE, and
   * a token that is revoked after it was pasted fails at the NEXT RESTART — long
   * after the operator who could explain it has gone home.
   *
   * So: at BOOT, one bad install is skipped, loudly, and everyone else is served. A
   * bridge with zero healthy installs still comes up and still answers /health —
   * because the deploy's liveness probe must be able to tell "the process is fine,
   * one tenant's token is not" from "the process is dead".
   *
   * The RUNTIME path (`addInstall`) deliberately still THROWS: the connect route
   * has a human waiting on the other end of it, and it must answer `mount_failed`
   * and roll its write back rather than report success about a bot that will never
   * speak.
   */
  const bringUpAtBoot = async (
    connector: Connector,
    install: ConnectorInstall,
  ): Promise<void> => {
    try {
      await bringUp(connector, install);
    } catch (error) {
      console.error(
        `[bridge] FAILED to mount ${connector.id} install=${install.installKey} ` +
          `workspace=${install.workspaceId} — SKIPPING it and continuing to boot. ` +
          "The credential is most likely revoked or rotated: re-connect this install. " +
          "Every other install on this bridge is unaffected.",
        error,
      );
    }
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

  const addInstall = async (install: ConnectorInstall): Promise<MountedInstall> => {
    const connector = registry.get(install.provider);
    if (!connector) {
      // Fail closed and loudly: an install with no connector has credentials
      // and no code to use them safely.
      throw new Error(
        `bridge.addInstall: no connector registered for provider "${install.provider}"`,
      );
    }
    // Replace rather than duplicate: a re-install (OAuth re-authorised, new
    // credential) must not leave the old Chat running against the old secret.
    await takeDown(install.provider, install.installKey);
    return bringUp(connector, install);
  };

  for (const connector of registry.channels()) {
    for (const install of await installs.listInstalls(connector.id)) {
      // Contained (D53): a bad row is skipped, not fatal. See `bringUpAtBoot`.
      await bringUpAtBoot(connector, install);
    }
  }

  if (mounted.length === 0) {
    console.warn(
      "[bridge] no connector installs found in chat_bridge.connector_installs — " +
        "nothing to listen on. See connectors/docs/telegram-smoke.md to register a bot.",
    );
  }

  /**
   * The connect loop's deps (D50/D51) — built ONLY when the bridge has a connect
   * secret. Absent ⇒ `connect` is undefined ⇒ the routes are not mounted and every
   * one of their paths is the same opaque 404 as any unknown route.
   */
  const connectDeps: ConnectDeps | undefined = config.connectSecret
    ? {
        secret: config.connectSecret,
        registry,
        installs,
        upsertInstall: (install) => upsertInstall(pool, cipher, install),
        deleteInstall: (provider, installKey) =>
          deleteInstall(pool, provider, installKey),
        // The RUNTIME mount, which throws — so a failed mount becomes a 502
        // `mount_failed` and the row that caused it is deleted (see http/connect.ts),
        // rather than a "connected!" about a bot that will never answer.
        mountInstall: addInstall,
        unmountInstall: takeDown,
        // Stage the OAuth flow's pending-connect row (D63) — seals the raw chat
        // token under the ticket nonce so the public callback can join it.
        stagePending: (input) => stagePendingConnect(pool, cipher, input),
      }
    : undefined;

  if (!connectDeps) {
    console.warn(
      "[bridge] CONNECTORS_CONNECT_SECRET is not set — the connect routes " +
        `(${config.webhook.pathPrefix}/connect, /connect/validate, /disconnect) are ` +
        "NOT MOUNTED and answer 404. Installs must be written to " +
        "chat_bridge.connector_installs by hand until the deploy provisions the secret. " +
        "This is not an error: the bridge boots and serves every existing install.",
    );
  }

  /**
   * THE ADD-TO-SLACK OAUTH CALLBACK deps (D62/D63). Mounted only when the bridge
   * has a Slack app (client id/secret), a connect secret (the ticket HMAC key),
   * AND a public base URL (Slack redirects a browser to an exact registered URL —
   * a loopback address could never be that). Any one missing ⇒ the callback route
   * answers the opaque 404, which is the honest state on an unconfigured box.
   *
   * `redirectUri` is derived from the SAME public base + path prefix the Elixir
   * Studio catalog builds its authorize URL from; the two MUST byte-match Slack's
   * registration (the human gate names it).
   */
  const publicBaseUrl = config.webhook.publicBaseUrl;
  const slackOAuth: SlackOAuthCallbackDeps | undefined =
    slackApp && config.connectSecret && publicBaseUrl
      ? {
          clientId: slackApp.clientId,
          clientSecret: slackApp.clientSecret,
          redirectUri: `${publicBaseUrl.replace(/\/+$/, "")}${config.webhook.pathPrefix}/oauth/slack/callback`,
          stateSecret: config.connectSecret,
          consumePendingConnect: (nonce) =>
            consumePendingConnect(pool, cipher, nonce),
          resolveWorkspace: (provider, installKey) =>
            installs.resolveWorkspace(provider, installKey),
          upsertInstall: (install) => upsertInstall(pool, cipher, install),
          mountInstall: addInstall,
        }
      : undefined;

  if (!slackOAuth) {
    console.warn(
      "[bridge] Add-to-Slack OAuth callback is NOT MOUNTED — needs SLACK_CLIENT_ID/" +
        "SLACK_CLIENT_SECRET, CONNECTORS_CONNECT_SECRET, and CONNECTORS_PUBLIC_BASE_URL. " +
        `${config.webhook.pathPrefix}/oauth/slack/callback answers 404 until they are set. ` +
        "The Slack channel itself still works for any install written another way.",
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
      ...(connectDeps ? { connect: connectDeps } : {}),
      ...(slackOAuth ? { slackOAuth } : {}),
      // LOOPBACK behind Caddy (D34). Binding every interface would expose the
      // seam — and the x-forwarded-* headers it trusts — straight to the internet.
      host: config.webhook.host,
      port: config.webhook.port,
      pathPrefix: config.webhook.pathPrefix,
      publicBaseUrl: config.webhook.publicBaseUrl,
      maxBodyBytes: config.webhook.maxBodyBytes,
    });
    console.log(
      `[bridge] webhooks on ${config.webhook.host}:${webhookServer.port}` +
        `${config.webhook.pathPrefix}/webhooks/… (${mounts.size()} mounted); ` +
        `health: ${config.webhook.pathPrefix}/health` +
        (connectDeps ? `; connect: ${config.webhook.pathPrefix}/connect` : ""),
    );

    // The tool-connector seam's own loopback base (D69/D71), resolved AFTER bind so
    // it carries the REAL port (an ephemeral `port: 0` in tests still works). This
    // is the URL the `headersHelper` curl POSTs to at MCP-connect — it MUST be the
    // loopback address, never `publicBaseUrl`: a helper hitting the public URL would
    // travel through Caddy, arrive with `x-forwarded-*`, and be refused as the
    // opaque 404 that keeps `tool-headers` loopback-only.
    if (connectDeps) {
      const host =
        config.webhook.host === "0.0.0.0" || config.webhook.host === "::"
          ? "127.0.0.1"
          : config.webhook.host;
      const hostForUrl = host.includes(":") ? `[${host}]` : host;
      connectDeps.toolHeadersBaseUrl = `http://${hostForUrl}:${webhookServer.port}${config.webhook.pathPrefix}`;
    }
  }

  return {
    pool,
    registry,
    installs,
    mounted,
    mounts,
    webhookServer,

    addInstall,

    async removeInstall(provider: string, installKey: string) {
      return takeDown(provider, installKey);
    },

    // `mount` is the name Slack's OAuth callback was written against. Same
    // function, two names either side of a merge; the alias costs a line and
    // spares every caller a rename.
    mount: addInstall,

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
