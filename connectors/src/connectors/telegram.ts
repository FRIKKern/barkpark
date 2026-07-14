import {
  createTelegramAdapter,
  type TelegramAdapter,
} from "@chat-adapter/telegram";
import type { Adapter } from "chat";

import type {
  Connector,
  ConnectorInstall,
  InboundEvent,
  TenantContext,
} from "../connector/types.js";
import { credentialBoundResolver } from "../tenant/resolve.js";

/**
 * Telegram — the first channel Connector (charter D3/D29/D30).
 *
 * It is here as the LIGHTEST channel to prove the core, not as a special case:
 * everything below is the generic Connector shape. A P3 channel (Slack,
 * Discord, ...) is the same declaration with a different `adapterFactory` and
 * possibly `tenantResolution: "payload-team-id"` — and NO change to
 * core/dispatch.
 *
 * Why `credential-bound` (D29): a Telegram update carries no team/org/tenant
 * field of any kind. The only thing that identifies the tenant is WHICH BOT
 * received the message. So the bot is the tenant binding, resolved before the
 * payload is even looked at. BYO-bot: each workspace registers its own
 * BotFather token.
 *
 * Why `polling` by default: getUpdates needs no public URL, so the smoke runs
 * on a laptop with no tunnel. Webhook mode is the same connector with
 * `mode: "webhook"` — a config value, not a code path.
 */

export const TELEGRAM_PROVIDER = "telegram";

export interface TelegramConnectorOptions {
  /** getUpdates long-polling (default) needs no public URL. */
  mode?: "polling" | "webhook" | "auto";
}

/**
 * A Telegram bot token is `<bot_id>:<secret>`. The bot id is the stable,
 * non-secret half — it is the install key in `connector_installs`, so the
 * routing table never stores a raw secret as its primary key.
 */
export function telegramBotIdFromToken(botToken: string): string {
  const botId = botToken.split(":")[0]?.trim();
  if (!botId) {
    throw new Error('invalid Telegram bot token: expected "<bot_id>:<secret>"');
  }
  return botId;
}

export function createTelegramConnector(
  options: TelegramConnectorOptions = {},
): Connector {
  const mode = options.mode ?? "polling";
  const resolver = credentialBoundResolver();

  return {
    id: TELEGRAM_PROVIDER,
    direction: "channel",
    auth: "token",
    tenantResolution: "credential-bound",

    /**
     * One adapter per INSTALL — built from that workspace's own bot token.
     * Per-workspace credential isolation (D1) is structural: a tenant's
     * adapter is constructed from that tenant's credential and nothing else.
     *
     * `credentialRef` is nullable at the type level because Teams has no
     * per-workspace secret (D42). Telegram DOES: a credential-bound connector
     * whose credential is missing has no tenant binding at all, so it fails
     * LOUDLY here at mount rather than constructing an adapter that would fall
     * back to a `TELEGRAM_BOT_TOKEN` env var — i.e. to the operator's bot, in
     * another workspace's name.
     */
    adapterFactory(install: ConnectorInstall): TelegramAdapter {
      const botToken = install.credentialRef;
      if (botToken === null || botToken.trim() === "") {
        throw new Error(
          `telegram: install "${install.installKey}" (workspace ${install.workspaceId}) ` +
            "has no credential_ref — Telegram is bring-your-own-bot and the bot token " +
            "IS the tenant binding (D29). Refusing to mount.",
        );
      }
      return createTelegramAdapter({
        botToken,
        mode,
      });
    },

    async resolveTenant(
      event: InboundEvent,
      ctx: TenantContext,
    ): Promise<string | null> {
      return resolver(event, ctx);
    },

    /**
     * getUpdates long-polling. No public URL, so the smoke runs on a laptop.
     * In webhook mode the transport is the HTTP request, so there is nothing
     * to start.
     */
    async listen(adapter: Adapter): Promise<void> {
      if (mode === "webhook") return;
      const telegram = adapter as TelegramAdapter;
      if (!telegram.isPolling) await telegram.startPolling();
    },

    async stopListening(adapter: Adapter): Promise<void> {
      const telegram = adapter as TelegramAdapter;
      if (telegram.isPolling) await telegram.stopPolling();
    },
  };
}
