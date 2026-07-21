import { createDiscordAdapter, type DiscordAdapter } from "@chat-adapter/discord";
import type { Adapter, Author, ModalElement, WebhookOptions } from "chat";

import type {
  ConnectValidation,
  Connector,
  ConnectorInstall,
  InboundEvent,
  TenantContext,
} from "../connector/types.js";
import { credentialBoundResolver } from "../tenant/resolve.js";
import {
  startSupervisedGateway,
  type GatewaySession,
  type GatewayTuning,
} from "./gateway.js";

/**
 * Discord — a credential-bound, Gateway-only channel Connector (charter D41).
 *
 * ONE registry entry, ZERO core-loop change. Everything Discord-specific lives
 * in this file; `core/dispatch.ts`, `tenant/resolve.ts` and `connector/registry.ts`
 * never learn the word "discord".
 *
 * WHY BRING-YOUR-OWN-BOT, NOT A SHARED APP + `guild_id`
 * ----------------------------------------------------
 * A shared "Add to Discord" app would look like a nicer onboarding story, and it
 * is exactly the bug this wave exists to kill. `DiscordAdapterConfig` takes ONE
 * static `botToken` with no installation provider — there is no per-guild
 * credential hook. So a shared app means ONE credential serving EVERY tenant:
 * the headline multi-tenant leak, wearing an OAuth button as a disguise.
 *
 * Instead, each workspace creates its OWN Discord Application and bot token, and
 * the token IS the tenant binding (`tenantResolution: "credential-bound"`,
 * exactly like Telegram). Say this plainly when you document it: **Discord
 * onboarding is BYO-bot, not a one-click install.** See
 * `connectors/docs/discord-byo-bot.md`.
 *
 * WHY THE CREDENTIAL IS A JSON TRIPLE, NOT A BARE TOKEN
 * ----------------------------------------------------
 * `new DiscordAdapter(...)` requires THREE values — `applicationId`, `botToken`,
 * `publicKey` — and for any of them that is missing it falls back to
 * `process.env.DISCORD_APPLICATION_ID` / `DISCORD_BOT_TOKEN` / `DISCORD_PUBLIC_KEY`
 * (`node_modules/@chat-adapter/discord/dist/index.js:761-782`). In a multi-tenant
 * bridge that env fallback is a CROSS-TENANT LEAK: one stray `DISCORD_BOT_TOKEN`
 * in the process environment would silently serve every workspace whose install
 * row happened to be incomplete. So {@link parseDiscordCredential} demands all
 * three, up front, from THAT install's sealed `credential_ref`, and
 * `adapterFactory` passes all three EXPLICITLY — the env fallback is structurally
 * unreachable.
 *
 * `publicKey` verifies the Ed25519 signature on Discord's HTTP interactions —
 * required from the start precisely so that the day slash commands landed, every
 * existing install already carried a REAL key rather than a sentinel someone
 * later mistakes for one. That day is here (see below).
 *
 * TWO TRANSPORTS, ONE HANDLER (charter D225/D228)
 * ----------------------------------------------
 * Discord speaks over TWO inbound transports, and they are ADDITIVE, never an
 * XOR:
 *   - the GATEWAY WEBSOCKET carries DMs and mentions — no inbound URL at all
 *     (the {@link listen} socket, lease-owned across replicas);
 *   - an ED25519-SIGNED HTTP WEBHOOK carries slash-command interactions once the
 *     app's portal Interactions Endpoint URL is set.
 * This connector declares `webhook: { keySource: "path" }` so the generic HTTP
 * seam (D39) mounts `/connectors/webhooks/discord/:installKey` alongside the
 * socket. The vendor `DiscordAdapter.handleWebhook` already ships the ENTIRE
 * interaction protocol — raw-body Ed25519 verify, PING→PONG, the synchronous
 * type-5 deferred ack, and `waitUntil`-backgrounded dispatch — so the bridge adds
 * ZERO protocol code for slash commands and components; the wiring is the handler
 * registration in {@link mountInstall} (`chat.onSlashCommand`, `chat.onAction`,
 * `chat.onModalSubmit`). The ONE protocol gap the vendor has — MODAL_SUBMIT
 * (type 5) falls through its dispatch switch to 400 — is closed by
 * {@link extendDiscordInteractionWebhook} (W30). `keySource: "path"` because
 * Discord is BYO-bot (D41): each install has its OWN `publicKey`, so the body
 * must not choose the key that verifies the body. See
 * `connectors/docs/discord-byo-bot.md`.
 */

export const DISCORD_PROVIDER = "discord";

/**
 * One workspace's Discord credential, as stored in
 * `chat_bridge.connector_installs.credential_ref` (JSON).
 *
 * `applicationId` is the non-secret half and doubles as the install key, so the
 * routing table's PRIMARY KEY never holds a raw secret.
 */
export interface DiscordCredential {
  /** Discord Application ID. Non-secret. Also the install key. */
  applicationId: string;
  /** Bot token from the application's Bot tab. SECRET. */
  botToken: string;
  /** Ed25519 public key from the application's General Information tab. Non-secret. */
  publicKey: string;
}

const REQUIRED_FIELDS = ["applicationId", "botToken", "publicKey"] as const;

/**
 * Parse an install's `credential_ref` into a complete Discord credential.
 *
 * FAIL-CLOSED, by design: a missing or blank field THROWS rather than letting
 * the vendor's `?? process.env.DISCORD_*` fallback quietly substitute a
 * process-wide credential for a tenant's own (see the module note above).
 */
export function parseDiscordCredential(
  credentialRef: string | null | undefined,
): DiscordCredential {
  // Absent and null are the same nothing: `credentialRef` is optional in the TYPE
  // since D52 (absent = "leave the column alone" on the write path).
  if (
    credentialRef === null ||
    credentialRef === undefined ||
    credentialRef.trim() === ""
  ) {
    // NULL is a legitimate column state (Teams has no per-workspace credential,
    // D42) — but it is NOT legitimate for Discord, which is BYO-bot. Throw at
    // MOUNT rather than construct an adapter that would silently fall back to the
    // process-wide DISCORD_* environment and serve one tenant's bot to another.
    throw new Error(
      "Discord install has no credential_ref — Discord is BYO-bot (D41): every " +
        "workspace supplies its own Application id + bot token + public key. " +
        "Refusing to mount rather than fall back to the process-wide DISCORD_* env.",
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(credentialRef);
  } catch {
    throw new Error(
      "invalid Discord credential: expected JSON " +
        '{"applicationId":"…","botToken":"…","publicKey":"…"} — Discord needs all three ' +
        "(a bare bot token is not enough, and a missing field would fall back to the " +
        "process-wide DISCORD_* environment, serving one tenant's bot to another)",
    );
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(
      "invalid Discord credential: expected a JSON object with applicationId, botToken, publicKey",
    );
  }

  const record = parsed as Record<string, unknown>;
  const credential: Partial<DiscordCredential> = {};

  for (const field of REQUIRED_FIELDS) {
    const value = record[field];
    if (typeof value !== "string" || value.trim() === "") {
      throw new Error(
        `invalid Discord credential: "${field}" is required and must be a non-empty string. ` +
          "Barkpark refuses to fall back to the process environment for a tenant's credential.",
      );
    }
    credential[field] = value.trim();
  }

  return credential as DiscordCredential;
}

/**
 * The install key for a Discord credential: the Application ID.
 * Stable, non-secret, and the thing Discord stamps on everything the app sends.
 */
export function discordApplicationIdFromCredential(credentialRef: string): string {
  return parseDiscordCredential(credentialRef).applicationId;
}

/** Discord's REST API. `users/@me` is its cheapest authenticated call. */
const DISCORD_API_BASE = "https://discord.com/api/v10";

/** The slice of Discord's `GET /users/@me` response the connect flow reads. */
interface DiscordSelfUser {
  id?: string;
  username?: string;
  discriminator?: string;
  message?: string;
}

/**
 * PASTE-MODE VALIDATION (D51) — `GET /users/@me` with `Authorization: Bot <token>`.
 *
 * The credential is the JSON TRIPLE (D41), so validation is two steps: the shape
 * must parse (all three fields, no env fallback) and the BOT TOKEN half must
 * actually authenticate. Discord answers 401 `{"message":"401: Unauthorized"}` for
 * a revoked or mistyped token.
 *
 * The install key is the APPLICATION ID — and it is CROSS-CHECKED against the id
 * `users/@me` returns for the authenticated bot. Discord gives a bot user the SAME
 * snowflake as its application, so those two must agree, and DEMANDING that they do
 * is what makes the install key provider-authenticated rather than caller-chosen.
 *
 * That check is a TENANT BOUNDARY, not a nicety. An application id is PUBLIC — it
 * is in every bot's invite URL. Without the cross-check, a workspace-B admin could
 * paste `{"applicationId":"<workspace A's app id>","botToken":"<B's OWN valid
 * token>","publicKey":"…"}`: validation would pass (B's token really does
 * authenticate), the install key would be A's, and `upsertInstall`'s
 * `ON CONFLICT` would repoint A's row to workspace B — destroying A's install and
 * seizing its key, with no secret of A's ever changing hands. The route re-validates
 * server-side precisely so the key cannot be caller-chosen; taking it from an
 * UNVERIFIED field of the pasted blob handed that choice straight back.
 *
 * Honest gap, and it is Discord's, not ours: `users/@me` proves the token is live;
 * it does NOT prove the app has the MESSAGE CONTENT INTENT enabled. That is a
 * checkbox in the Developer Portal with no API to read it, and without it the bot
 * connects, appears healthy, and receives empty message bodies forever. Say so in
 * the UI (`connectors/docs/discord-byo-bot.md`); we cannot check it here.
 */
async function validateDiscordCredential(
  credential: string,
  doFetch: typeof fetch,
  apiBase: string,
): Promise<ConnectValidation> {
  let parsed: DiscordCredential;
  try {
    parsed = parseDiscordCredential(credential);
  } catch (error) {
    // parseDiscordCredential THROWS by design (it guards the mount path, where a
    // throw is the right answer). At paste time a bad shape is a typed refusal the
    // operator can act on, so the throw is converted, not propagated.
    return {
      ok: false,
      reason: error instanceof Error ? error.message : String(error),
    };
  }

  let response: Response;
  try {
    response = await doFetch(`${apiBase}/users/@me`, {
      method: "GET",
      headers: { authorization: `Bot ${parsed.botToken}` },
    });
  } catch (error) {
    return {
      ok: false,
      reason: `could not reach Discord to check the token: ${
        error instanceof Error ? error.message : String(error)
      }`,
    };
  }

  let payload: DiscordSelfUser;
  try {
    payload = (await response.json()) as DiscordSelfUser;
  } catch {
    return {
      ok: false,
      reason: `Discord answered HTTP ${response.status} with a body that is not JSON`,
    };
  }

  if (!response.ok) {
    return {
      ok: false,
      reason:
        payload.message ??
        `Discord rejected the bot token (HTTP ${response.status})`,
    };
  }

  // THE TENANT BOUNDARY (see the note above). The bot user's snowflake IS the
  // application's, so a pasted `applicationId` that does not match the token's own
  // bot is not a typo to be tolerated — it is the one input that would let a caller
  // choose another workspace's install key. Refuse, and say exactly what disagreed.
  if (typeof payload.id !== "string" || payload.id.trim() === "") {
    return {
      ok: false,
      reason:
        "Discord accepted the bot token but returned no bot id, so the applicationId " +
        "you pasted cannot be verified against it. Refusing to install an unverified key.",
    };
  }
  if (payload.id !== parsed.applicationId) {
    return {
      ok: false,
      reason:
        `that bot token belongs to application ${payload.id}, not to the ` +
        `applicationId you pasted (${parsed.applicationId}). Copy the Application ID ` +
        "from the SAME app you copied the bot token from.",
    };
  }

  return {
    ok: true,
    installKey: parsed.applicationId,
    displayName: payload.username
      ? `@${payload.username}`
      : `app ${parsed.applicationId}`,
  };
}

export interface DiscordConnectorOptions {
  /** Gateway supervisor tuning. Tests inject fake timers; production takes the defaults. */
  gateway?: GatewayTuning;
  /** Injected for `connect.validate` — tests NEVER hit the network. */
  fetch?: typeof fetch;
  /** Override the REST origin (tests point it at a local recorder). */
  apiBase?: string;
}

export function createDiscordConnector(
  options: DiscordConnectorOptions = {},
): Connector {
  const resolver = credentialBoundResolver();
  const doFetch = options.fetch ?? fetch;
  const apiBase = (options.apiBase ?? DISCORD_API_BASE).replace(/\/+$/, "");

  // One live Gateway per mounted adapter. Scoped to this connector instance, so
  // two registries in one test process never share listener state.
  const sessions = new Map<Adapter, GatewaySession>();

  return {
    id: DISCORD_PROVIDER,
    direction: "channel",
    auth: "token",
    // The bot token IS the tenant binding. A Discord message event carries a
    // guild id, but a guild does not own the bot — the APPLICATION does, and a
    // shared application would mean a shared credential (see the module note).
    tenantResolution: "credential-bound",

    // The additive HTTP interactions transport (D228). Slash commands arrive over
    // Discord's Ed25519-signed HTTP Interactions API, which rides the generic
    // webhook seam (D39): the demux (webhook-server → lookupInstall →
    // mounts.handlerFor → chat.webhooks.discord) serves it with ZERO seam changes,
    // and the vendor adapter already ships the whole protocol (raw-body Ed25519
    // verify, PING→PONG, type-5 deferred ack, waitUntil-backgrounded dispatch).
    // keySource:"path" because Discord is BYO-bot (D41) — every install has its
    // OWN publicKey, so the route is per-install (POST
    // /connectors/webhooks/discord/:installKey, the WhatsApp precedent) and the
    // body never chooses the key that verifies the body. ADDITIVE to the Gateway
    // socket (D225), never an XOR.
    webhook: { keySource: "path" },

    /**
     * BYO-bot paste (D41/D51). The credential is the JSON triple, not a bare
     * token — say that in the label, because pasting just the bot token is the
     * mistake every first-time operator makes, and the vendor's env fallback used
     * to turn it into a cross-tenant leak instead of an error.
     */
    connect: {
      mode: "paste",
      credentialLabel:
        'Discord credential JSON — {"applicationId":"…","botToken":"…","publicKey":"…"}',
      helpUrl: "https://discord.com/developers/applications",
      validate: (credential: string) =>
        validateDiscordCredential(credential, doFetch, apiBase),
    },

    /**
     * One adapter per INSTALL, built from THAT workspace's credential and
     * nothing else (D1). All three fields are passed explicitly, so the vendor's
     * `process.env.DISCORD_*` fallback can never fire.
     */
    adapterFactory(install: ConnectorInstall): DiscordAdapter {
      const credential = parseDiscordCredential(install.credentialRef);

      return createDiscordAdapter({
        applicationId: credential.applicationId,
        botToken: credential.botToken,
        publicKey: credential.publicKey,
      });
    },

    async resolveTenant(
      event: InboundEvent,
      ctx: TenantContext,
    ): Promise<string | null> {
      return resolver(event, ctx);
    },

    /**
     * Start the Gateway websocket.
     *
     * Resolves promptly — `startGatewayListener` hands its connection promise to
     * `waitUntil` and returns synchronously, so this never stalls the sequential
     * mount loop in `startBridge`. It THROWS if the gateway refuses (a 500 that
     * would otherwise look exactly like "nothing happened"), and the supervisor
     * re-arms the socket for the life of the process. See `gateway.ts` for the
     * three vendor traps this handles.
     *
     * Must run AFTER `chat.initialize()` — the adapter answers 500 "Chat instance
     * not initialized" otherwise. `startBridge` already orders it that way.
     *
     * SINGLE-OWNER ACROSS REPLICAS (charter D93/D94). A Gateway socket opened on
     * two replicas double-POSTs every reply, so `startBridge` does NOT call this at
     * boot — the install-lease coordinator does, only on the replica that holds the
     * install's lease. A standby stands by; on the owner's lapse it steals the lease
     * and calls this. `stopListening()` clears the session, so a lease regained
     * re-arms a FRESH socket (takeover), which the connector tests pin.
     */
    async listen(adapter: Adapter): Promise<void> {
      if (sessions.has(adapter)) return; // idempotent: never two sockets per bot

      const session = await startSupervisedGateway({
        provider: DISCORD_PROVIDER,
        adapter: adapter as DiscordAdapter,
        ...options.gateway,
      });

      sessions.set(adapter, session);
    },

    async stopListening(adapter: Adapter): Promise<void> {
      const session = sessions.get(adapter);
      if (!session) return;

      sessions.delete(adapter);
      await session.stop();
    },
  };
}

/* ────────────────────────────────────────────────────────────────────────────
 * COMPONENT + MODAL INTERACTIONS (charter W30) — the missing type-5 branch.
 *
 * The vendor `DiscordAdapter.handleWebhook` dispatch switch handles PING (1),
 * MESSAGE_COMPONENT (3, acked type-6 → `chat.processAction`) and
 * APPLICATION_COMMAND (2, acked type-5 → `chat.processSlashCommand`) — and then
 * falls through to 400 "Unknown interaction type" for everything else
 * (`@chat-adapter/discord/dist/index.js:907`). MODAL_SUBMIT (5) has NO branch,
 * so a modal submit is Ed25519-VERIFIED and then answered 400: registering
 * `chat.onModalSubmit` alone can never fix modals. This seam wraps
 * `chat.webhooks.discord` IN PLACE (the mount index re-reads that property per
 * request, so the wrap serves both the webhook-server path and the tests) and
 * adds exactly two things:
 *
 *   1. a MODAL_SUBMIT intercept AFTER the vendor answered — a 400 for a
 *      parseable type-5 body means the signature ALREADY VERIFIED (a bad
 *      signature returns 401 before the dispatch switch runs), so the intercept
 *      never handles an unverified payload and adds ZERO crypto of its own;
 *   2. an `onOpenModal` seam (the `WebhookOptions` hook Teams uses) so
 *      `event.openModal(...)` from a slash/action handler produces the real
 *      Discord type-9 modal callback POST instead of the vendor's silent
 *      "does not support modals" warning.
 *
 * HONEST CEILING, named: Discord accepts a modal ONLY as an interaction's FIRST
 * response, and the vendor auto-acks every interaction (type-5/type-6)
 * synchronously before dispatch runs. So live, the type-9 callback POST loses
 * the race to the ack and Discord answers 40060 "already acknowledged" — the
 * seam surfaces that as a warn + `undefined` (the SDK's "modals unavailable"
 * contract), never a silent success. Making the modal BE the HTTP response
 * requires holding the vendor ack, an ack-timing redesign filed as
 * `connectors-discord-modal-open-response` — NOT fake-proven here. The
 * submit-side routing below is transport-real either way: a user-submitted
 * modal arrives as its OWN signed interaction and round-trips fully.
 * ──────────────────────────────────────────────────────────────────────────── */

/** Discord interaction type 5 — MODAL_SUBMIT. */
const INTERACTION_MODAL_SUBMIT = 5;
/** Discord interaction CALLBACK type 5 — DeferredChannelMessageWithSource. */
const INTERACTION_CALLBACK_DEFERRED_MESSAGE = 5;
/** Discord interaction CALLBACK type 9 — respond with a MODAL. */
const INTERACTION_CALLBACK_MODAL = 9;

/** The slice of a Discord interaction payload the modal seam reads. */
interface DiscordInboundInteraction {
  type?: number;
  id?: string;
  token?: string;
  channel_id?: string;
  guild_id?: string;
  channel?: { type?: number; parent_id?: string };
  member?: { user?: DiscordInteractionUser };
  user?: DiscordInteractionUser;
  data?: { custom_id?: string; components?: unknown[] };
}

interface DiscordInteractionUser {
  id?: string;
  username?: string;
  global_name?: string;
  bot?: boolean;
}

/**
 * The minimum Chat shape the seam needs, declared structurally (the same idiom
 * as `http/mounts.ts`) so this module never couples to the `Chat` generic. A
 * real `Chat` satisfies it: `webhooks` is the per-adapter handler map and
 * `processModalSubmit` is the SDK's modal dispatch entry point.
 */
export interface DiscordInteractionChat {
  webhooks: Record<
    string,
    ((request: Request, options?: WebhookOptions) => Promise<Response>) | undefined
  >;
  processModalSubmit(
    event: {
      adapter: Adapter;
      callbackId: string;
      raw: unknown;
      user: Author;
      values: Record<string, string>;
      viewId: string;
    },
    contextId?: string,
    options?: WebhookOptions,
  ): Promise<unknown>;
}

/**
 * Encode the modal `custom_id` the bridge round-trips through Discord.
 *
 * JSON-encoded rather than joined on a separator — the `http/mounts.ts`
 * construction, for the same reason: no delimiter to collide on. Discord caps
 * `custom_id` at 100 chars; the contextId is a 36-char UUID, so callbackIds up
 * to ~55 chars fit. An oversized one is refused by Discord at open time and
 * surfaced by the `onOpenModal` warn — never silently truncated.
 */
export function encodeDiscordModalCustomId(
  callbackId: string,
  contextId: string,
): string {
  return JSON.stringify([callbackId, contextId]);
}

/**
 * Decode a modal `custom_id`. A foreign shape (a modal this bridge did not
 * open, or a pre-W30 hand-rolled one) degrades honestly: the WHOLE custom_id
 * becomes the callbackId and there is no contextId — the submit still routes,
 * it just has no stored relatedChannel to reply through.
 */
export function decodeDiscordModalCustomId(customId: string): {
  callbackId: string;
  contextId?: string;
} {
  try {
    const parsed: unknown = JSON.parse(customId);
    if (
      Array.isArray(parsed) &&
      typeof parsed[0] === "string" &&
      typeof parsed[1] === "string"
    ) {
      return { callbackId: parsed[0], contextId: parsed[1] };
    }
  } catch {
    // Not our encoding — fall through to the honest fallback.
  }
  return { callbackId: customId };
}

/**
 * Convert the SDK's `ModalElement` into Discord modal components.
 *
 * Discord modals accept ONLY text inputs (type 4 in type-1 action rows); every
 * other SDK modal child (select, radio, fields) has no Discord counterpart and
 * is skipped with a warn — a partial modal beats a silent 400 from Discord.
 */
function discordModalPayload(
  modal: ModalElement,
  customId: string,
): Record<string, unknown> {
  const rows: unknown[] = [];
  for (const child of modal.children) {
    if (child.type !== "text_input") {
      console.warn(
        `[discord] modal "${modal.callbackId}": dropping "${child.type}" child — ` +
          "Discord modals support text inputs only",
      );
      continue;
    }
    rows.push({
      type: 1,
      components: [
        {
          type: 4,
          custom_id: child.id,
          label: child.label,
          style: child.multiline ? 2 : 1,
          required: !child.optional,
          ...(child.placeholder ? { placeholder: child.placeholder } : {}),
          ...(child.initialValue ? { value: child.initialValue } : {}),
          ...(child.maxLength ? { max_length: child.maxLength } : {}),
        },
      ],
    });
  }
  return { custom_id: customId, title: modal.title, components: rows };
}

/**
 * Flatten a MODAL_SUBMIT payload's component tree into `{inputId: value}`.
 * Walks nested `components` arrays (type-1 action rows today, the newer label
 * wrappers tomorrow) and collects every leaf carrying `custom_id` + `value`.
 */
function modalSubmitValues(
  interaction: DiscordInboundInteraction,
): Record<string, string> {
  const values: Record<string, string> = {};
  const walk = (nodes: unknown[]): void => {
    for (const node of nodes) {
      if (!node || typeof node !== "object") continue;
      const rec = node as Record<string, unknown>;
      if (typeof rec.custom_id === "string" && typeof rec.value === "string") {
        values[rec.custom_id] = rec.value;
      }
      if (Array.isArray(rec.components)) walk(rec.components);
      if (rec.component && typeof rec.component === "object") {
        walk([rec.component]);
      }
    }
  };
  const rows = interaction.data?.components;
  if (Array.isArray(rows)) walk(rows);
  return values;
}

/**
 * The vendor's namespaced thread id for the channel a modal submit came from —
 * `encodeThreadId` (PUBLIC on `DiscordAdapter`) with the exact thread-channel
 * handling `handleComponentInteraction` uses, so the ALS reply route and any
 * stored relatedChannel agree on the id byte-for-byte.
 */
function namespacedChannelId(
  adapter: DiscordAdapter,
  interaction: DiscordInboundInteraction,
): string | undefined {
  const interactionChannelId = interaction.channel_id;
  if (typeof interactionChannelId !== "string" || interactionChannelId === "") {
    return undefined;
  }
  const guildId =
    typeof interaction.guild_id === "string" && interaction.guild_id !== ""
      ? interaction.guild_id
      : "@me";
  const channel = interaction.channel;
  const isThread = channel?.type === 11 || channel?.type === 12;
  const parentChannelId =
    isThread && typeof channel?.parent_id === "string"
      ? channel.parent_id
      : interactionChannelId;
  return isThread
    ? adapter.encodeThreadId({
        guildId,
        channelId: parentChannelId,
        threadId: interactionChannelId,
      })
    : adapter.encodeThreadId({ guildId, channelId: interactionChannelId });
}

/**
 * Route one VERIFIED MODAL_SUBMIT into `chat.processModalSubmit`, mirroring the
 * vendor's own dispatch pattern byte-for-byte in shape:
 *
 *   - the dispatch task rides `options.waitUntil` and the type-5 deferred ack
 *     returns synchronously (webhook-server rule 2, D230);
 *   - dispatch runs INSIDE `adapter.requestContext.run({slashCommand: …})` —
 *     the SAME AsyncLocalStorage store `handleApplicationCommandInteraction`
 *     uses — so a handler replying via the related channel PATCHes
 *     `/webhooks/{appId}/{token}/messages/@original` on the SUBMIT's own token
 *     and the deferred ack never dangles as "did not respond". The store is
 *     `protected` on the vendor class (runtime-real, tsc-hidden), so the ONE
 *     cast lives here with this note; pinned to @chat-adapter/discord@4.34.0.
 *
 * Returns undefined (caller keeps the vendor 400) when the payload lacks the
 * pieces routing needs — custom_id and a user.
 */
function dispatchDiscordModalSubmit(
  chat: DiscordInteractionChat,
  adapter: DiscordAdapter,
  interaction: DiscordInboundInteraction,
  options: WebhookOptions | undefined,
): Response | undefined {
  const customId = interaction.data?.custom_id;
  const user = interaction.member?.user ?? interaction.user;
  if (
    typeof customId !== "string" ||
    customId === "" ||
    typeof user?.id !== "string" ||
    typeof user.username !== "string" ||
    typeof interaction.token !== "string"
  ) {
    return undefined;
  }

  const { callbackId, contextId } = decodeDiscordModalCustomId(customId);
  const event = {
    adapter: adapter as Adapter,
    callbackId,
    raw: interaction,
    user: {
      userId: user.id,
      userName: user.username,
      fullName: user.global_name || user.username,
      isBot: user.bot ?? false,
      isMe: false,
    },
    values: modalSubmitValues(interaction),
    viewId: customId,
  };

  const channelId = namespacedChannelId(adapter, interaction);
  const requestContext = (
    adapter as unknown as {
      requestContext: { run<T>(store: unknown, fn: () => T): T };
    }
  ).requestContext;
  const interactionToken = interaction.token;

  const task = channelId
    ? requestContext.run(
        {
          slashCommand: {
            channelId,
            interactionToken,
            initialResponseSent: false,
          },
        },
        () => chat.processModalSubmit(event, contextId, options),
      )
    : chat.processModalSubmit(event, contextId, options);

  const tracked = task.catch((err) => {
    console.error(`[discord] modal submit "${callbackId}" dispatch failed:`, err);
  });
  options?.waitUntil?.(tracked);

  return Response.json({ type: INTERACTION_CALLBACK_DEFERRED_MESSAGE });
}

/**
 * Inject the `onOpenModal` seam so `event.openModal(...)` works on Discord.
 * A caller-supplied hook wins; without an interaction id + token there is no
 * callback endpoint to POST to, so the options pass through untouched.
 */
function withDiscordOpenModal(
  options: WebhookOptions | undefined,
  interaction: DiscordInboundInteraction | undefined,
): WebhookOptions | undefined {
  if (
    options?.onOpenModal ||
    typeof interaction?.id !== "string" ||
    typeof interaction.token !== "string"
  ) {
    return options;
  }
  const { id, token } = interaction;
  return {
    ...options,
    onOpenModal: async (modal, contextId) => {
      const customId = encodeDiscordModalCustomId(modal.callbackId, contextId);
      // Bare GLOBAL fetch + hardcoded DISCORD_API_BASE — deliberately the
      // vendor's own idiom (D229 law d), so offline tests stub ONE seam.
      const res = await fetch(
        `${DISCORD_API_BASE}/interactions/${id}/${token}/callback`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            type: INTERACTION_CALLBACK_MODAL,
            data: discordModalPayload(modal, customId),
          }),
        },
      );
      if (!res.ok) {
        console.warn(
          `[discord] modal "${modal.callbackId}" open refused (HTTP ${res.status}) — ` +
            "Discord accepts a modal only as an interaction's FIRST response and " +
            "the vendor adapter auto-acks before dispatch (see the W30 seam note); " +
            "the modal was NOT shown",
        );
        return undefined;
      }
      return { viewId: customId };
    },
  };
}

/**
 * Wrap `chat.webhooks.discord` in place with the component/modal seam.
 *
 * Call once per mounted install, right after the `Chat` is constructed. A Chat
 * with no `discord` webhook (every other provider) is a NO-OP, so the caller
 * stays provider-generic. The wrapper:
 *
 *   - forwards the vendor a byte-identical request (Ed25519 signs the RAW body,
 *     so the bytes are read once and re-sent verbatim);
 *   - injects the `onOpenModal` seam ({@link withDiscordOpenModal});
 *   - intercepts the vendor's 400 for a VERIFIED type-5 MODAL_SUBMIT and routes
 *     it ({@link dispatchDiscordModalSubmit}); every other response — 200 acks,
 *     401 bad signature, 400 bad JSON — passes through untouched.
 */
export function extendDiscordInteractionWebhook(
  chat: DiscordInteractionChat,
  adapter: Adapter,
): void {
  const vendor = chat.webhooks[DISCORD_PROVIDER];
  if (!vendor) return;
  const discord = adapter as DiscordAdapter;

  chat.webhooks[DISCORD_PROVIDER] = async (request, options) => {
    // No body to sign or parse — hand straight through (the route is POST-only,
    // but a wrapper must never turn a stray GET into a hang on .arrayBuffer()).
    if (request.method === "GET" || request.method === "HEAD") {
      return vendor(request, options);
    }

    const bytes = await request.arrayBuffer();
    const forwarded = new Request(request.url, {
      method: request.method,
      headers: request.headers,
      body: bytes,
    });

    let interaction: DiscordInboundInteraction | undefined;
    try {
      const parsed: unknown = JSON.parse(new TextDecoder().decode(bytes));
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        interaction = parsed as DiscordInboundInteraction;
      }
    } catch {
      // Unparseable body: the vendor answers 400 "Invalid JSON" — pass through.
    }

    const extended = withDiscordOpenModal(options, interaction);
    const response = await vendor(forwarded, extended);

    if (response.status !== 400 || interaction?.type !== INTERACTION_MODAL_SUBMIT) {
      return response;
    }
    // A 400 for a parseable type-5 body is the vendor's "Unknown interaction
    // type" fall-through — REACHED ONLY AFTER Ed25519 verify passed (a bad
    // signature short-circuits to 401 before the dispatch switch).
    return (
      dispatchDiscordModalSubmit(chat, discord, interaction, extended) ?? response
    );
  };
}
