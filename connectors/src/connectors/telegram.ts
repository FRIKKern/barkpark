import {
  createTelegramAdapter,
  type TelegramAdapter,
} from "@chat-adapter/telegram";
import type { Adapter } from "chat";

import type {
  ConnectValidation,
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

/** Telegram's Bot API. `getMe` is the cheapest authenticated call it has. */
const TELEGRAM_API_BASE = "https://api.telegram.org";

export interface TelegramConnectorOptions {
  /** getUpdates long-polling (default) needs no public URL. */
  mode?: "polling" | "webhook" | "auto";
  /** Injected for `connect.validate` — tests NEVER hit the network. */
  fetch?: typeof fetch;
  /** Override the Bot API origin (tests point it at a local recorder). */
  apiBase?: string;
}

/** The slice of Telegram's `getMe` response the connect flow reads. */
interface TelegramGetMe {
  ok?: boolean;
  description?: string;
  result?: { id?: number; username?: string; first_name?: string };
}

/**
 * PASTE-MODE VALIDATION (D51) — `GET /bot<token>/getMe`.
 *
 * The credential is the whole of what Telegram needs, so "is this token good?" is
 * one authenticated round trip. It answers 401 `{"ok":false,"description":
 * "Unauthorized"}` for a revoked or mistyped token, which is precisely the failure
 * we want to surface AT PASTE TIME rather than at the next restart (D53) — where it
 * would throw out of `chat.initialize()` and, before this wave, crash-loop the unit.
 *
 * Nothing is written here, and the token is never logged. Every failure is a TYPED
 * refusal, not a throw: a bad paste is a 422 with a reason a human can act on, not
 * a 500.
 */
async function validateTelegramToken(
  botToken: string,
  doFetch: typeof fetch,
  apiBase: string,
): Promise<ConnectValidation> {
  // Shape first: `<digits>:<secret>`. A bare word is not a token, and asking
  // Telegram about it is a round trip we can spend on nothing. The shape check
  // now lives in `telegramBotIdFromToken` itself, which throws on anything that
  // is not `<digits>:<secret>` — so there is ONE guard, not a regex here kept in
  // lockstep with the parser. A malformed paste is caught while deriving the bot
  // id and surfaced as the same human-readable refusal, never a raw stack trace.
  let botId: string;
  try {
    botId = telegramBotIdFromToken(botToken);
  } catch {
    return {
      ok: false,
      reason:
        'that does not look like a Telegram bot token — @BotFather issues them as "<bot_id>:<secret>", e.g. 123456789:AAE…',
    };
  }

  let response: Response;
  try {
    response = await doFetch(`${apiBase}/bot${botToken}/getMe`, { method: "GET" });
  } catch (error) {
    // Telegram unreachable is NOT "your token is bad" — say which, or the operator
    // re-pastes a perfectly good token five times.
    return {
      ok: false,
      reason: `could not reach Telegram to check the token: ${
        error instanceof Error ? error.message : String(error)
      }`,
    };
  }

  let payload: TelegramGetMe;
  try {
    payload = (await response.json()) as TelegramGetMe;
  } catch {
    return {
      ok: false,
      reason: `Telegram answered HTTP ${response.status} with a body that is not JSON`,
    };
  }

  if (!response.ok || payload.ok !== true || !payload.result) {
    return {
      ok: false,
      reason:
        payload.description ??
        `Telegram rejected the token (HTTP ${response.status})`,
    };
  }

  const username = payload.result.username;
  return {
    ok: true,
    // The BOT ID from the token — not `result.id` — because the bot id is what the
    // install key must be for `credential-bound` routing to work, and it is the
    // half of the token we can derive without trusting the response body.
    installKey: botId,
    displayName: username
      ? `@${username}`
      : (payload.result.first_name ?? `bot ${botId}`),
  };
}

/**
 * A Telegram bot token is `<bot_id>:<secret>`. The bot id is the stable,
 * non-secret half — it is the install key in `connector_installs`, so the
 * routing table never stores a raw secret as its primary key.
 *
 * The shape is enforced HERE, not by a separate regex at the call site
 * (connectors-telegram-token-shape-guard): the bot id must be digits and there
 * must be a secret. `telegramBotIdFromToken("not-a-token")` and `("abc:secret")`
 * both throw, so a paste error cannot slip past as a "valid" install key and
 * then fail only at the first poll (D53). Callers that surface this to a human
 * (connect.validate) catch the throw and turn it into a typed refusal.
 */
export function telegramBotIdFromToken(botToken: string): string {
  const match = /^(\d+):.+$/.exec(botToken.trim());
  if (!match) {
    throw new Error(
      'invalid Telegram bot token: expected "<bot_id>:<secret>" where <bot_id> is digits',
    );
  }
  return match[1] as string;
}

export function createTelegramConnector(
  options: TelegramConnectorOptions = {},
): Connector {
  const mode = options.mode ?? "polling";
  const resolver = credentialBoundResolver();
  // Bound at construction, not read from the global at call time: a test that
  // injects a fetch must be certain no code path can reach the real network.
  const doFetch = options.fetch ?? fetch;
  const apiBase = (options.apiBase ?? TELEGRAM_API_BASE).replace(/\/+$/, "");

  return {
    id: TELEGRAM_PROVIDER,
    direction: "channel",
    auth: "token",
    tenantResolution: "credential-bound",

    /**
     * Two-minute onboarding (D51): the operator pastes the BotFather token and
     * that is the entire credential. No OAuth app, no admin consent, no public URL.
     */
    connect: {
      mode: "paste",
      credentialLabel: "Bot token from @BotFather",
      helpUrl: "https://core.telegram.org/bots/features#botfather",
      validate: (credential: string) =>
        validateTelegramToken(credential, doFetch, apiBase),
    },

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
      // `credentialRef` is optional in the TYPE since D52 (absent = "don't touch
      // this column" on the write path), so absent and null are both "no
      // credential" here — and for a credential-bound connector that is fatal.
      const botToken = install.credentialRef;
      if (!botToken || botToken.trim() === "") {
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
