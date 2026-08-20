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
 * Why `polling`, and ONLY polling: getUpdates needs no public URL, so the smoke
 * runs on a laptop with no tunnel. Webhook transport is not wired — the connector
 * never registers a route and never calls setWebhook, so a webhook-configured bot
 * would silently drop all traffic. Polling is the only transport this connector
 * has (a future webhook wire is backlog connectors-telegram-webhook-wire).
 */

export const TELEGRAM_PROVIDER = "telegram";

/** Telegram's Bot API. `getMe` is the cheapest authenticated call it has. */
const TELEGRAM_API_BASE = "https://api.telegram.org";

/**
 * THE POLL WATCHDOG (charter D84) — a Barkpark-owned supervisor around the
 * vendor's getUpdates loop.
 *
 * WHY TELEGRAM CANNOT COPY DISCORD'S `startSupervisedGateway` VERBATIM
 * -------------------------------------------------------------------
 * The Discord supervisor RACES a connection promise: `waitUntil` hands it the
 * long-lived socket promise, and the promise SETTLING is the "window ended"
 * signal it re-arms on. `@chat-adapter/telegram` exposes no such promise and no
 * event: `pollingTask` is `private`, and the ONLY public health signal is the
 * `isPolling` boolean getter (`isPolling(): boolean`, backed by `pollingActive`).
 * So the shape here is a HEALTH-CHECK INTERVAL that reads `isPolling`, not a
 * promise race — but it re-uses the SAME backoff vocabulary
 * (`minBackoffMs`/`maxBackoffMs`/`healthyAfterMs`) so the two supervisors read
 * as one family.
 *
 * TWO FAILURE MODES THIS EXISTS TO SURVIVE, both proven against the vendor:
 *
 *   (1) THE SILENT SETTLE. `startPolling()` runs `this.pollingLoop(...).finally(
 *       () => { this.pollingActive = false; ... })`. The loop self-heals per
 *       iteration (try/catch + capped backoff), but if it EVER returns — a bug,
 *       an exhausted retry, an unhandled path — `pollingActive` flips to false
 *       and `isPolling` silently reads false forever. Nothing re-arms it: the
 *       bot goes quiet with no error. The interval health-check catches exactly
 *       this and calls `startPolling()` again.
 *
 *   (2) THE SYNCHRONOUS MOUNT THROW. `startPolling()` can throw AT MOUNT: if
 *       `resetWebhook()` (the `deleteWebhook` call) rejects, the vendor sets
 *       `pollingActive = false` and RETHROWS (index.js:1047-1051). Before this
 *       watchdog that rethrow permanently failed the install with ZERO retry —
 *       one transient Telegram 5xx at boot and the bot never polled again. The
 *       supervisor wraps the initial arm in the same bounded backoff, so a
 *       transient mount failure retries instead of bricking the install.
 *
 * DISARM ON STOP (charter D84c): `stop()` aborts the supervisor's own
 * `AbortController` and awaits the loop's wind-down BEFORE the caller stops the
 * vendor loop — so the health-check never observes the deliberate
 * `isPolling === false` and re-arms a bot the operator just took down. No zombie
 * re-arm after `stopListening`.
 */

/** Node's default first re-arm delay after a poll that died fast (1s). */
const DEFAULT_MIN_BACKOFF_MS = 1_000;
/** Backoff ceiling — a bad token must never hot-loop against Telegram (60s). */
const DEFAULT_MAX_BACKOFF_MS = 60_000;
/** A poll that stayed up at least this long resets the backoff (30s). */
const DEFAULT_HEALTHY_AFTER_MS = 30_000;
/**
 * How often the watchdog reads `isPolling`. This is the poll-specific knob the
 * Gateway supervisor does not need (it races a promise instead). 15s is well
 * under any human's "why is my bot quiet?" patience and far above a busy-poll.
 */
const DEFAULT_HEALTH_CHECK_INTERVAL_MS = 15_000;

/**
 * The slice of `TelegramAdapter` the watchdog drives — only the PUBLIC polling
 * surface (charter D84: "hook only the public isPolling/startPolling/stopPolling
 * surface; no vendor fork"). `pollingTask`/`pollingActive`/`pollingLoop` are all
 * `private` and deliberately untouched.
 */
export interface SupervisedPoller {
  readonly isPolling: boolean;
  startPolling(): Promise<void>;
  stopPolling(): Promise<void>;
}

/**
 * Watchdog tuning. Shares `minBackoffMs`/`maxBackoffMs`/`healthyAfterMs` with the
 * Gateway supervisor by design; adds `healthCheckIntervalMs` because a boolean
 * getter must be POLLED where a promise is AWAITED. `sleep`/`now` are injectable
 * so tests use fake time and assert on the backoff schedule and arm count with
 * no real timers.
 */
export interface TelegramPollTuning {
  /** First re-arm delay after a poll that died fast. Default 1s. */
  minBackoffMs?: number;
  /** Backoff ceiling. Default 60s. */
  maxBackoffMs?: number;
  /** A poll that survived at least this long resets the backoff. Default 30s. */
  healthyAfterMs?: number;
  /** How often `isPolling` is read for the silent-settle check. Default 15s. */
  healthCheckIntervalMs?: number;
  log?: (message: string, error?: unknown) => void;
  /** Injectable for tests — resolves early when the signal aborts. */
  sleep?: (ms: number, signal: AbortSignal) => Promise<void>;
  now?: () => number;
}

export interface TelegramPollSupervisorOptions extends TelegramPollTuning {
  provider: string;
  adapter: SupervisedPoller;
}

/** The running watchdog. Mirrors `GatewaySession` so ops reads one shape. */
export interface PollSession {
  /** Resolves when the supervisor loop has fully stopped. */
  readonly done: Promise<void>;
  /** How many times `startPolling()` has been invoked (1 = the boot arm). */
  readonly arms: () => number;
  /** Disarm the watchdog and wait for the supervisor loop to wind down. */
  stop(): Promise<void>;
}

/** A sleep that gives up the moment the signal aborts, so shutdown is prompt. */
function abortablePollSleep(ms: number, signal: AbortSignal): Promise<void> {
  if (ms <= 0 || signal.aborted) return Promise.resolve();

  return new Promise<void>((resolve) => {
    const finish = (): void => {
      clearTimeout(timer);
      signal.removeEventListener("abort", finish);
      resolve();
    };
    const timer = setTimeout(finish, ms);
    signal.addEventListener("abort", finish, { once: true });
  });
}

function defaultPollLog(message: string, error?: unknown): void {
  if (error === undefined) console.log(message);
  else console.error(message, error);
}

/**
 * Start the getUpdates poll loop and keep it polling for the life of the process.
 *
 * The FIRST arm is awaited so a clean mount is already polling when this resolves
 * — but a THROW from that first `startPolling()` is CAUGHT, never rethrown: a
 * transient `resetWebhook` failure at mount must retry (see failure mode 2), not
 * brick the install. Returns promptly regardless, so the sequential mount loop in
 * `startBridge` keeps moving; the retry and health-check both run in the
 * background loop.
 */
export async function startSupervisedPolling(
  options: TelegramPollSupervisorOptions,
): Promise<PollSession> {
  const {
    provider,
    adapter,
    minBackoffMs = DEFAULT_MIN_BACKOFF_MS,
    maxBackoffMs = DEFAULT_MAX_BACKOFF_MS,
    healthyAfterMs = DEFAULT_HEALTHY_AFTER_MS,
    healthCheckIntervalMs = DEFAULT_HEALTH_CHECK_INTERVAL_MS,
    log = defaultPollLog,
    sleep = abortablePollSleep,
    now = Date.now,
  } = options;

  const controller = new AbortController();
  const signal = controller.signal;
  let armCount = 0;
  let consecutiveFailures = 0;
  let armStartedAt = 0;

  /**
   * One `startPolling()` attempt. Returns true if the bot is now polling. A
   * throw is CAUGHT (not propagated): the vendor sets `pollingActive = false`
   * and rethrows on a `resetWebhook` failure, and before this watchdog that
   * rethrow permanently failed the install. Here it just bumps the failure count
   * so the caller backs off and retries.
   */
  const arm = async (): Promise<boolean> => {
    armCount += 1;
    try {
      await adapter.startPolling();
    } catch (error) {
      consecutiveFailures += 1;
      log(
        `[${provider}] startPolling failed (${consecutiveFailures} in a row) — ` +
          "watchdog will retry with backoff",
        error,
      );
      return false;
    }
    armStartedAt = now();
    return true;
  };

  // The FIRST arm is awaited — but its throw is swallowed (see the doc above).
  await arm();

  const loop = (async (): Promise<void> => {
    for (;;) {
      if (signal.aborted) return;

      // (RE-)ARM when the bot is not polling: either the initial arm threw, or a
      // previous window settled silently. Back off in proportion to how many
      // times in a row we have failed, so a persistently-bad token cannot spin.
      if (!adapter.isPolling) {
        const delay =
          consecutiveFailures === 0
            ? 0
            : Math.min(maxBackoffMs, minBackoffMs * 2 ** (consecutiveFailures - 1));
        await sleep(delay, signal);
        if (signal.aborted) return;

        const armed = await arm();
        if (!armed) continue; // still down — next pass backs off further
      }

      // HEALTH CHECK. There is no promise to await, so we sleep one interval and
      // then read the only public health signal the adapter exposes.
      await sleep(healthCheckIntervalMs, signal);
      if (signal.aborted) return;

      if (adapter.isPolling) {
        // Survived the interval. If it has been up long enough, clear the
        // backoff so the next unexpected settle re-arms immediately.
        if (now() - armStartedAt >= healthyAfterMs) consecutiveFailures = 0;
        continue;
      }

      // THE SILENT SETTLE. `isPolling` went false with no stop() from us — the
      // vendor loop ended on its own. Measure how long it lasted to decide the
      // backoff, then loop back to the re-arm branch.
      const lasted = now() - armStartedAt;
      consecutiveFailures = lasted >= healthyAfterMs ? 0 : consecutiveFailures + 1;
      log(
        `[${provider}] polling stopped unexpectedly after ${lasted}ms — re-arming`,
      );
    }
  })();

  return {
    done: loop,
    arms: () => armCount,
    async stop(): Promise<void> {
      controller.abort();
      await loop;
    },
  };
}

export interface TelegramConnectorOptions {
  /**
   * Transport. Polling is the ONLY value: getUpdates long-polling needs no
   * public URL. The former `"webhook"` and `"auto"` members were removed — a
   * webhook-configured bot silently dropped all traffic (no route was ever
   * mounted, setWebhook was never called), and the vendor's `"auto"` can select
   * that dead webhook path. The field is retained (single-valued) so existing
   * `{ mode: "polling" }` call sites stay explicit; it has no other effect.
   */
  mode?: "polling";
  /** Injected for `connect.validate` — tests NEVER hit the network. */
  fetch?: typeof fetch;
  /** Override the Bot API origin (tests point it at a local recorder). */
  apiBase?: string;
  /** Poll-watchdog tuning. Tests inject fake time; production takes defaults. */
  polling?: TelegramPollTuning;
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
  const resolver = credentialBoundResolver();
  // Bound at construction, not read from the global at call time: a test that
  // injects a fetch must be certain no code path can reach the real network.
  const doFetch = options.fetch ?? fetch;
  const apiBase = (options.apiBase ?? TELEGRAM_API_BASE).replace(/\/+$/, "");

  // One watchdog per mounted adapter. Scoped to this connector instance so two
  // registries in one test process never share supervisor state (mirrors the
  // Discord connector's per-instance `sessions` map).
  const sessions = new Map<Adapter, PollSession>();

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
        // Force polling. The vendor default is `"auto"`, which can select the
        // webhook path — but this connector never mounts a webhook route, so
        // "auto" would silently strand the bot. Polling is the only transport.
        mode: "polling",
      });
    },

    async resolveTenant(
      event: InboundEvent,
      ctx: TenantContext,
    ): Promise<string | null> {
      return resolver(event, ctx);
    },

    /**
     * getUpdates long-polling under a Barkpark-owned watchdog (D84). No public
     * URL, so the smoke runs on a laptop. Polling is the only transport, so every
     * mounted install starts a poll — there is no no-op transport arm.
     *
     * The watchdog survives BOTH a silent settle (the vendor loop ending on its
     * own → `isPolling` false with no error) and a synchronous mount throw (a
     * `resetWebhook` failure that, before this, permanently failed the install).
     * Idempotent: a second listen() never opens a second watchdog for one bot.
     *
     * SINGLE-OWNER ACROSS REPLICAS (charter D93/D94). A second getUpdates poll on
     * one bot token is a hard Telegram 409 Conflict, so `startBridge` does NOT call
     * this at boot — the install-lease coordinator does, only on the replica that
     * holds the install's lease. A standby stands by; on the owner's lapse it steals
     * the lease and calls this. `stopListening()` clears the session, so a lease
     * regained re-arms a FRESH poll (takeover), which the connector tests pin.
     */
    async listen(adapter: Adapter): Promise<void> {
      if (sessions.has(adapter)) return; // idempotent: one watchdog per bot

      const session = await startSupervisedPolling({
        provider: TELEGRAM_PROVIDER,
        adapter: adapter as TelegramAdapter,
        ...options.polling,
      });

      sessions.set(adapter, session);
    },

    /**
     * Take the bot down cleanly. DISARM FIRST (D84c): stop the watchdog and wait
     * for its loop to wind down BEFORE stopping the vendor poll loop, so the
     * health-check never observes the deliberate `isPolling === false` and
     * re-arms a bot the operator just took down — no zombie re-arm. The direct
     * `stopPolling()` still runs when there is no session (an adapter never handed
     * to listen()), preserving the pre-watchdog behaviour.
     */
    async stopListening(adapter: Adapter): Promise<void> {
      const session = sessions.get(adapter);
      if (session) {
        sessions.delete(adapter);
        await session.stop();
      }

      const telegram = adapter as TelegramAdapter;
      if (telegram.isPolling) await telegram.stopPolling();
    },
  };
}
