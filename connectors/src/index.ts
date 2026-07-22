import { Chat, type Adapter, type StateAdapter } from "chat";
import type pg from "pg";
import { pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";

import { createChatClient } from "./chat-client/client.js";
import type { ChatClient } from "./chat-client/types.js";
import {
  consumePendingConnect,
  stagePendingConnect,
} from "./connect/pending-connect.js";
import {
  loadConfig,
  DEFAULT_MOUNT_RECONCILE_INTERVAL_MS,
  DEFAULT_INSTALL_LEASE_INTERVAL_MS,
  DEFAULT_INSTALL_LEASE_TTL_MS,
  type BridgeConfig,
} from "./config.js";
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
  createDiscordConnector,
  DISCORD_PROVIDER,
  extendDiscordInteractionWebhook,
} from "./connectors/discord.js";
import { createGithubConnector, GITHUB_PROVIDER } from "./connectors/github.js";
import { createLinearConnector, LINEAR_PROVIDER } from "./connectors/linear.js";
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
import type { LinearOAuthCallbackDeps } from "./oauth/linear-oauth.js";
import type { SlackOAuthCallbackDeps } from "./oauth/slack-oauth.js";
import { createWebhookMountIndex, type WebhookMountIndex } from "./http/mounts.js";
import {
  createMountReconcile,
  type MountReconcile,
} from "./http/mount-reconcile.js";
import {
  createBridgeLeaseStore,
  createInstallLease,
  type InstallLease,
  type LeaseStore,
} from "./tenant/install-lease.js";
import { startWebhookServer, type WebhookServer } from "./http/webhook-server.js";
import { createBridgeState, scopeStateAdapter } from "./state/state-adapter.js";
import {
  createPgLockedThreadSessionMap,
  type ThreadSessionMap,
} from "./state/thread-session-map.js";
import { createPgWhatsappWindowStore } from "./state/whatsapp-window-store.js";
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
  /**
   * Linear OAuth client credentials (charter D92). Present ⇒ the Linear connector
   * carries a `refreshCredential` hook that re-tokens an expiring install at
   * header-build time. Absent ⇒ Linear still registers (the tool seam serves any
   * install written another way) but WITHOUT the refresh hook — a bare-string or
   * bundle credential is served as-is. Threaded exactly as `slack` is: a generic
   * need of the connector, never an `if (provider === "linear")`.
   */
  linear?: {
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

  // Discord — credential-bound BYO-bot (D41): a shared app would mean ONE bot
  // token serving every tenant, the headline bug. TWO additive transports (D225):
  // a Gateway socket for DMs/mentions AND a path-keyed Ed25519 webhook for
  // slash-command interactions (D228), both served by the one registry entry.
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

  // Linear — the SECOND tool connector (D77), the proof that "a second tool
  // connector is a second registry entry with ZERO core-loop change" is TRUE. It
  // is OAuth-only (no `connect` paste member), so it is never paste-connectable —
  // it lands through `oauth/linear-oauth.ts`. Registered UNCONDITIONALLY, exactly
  // like GitHub: registration makes the tool-descriptors/tool-headers seam serve
  // its installs; the OAuth CALLBACK route is separately gated on app credentials
  // (see `linearOAuth` below). One registry entry, one more line than GitHub's.
  if (!registry.has(LINEAR_PROVIDER)) {
    // The refresh hook (D92) is attached ONLY when Linear OAuth client creds were
    // threaded in — otherwise the connector still registers and serves any install,
    // just without header-build refresh. `refresh` needs the client id/secret to
    // drive `grant_type=refresh_token`; `installs` is not required (the route hands
    // the hook the already-opened install).
    registry.register(
      createLinearConnector(deps.linear ? { refresh: deps.linear } : {}),
    );
  }

  // iMessage is a self-hosted OPERATOR PROFILE, never a Cloud product (D3/D44):
  // it needs a dedicated Mac signed into an Apple ID, so it has no multi-tenant
  // story at all. FAIL-CLOSED — an unset/other/misspelled profile does not get
  // it, so a Cloud deployment can never offer iMessage by accident.
  if (isSelfHostedProfile(env) && !registry.has(IMESSAGE_PROVIDER)) {
    registry.register(createIMessageConnector());
  }
}

/**
 * Does this connector carry a LEASED transport (charter D93/D225)? A `listen()`
 * opens a long-lived socket/poll (a Discord Gateway socket, a Telegram
 * getUpdates poll) that must be single-owner across replicas — two of them
 * against one bot double-POST (Discord) or 409-Conflict (Telegram) — so the
 * install-lease coordinator, not boot, starts it.
 *
 * Transports are ADDITIVE (D225): a `webhook` block on the same connector does
 * NOT exclude it — Discord runs a Gateway socket AND an interactions webhook,
 * and the pre-D225 `webhook === undefined` clause here was an XOR that would
 * have silently killed the Gateway the moment the webhook block landed.
 *
 * LOCKSTEP (D226): `socketPollConnectors()` in tenant/install-lease.ts inlines
 * this exact predicate — it CANNOT import this function (index.ts imports
 * install-lease.ts; importing back is circular). Any edit here MUST be
 * mirrored there in the same diff.
 */
export function isLeaseManaged(connector: Connector): boolean {
  return (
    (connector.direction === "channel" || connector.direction === "both") &&
    typeof connector.listen === "function"
  );
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
  /**
   * Persist the inbound timestamp under the resolved workspace + thread (D178) —
   * the durable feed for WhatsApp's 24-hour window store. Generic: dispatch calls
   * it after workspace resolution, before the turn, and never learns the channel.
   */
  recordInbound?: (
    workspaceId: string,
    threadId: string,
    atMs: number,
  ) => void | Promise<void>;
}

export interface MountedInstall {
  connector: Connector;
  install: ConnectorInstall;
  chat: Chat;
  adapter: Adapter;
}

/**
 * Build one Chat for one install, with the core loop wired to every inbound
 * shape the SDK routes (DM, new mention, follow-up in a subscribed thread,
 * slash-command interaction, component action, and modal submit).
 *
 * The handlers are six thin wrappers around the SAME dispatchInbound call —
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
    // Namespaced per install (D160): the SDK keys its state on thread id
    // ALONE, and state-pg's key_prefix is global to the bridge — without this
    // scope, two installs sharing a raw provider thread id would share
    // subscriptions, cache, and locks across tenants.
    state: scopeStateAdapter(deps.state, connector.id, install.installKey),
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
        // Ack-first (D21/D170): fires on the 202, long before the model speaks.
        // The user-visible ack is the adapter's TYPING INDICATOR, started here —
        // a presence call, never a message post, so post-once-per-turn (D12/D26)
        // is untouched. Fire-and-forget: the .catch is LOAD-BEARING (imessage's
        // startTyping THROWS in local mode) — an indicator must never fail a turn.
        onAck: () => {
          adapter.startTyping(threadId).catch(() => {});
          deps.onAck?.(event);
        },
        // Persist the window from the connector's own vendor timestamp (D178).
        // dispatch names no channel: it reads connector.inboundTimestampMs and
        // calls this hook after workspace resolution, before the turn.
        ...(deps.recordInbound ? { recordInbound: deps.recordInbound } : {}),
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

  // Slash commands (D228/D229) — the FOURTH wrapper around the SAME handle
  // closure, so a Discord interaction funnels into the identical turn loop the
  // message handlers use, with ZERO core-loop change. The event has no thread
  // (it is not a subscribed conversation), so the reply targets event.channel.id
  // directly — the vendor adapter routes channel.post to the interaction
  // follow-up (PATCH /webhooks/{appId}/{token}/messages/@original) via
  // AsyncLocalStorage. FOUR vendor-contract laws hold here:
  //   - event.channel.id is passed VERBATIM (the vendor's namespaced
  //     "discord:{guild}:{chan}" id — the ALS store keys on it; unwrapping it
  //     silently drops the reply off the interaction);
  //   - dispatch text is `${event.command} ${event.text}`.trim() (D232), NEVER
  //     event.text alone — the vendor text is option-values-only, so a bare
  //     no-option command (/status) has text:"" and core/dispatch.ts drops empty
  //     text as dropped_empty_input BEFORE tenant resolution: a silent no-op that
  //     surfaces to the user as "The application did not respond" after the
  //     15-min interaction-token TTL;
  //   - the reply stays channel.post-shaped (the adapter, not the bridge, knows
  //     the interaction token);
  //   - the dispatch runs inside the vendor's requestContext.run (it rides
  //     waitUntil, not a fresh macrotask, so the ALS store survives).
  chat.onSlashCommand(async (event) => {
    await handle(
      event.channel.id,
      `${event.command} ${event.text}`.trim(),
      (out) => event.channel.post(out),
      event.raw,
    );
  });

  // Component actions (W30) — the FIFTH wrapper. A button click / select choice
  // on a bridge-posted card is acked by the vendor (Discord: type-6 deferred
  // update) and reaches a handler ONLY if one is registered — the ack is NOT
  // proof of handling, so without this wrapper every component interaction was
  // acked-then-dropped. Funnel text is the D232 idiom transposed: the actionId
  // is always non-empty (vendors guard custom_id before dispatch), so dispatch
  // can never drop the event as empty input; the value rides along only when it
  // says something the actionId doesn't (Discord defaults value := actionId for
  // plain buttons — repeating it would just stutter).
  chat.onAction(async (event) => {
    const thread = event.thread;
    if (!thread) {
      // View-based actions (e.g. a home-tab button) have no thread and thus no
      // reply surface for a turn — an honest skip beats a turn that cannot post.
      console.warn(
        `[bridge] action ${event.actionId} on ${connector.id} has no thread — skipped`,
      );
      return;
    }
    const detail = event.value && event.value !== event.actionId ? event.value : "";
    await handle(
      event.threadId,
      `${event.actionId} ${detail}`.trim(),
      (out) => thread.post(out),
      event.raw,
    );
  });

  // Modal submits (W30) — the SIXTH wrapper. The reply targets the channel the
  // modal was opened FROM (restored from the modal context stored at openModal
  // time); on Discord the intercept in extendDiscordInteractionWebhook runs this
  // dispatch inside the vendor's ALS store, so the post lands as the submit
  // interaction's own response. Values are serialized as JSON — deterministic,
  // and the turn sees exactly what the user typed, keyed by input id.
  chat.onModalSubmit(async (event) => {
    const target = event.relatedChannel ?? event.relatedThread;
    if (!target) {
      console.warn(
        `[bridge] modal submit ${event.callbackId} on ${connector.id} has no ` +
          "related channel (foreign or expired modal context) — skipped",
      );
      return;
    }
    await handle(
      target.id,
      `${event.callbackId} ${JSON.stringify(event.values)}`.trim(),
      (out) => target.post(out),
      event.raw,
    );
  });

  // Discord's missing MODAL_SUBMIT branch (W30) + the D249 modal-OPEN
  // hold-and-substitute (W31): wrap chat.webhooks.discord in place — a
  // verified type-5 would otherwise fall through the vendor dispatch switch to
  // 400 AFTER registration (so registering onModalSubmit above is necessary
  // but NOT sufficient), and a modal opened inside the hold window becomes the
  // interaction's own HTTP response instead of losing the vendor's ack race.
  // The window knob rides BridgeConfig (CONNECTORS_DISCORD_MODAL_WINDOW_MS);
  // undefined defaults inside the seam. No-op for every other provider
  // (guarded on the discord webhook key).
  extendDiscordInteractionWebhook(chat, adapter, {
    modalWindowMs: deps.config.discordModalWindowMs,
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
   * The periodic DB reconcile (D83) that lets a second replica rediscover an
   * install written by the first. Always present — at `intervalMs: 0` its timer
   * simply never arms — so a boot test can drive `reconcileOnce()` deterministically
   * instead of waiting for a tick.
   */
  mountReconcile: MountReconcile;
  /**
   * The socket/poll ownership coordinator (D93/D94) that keeps exactly ONE replica
   * driving each Discord Gateway socket / Telegram poll. Always present — at
   * `intervalMs: 0` its timer never arms — so a boot test drives `reconcileOnce()`
   * deterministically with two replicas over one Postgres.
   */
  installLease: InstallLease;
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
 * Linear OAuth app credentials from the environment. Absent ⇒ the Connect-to-Linear
 * callback route is simply NOT MOUNTED (the connector itself is still registered so
 * the tool seam serves any install written another way). No signing secret: Linear
 * is a tool connector with no inbound webhook to verify — only the outbound OAuth
 * code exchange, which needs the client id/secret.
 */
function linearDepsFromEnv(
  env: NodeJS.ProcessEnv,
): { clientId: string; clientSecret: string } | undefined {
  const clientId = env["LINEAR_CLIENT_ID"]?.trim();
  const clientSecret = env["LINEAR_CLIENT_SECRET"]?.trim();
  if (!clientId || !clientSecret) return undefined;
  return { clientId, clientSecret };
}

/**
 * Injection seam for the composition root. Production passes nothing; a test
 * substitutes a registry of stub connectors so the boot path can be proven
 * end-to-end without a real bot token and a real provider on the other end.
 */
export interface StartBridgeOverrides {
  registry?: ConnectorRegistry;
  chatClientForInstall?: BridgeDeps["chatClientForInstall"];
  /**
   * Force the mount-reconcile interval (ms), overriding `config`. A boot test
   * passes `0` to arm nothing and drive `bridge.mountReconcile?.reconcileOnce()`
   * by hand — the timing-free way to prove convergence.
   */
  mountReconcileIntervalMs?: number;
  /**
   * Force the install-lease renew/takeover interval (ms), overriding `config`. A
   * boot test passes `0` to arm nothing and drive `bridge.installLease.reconcileOnce()`
   * by hand — the timing-free way to prove single-owner + takeover.
   */
  installLeaseIntervalMs?: number;
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
  // Reserve-first: the mint is serialised under a per-thread advisory lock so a
  // concurrent first-message can never orphan a Barkpark Session
  // (connectors-orphan-session-on-mint-race).
  const map = createPgLockedThreadSessionMap(pool);
  // The durable WhatsApp 24-hour window (D169/D178). Fed here, on every inbound,
  // from the connector's own vendor timestamp — so a proactive send after a
  // restart still sees a genuinely-open window instead of restart amnesia.
  const whatsappWindow = createPgWhatsappWindowStore(pool);

  // THIS replica's identity for the socket/poll ownership lease (D93). A fresh
  // per-PROCESS UUID, not the hostname: templated pods share a hostname and would
  // collide; a randomUUID never does. Every claim/renew/release this process makes
  // carries this owner id, so the lease table can tell "still mine" from "another
  // replica's" with no ambiguity.
  const replicaId = randomUUID();
  const leaseTtlMs = config.installLeaseTtlMs ?? DEFAULT_INSTALL_LEASE_TTL_MS;
  const leaseStore: LeaseStore = createBridgeLeaseStore(pool, {
    ownerId: replicaId,
    ttlMs: leaseTtlMs,
  });

  // The Slack app credentials, read ONCE — the registry needs them to build the
  // adapter, and the OAuth callback deps below need them to exchange the code.
  const slackApp = slackDepsFromEnv(process.env);
  // The Linear OAuth client credentials, read ONCE and HOISTED here (D92) — the
  // registry needs them to attach the refresh hook, and the OAuth callback deps
  // further down reference this same variable to exchange the authorization code.
  const linearApp = linearDepsFromEnv(process.env);

  const registry = overrides.registry ?? createConnectorRegistry();
  if (!overrides.registry) {
    registerBuiltinConnectors(registry, {
      installs,
      env: process.env,
      // Absent SLACK_*/LINEAR_* env ⇒ the connector registers without that
      // capability. Spreading rather than passing `undefined` keeps
      // `exactOptionalPropertyTypes` happy.
      ...(slackApp ? { slack: slackApp } : {}),
      ...(linearApp ? { linear: linearApp } : {}),
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
    // Feed the durable window on every inbound (D178). The store's own monotonic
    // upsert makes a Meta redelivery a no-op; a throwing write is swallowed inside
    // dispatch, never reaching the reply path.
    recordInbound: (workspaceId, threadId, atMs) =>
      whatsappWindow.recordInbound(workspaceId, threadId, atMs),
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
    // The core never learns the channel. Transports are ADDITIVE (D225): each
    // check is INDEPENDENT, so a dual-transport connector (Discord: Gateway
    // socket + interactions webhook) runs BOTH — never an if/else ladder, whose
    // pre-D225 XOR would have evicted the socket the moment a webhook landed.
    if (connector.webhook) {
      // Webhook transport: an inbound HTTP request. Mount into the index; any
      // replica may serve it (W8 mount-reconcile keeps that safe).
      mounts.mount({ connector, install, chat: entry.chat });
    }
    if (isLeaseManaged(connector)) {
      // Socket/poll transport: its listen() opens a long-lived Gateway socket /
      // getUpdates poll that MUST be single-owner across replicas (D93). The
      // Chat is mounted here, but the TRANSPORT is started by the install-lease
      // coordinator's onAcquire — only on the replica that holds this install's
      // lease. Starting it here would double-serve on every scaled-out replica.
    } else if (typeof connector.listen === "function") {
      // A listen() outside lease management (a non-channel direction — none
      // exists today): direct start, preserving the pre-lease fallback.
      await connector.listen(entry.adapter);
    }
    mounted.push(entry);
    const transports = [
      ...(connector.webhook ? ["webhook"] : []),
      ...(isLeaseManaged(connector) ? ["socket/poll — transport lease-gated"] : []),
    ];
    console.log(
      `[bridge] mounted: ${connector.id} install=${install.installKey} ` +
        `workspace=${install.workspaceId}` +
        (transports.length > 0 ? ` (${transports.join(" + ")})` : ""),
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
    const connector = registry.get(provider);
    const index = mounted.findIndex(
      (entry) =>
        entry.connector.id === provider && entry.install.installKey === installKey,
    );
    if (index === -1) {
      // Not mounted here, but a socket/poll lease we own must still be released so
      // a rolling restart / disconnect frees it immediately. Owner-scoped, so it
      // is a no-op when we don't own it — and webhook installs hold no lease at all.
      if (connector && isLeaseManaged(connector)) {
        await leaseStore.release(provider, installKey);
      }
      return false;
    }
    const [entry] = mounted.splice(index, 1);
    if (!entry) return false;
    // Unroute FIRST: an in-flight webhook must not reach a Chat we are tearing down.
    mounts.unmount(provider, installKey);
    await entry.connector.stopListening?.(entry.adapter);
    await entry.chat.shutdown();
    // Release the socket/poll ownership lease (D94): a graceful shutdown or a
    // disconnect hands the install to a standby replica on its NEXT tick rather
    // than making it wait out the TTL. Owner-scoped and a no-op for webhook
    // installs, which have no lease row.
    if (isLeaseManaged(entry.connector)) {
      await leaseStore.release(provider, installKey);
    }
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
   * THE REPLICA-REDISCOVERY RECONCILE (D83). Boot mounted every row THIS process
   * can see, and `addInstall` mounts anything a connect/OAuth request handled HERE
   * lands — but a horizontally-scaled bridge has more than one process, and the
   * mount index is per-process in-memory. This periodic pass re-reads
   * `connector_installs` and converges the webhook mounts through the very same
   * `addInstall`/`removeInstall` paths, so a row another replica wrote becomes
   * routable here without a restart. `intervalMs: 0` disables it (single replica).
   * It enumerates ONLY webhook connectors: converging a poll/socket channel from a
   * rediscovered row would start a SECOND poll loop against the same bot — the
   * separate `connectors-replica-socket-poll-safety` hazard, never this loop.
   */
  const mountReconcileIntervalMs =
    overrides.mountReconcileIntervalMs ??
    config.mountReconcileIntervalMs ??
    DEFAULT_MOUNT_RECONCILE_INTERVAL_MS;
  const mountReconcile = createMountReconcile(
    {
      registry,
      installs,
      mounts,
      addInstall,
      removeInstall: takeDown,
    },
    { intervalMs: mountReconcileIntervalMs },
  );
  mountReconcile.start();
  if (mountReconcileIntervalMs > 0) {
    console.log(
      `[bridge] mount reconcile armed — re-reading connector_installs every ` +
        `${mountReconcileIntervalMs}ms so a second replica rediscovers new installs`,
    );
  }

  /**
   * THE SOCKET/POLL OWNERSHIP LEASE (D93/D94) — the honest remainder mount-reconcile
   * could NOT solve. A webhook is stateless, so every replica may hold the mount; a
   * Gateway socket / getUpdates poll is a long-lived connection, and opening it on
   * two replicas double-POSTs (Discord) or 409s (Telegram). So exactly ONE replica
   * leases each socket/poll install and drives its transport; the others stand by
   * and take over on lapse.
   *
   * Boot mounts the Chat for these installs but deliberately does NOT `listen()`
   * (see `bringUp`): the coordinator's `onAcquire` starts the transport, only on
   * the replica that wins the lease. A single-replica deploy just wins every lease
   * on the first pass. The scope is the exact COMPLEMENT of mount-reconcile's
   * webhook filter (`isLeaseManaged`): Discord + Telegram today; iMessage would ride
   * it unchanged but is a self-hosted one-Mac profile, never Cloud (D95).
   */
  const onAcquireTransport = async (install: ConnectorInstall): Promise<void> => {
    const connector = registry.get(install.provider);
    if (!connector) {
      throw new Error(
        `install-lease onAcquire: no connector registered for provider "${install.provider}"`,
      );
    }
    // The Chat is normally already mounted (boot mounted it as a standby). A row
    // that appeared AFTER this replica booted — a connect handled on another
    // replica — has no local Chat yet, so bring it up now (bringUp does NOT start
    // the transport for a lease-managed connector; we do that next).
    let entry = mounted.find(
      (candidate) =>
        candidate.connector.id === install.provider &&
        candidate.install.installKey === install.installKey,
    );
    if (!entry) entry = await bringUp(connector, install);
    await connector.listen?.(entry.adapter);
  };

  const onReleaseTransport = async (install: ConnectorInstall): Promise<void> => {
    const entry = mounted.find(
      (candidate) =>
        candidate.connector.id === install.provider &&
        candidate.install.installKey === install.installKey,
    );
    if (!entry) return;
    // Stop the transport but LEAVE the Chat mounted (cheap, idle) so a re-acquire
    // is a fast `listen()`, not a full re-mount. A full teardown happens on
    // takeDown/shutdown, which also releases the lease.
    await entry.connector.stopListening?.(entry.adapter);
  };

  const installLeaseIntervalMs =
    overrides.installLeaseIntervalMs ??
    config.installLeaseIntervalMs ??
    DEFAULT_INSTALL_LEASE_INTERVAL_MS;
  const installLease = createInstallLease(
    {
      registry,
      installs,
      lease: leaseStore,
      onAcquire: onAcquireTransport,
      onRelease: onReleaseTransport,
    },
    { intervalMs: installLeaseIntervalMs },
  );
  // Drive ONE pass at boot so the sole/first replica starts its socket/poll
  // transports immediately (no interval-length silence), then arm the periodic
  // renew/takeover timer. A boot test that wires a stub socket/poll connector with
  // `installLeaseIntervalMs: 0` still gets this one pass; a two-replica DB test
  // constructs coordinators directly and is unaffected by boot.
  await installLease.reconcileOnce();
  installLease.start();
  if (installLeaseIntervalMs > 0) {
    console.log(
      `[bridge] install lease armed — renewing socket/poll ownership every ` +
        `${installLeaseIntervalMs}ms (owner=${replicaId}); a standby replica takes ` +
        "over on lapse so exactly one drives each Discord socket / Telegram poll",
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

  /**
   * THE CONNECT-TO-LINEAR OAUTH CALLBACK deps (D77/D78) — the OUTBOUND (tool)
   * mirror of the Slack callback, MINUS consumePendingConnect (a tool install has
   * no chat token to stage) and MINUS mountInstall (a tool is never a channel).
   * Mounted only when the bridge has a Linear OAuth app (client id/secret), a
   * connect secret (the ticket HMAC key), AND a public base URL (Linear redirects a
   * browser to an exact registered URL — a loopback address could never be that).
   * Any one missing ⇒ the callback route answers the opaque 404.
   */
  // `linearApp` is read once and HOISTED beside `slackApp` (D92) so the registry can
  // attach the refresh hook from the same credentials this callback uses.
  const linearOAuth: LinearOAuthCallbackDeps | undefined =
    linearApp && config.connectSecret && publicBaseUrl
      ? {
          clientId: linearApp.clientId,
          clientSecret: linearApp.clientSecret,
          redirectUri: `${publicBaseUrl.replace(/\/+$/, "")}${config.webhook.pathPrefix}/oauth/linear/callback`,
          stateSecret: config.connectSecret,
          resolveWorkspace: (provider, installKey) =>
            installs.resolveWorkspace(provider, installKey),
          upsertInstall: (install) => upsertInstall(pool, cipher, install),
        }
      : undefined;

  if (!linearOAuth) {
    console.warn(
      "[bridge] Connect-to-Linear OAuth callback is NOT MOUNTED — needs LINEAR_CLIENT_ID/" +
        "LINEAR_CLIENT_SECRET, CONNECTORS_CONNECT_SECRET, and CONNECTORS_PUBLIC_BASE_URL. " +
        `${config.webhook.pathPrefix}/oauth/linear/callback answers 404 until they are set. ` +
        "The Linear tool connector still serves any install written another way.",
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
      ...(linearOAuth ? { linearOAuth } : {}),
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
    // Always exposed even at interval 0: `start()` self-guards the timer, so a
    // boot test can drive `reconcileOnce()` by hand without any tick firing.
    mountReconcile,
    installLease,

    addInstall,

    async removeInstall(provider: string, installKey: string) {
      return takeDown(provider, installKey);
    },

    // `mount` is the name Slack's OAuth callback was written against. Same
    // function, two names either side of a merge; the alias costs a line and
    // spares every caller a rename.
    mount: addInstall,

    async shutdown() {
      // Disarm both housekeeping loops BEFORE tearing anything down, or a tick
      // could re-acquire a lease / re-mount a row mid-shutdown.
      installLease.stop();
      mountReconcile.stop();
      await webhookServer?.close();
      // Tear every install down THROUGH `takeDown` (D94). The old inline loop
      // bypassed it — it stopped the transport and shut the Chat but NEVER
      // released the socket/poll lease, so a graceful/rolling restart stranded the
      // lease until its TTL lapsed and a standby replica sat idle for that whole
      // window. Routing through `takeDown` releases each lease immediately, so a
      // standby takes over on its very next tick. Snapshot the keys first:
      // `takeDown` splices `mounted` as it goes.
      const installed = mounted.map((entry) => ({
        provider: entry.connector.id,
        installKey: entry.install.installKey,
      }));
      for (const { provider, installKey } of installed) {
        await takeDown(provider, installKey);
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
