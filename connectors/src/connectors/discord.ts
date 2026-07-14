import { createDiscordAdapter, type DiscordAdapter } from "@chat-adapter/discord";
import type { Adapter } from "chat";

import type {
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
export function parseDiscordCredential(credentialRef: string): DiscordCredential {
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

export interface DiscordConnectorOptions {
  /** Gateway supervisor tuning. Tests inject fake timers; production takes the defaults. */
  gateway?: GatewayTuning;
}

export function createDiscordConnector(
  options: DiscordConnectorOptions = {},
): Connector {
  const resolver = credentialBoundResolver();

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
