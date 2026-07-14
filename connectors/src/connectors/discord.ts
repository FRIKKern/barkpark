import { createDiscordAdapter, type DiscordAdapter } from "@chat-adapter/discord";
import type { Adapter } from "chat";

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
 * `publicKey` is only used to verify Ed25519 webhook signatures, which v1 does
 * not use (Gateway-only). It is still required, not defaulted: the day
 * `connectors-discord-slash-commands` lands, every existing install already
 * carries a REAL key — rather than a sentinel someone later mistakes for one.
 *
 * WHY GATEWAY-ONLY IN V1
 * ----------------------
 * Slash commands need Discord's Ed25519-signed HTTP interaction endpoint (a
 * public URL + `publicKey` verification). That is a webhook seam this slice
 * deliberately does not depend on. Filed as `connectors-discord-slash-commands`.
 * DMs and mentions — everything the turn loop needs — arrive over the Gateway
 * websocket, which needs no inbound URL at all.
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
