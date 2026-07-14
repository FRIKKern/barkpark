import {
  createSlackAdapter,
  type SlackAdapter,
  type SlackInstallation,
} from "@chat-adapter/slack";
import { readSlackWebhook } from "@chat-adapter/slack/webhook";

import type {
  Connector,
  ConnectorInstall,
  InboundEvent,
  InstallsLookup,
  TenantContext,
  WorkspaceId,
} from "../connector/types.js";
import { createPayloadTeamIdResolver } from "../tenant/resolve.js";

/**
 * Slack — the `payload-team-id` channel (charter D3/D29/D30/D40).
 *
 * Telegram proved `credential-bound` routing; Slack proves the OTHER strategy on
 * the SAME core. Nothing in `core/dispatch.ts`, `tenant/resolve.ts`,
 * `connector/registry.ts` or `turn/` changes to land it — that zero-core-change
 * diff IS this wave's acceptance bar.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * SOCKET MODE IS DISQUALIFIED, AND IT FAILS SILENTLY
 * ─────────────────────────────────────────────────────────────────────────────
 * `createSlackAdapter({ mode: "socket", clientId, clientSecret })` throws
 * ("Multi-workspace (clientId/clientSecret) is not supported in socket mode").
 * But that guard does NOT look at `installationProvider` — so
 * `{ mode: "socket", installationProvider, botToken }` CONSTRUCTS HAPPILY and
 * then serves EVERY tenant from the one static `botToken`, while
 * `getInstallation` is never called even once. The mechanism is in the SDK:
 *
 *   - `handleWebhook` (webhook mode) resolves the token per request:
 *       `if (!this.defaultBotTokenProvider && payload.type === "event_callback")`
 *       → `resolveTokenForTeam(enterprise_id ?? team_id)` → `requestContext.run({token}, …)`
 *   - `routeSocketEvent` (socket mode) calls `processEventPayload` DIRECTLY,
 *     skipping that wrap entirely — and `getToken()` reads `requestContext`
 *     first, a store that is ALWAYS empty in socket mode, so it falls through to
 *     the static token.
 *
 * Two consequences this module is built around:
 *   1. mode is HARD-CODED to "webhook". There is no socket option to pass.
 *   2. NO static `botToken` is ever handed to the adapter. A static botToken sets
 *      `defaultBotTokenProvider`, and the webhook path then SKIPS
 *      `resolveTokenForTeam` too — the same cross-tenant leak, in webhook mode.
 *      `test/slack-connector.test.ts` pins both with a protective test.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * WHY `installationProvider` AND NOT `setInstallation`
 * ─────────────────────────────────────────────────────────────────────────────
 * `setInstallation` / `encryptionKey` write the bot token into a SECOND store —
 * the SDK's own `state-pg` rows inside `chat_bridge` — encrypted with
 * `@chat-adapter/shared`'s no-AAD `encryptToken`. That is a duplicate credential
 * store with weaker sealing than `connector_installs`. We never call either:
 * `connector_installs` stays the ONE place a Slack bot token lives, and
 * `installationProvider.getInstallation` is the only way it is read.
 *
 * `resolveTokenForTeam` PREFERS `installationProvider` and returns `null` on a
 * miss — it does NOT fall through to the state store. A null means the SDK
 * answers `200 ok` and NEVER calls `processEventPayload`: no session, no post,
 * no token. Fail-closed, and pinned by test.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE SIGNING SECRET IS APP-WIDE, NOT PER-TENANT
 * ─────────────────────────────────────────────────────────────────────────────
 * `SlackInstallation` carries `{ botToken, botUserId?, teamName? }` — there is no
 * `signingSecret` field, and `verifySlackSignature` HMACs `v0:{ts}:{body}` with
 * ONE secret and never sees a team id. So Slack cannot be `credential-bound`:
 * ONE app, ONE endpoint, ONE signing secret, MANY tenants. The tenant lives in
 * the payload envelope. That is precisely why `tenantResolution` is
 * `"payload-team-id"` here and `"credential-bound"` for Telegram — and why the
 * abstraction had to carry both from day one.
 */

export const SLACK_PROVIDER = "slack";

/** The route Slack posts events to. The webhook seam mounts it; we only name it. */
export const SLACK_WEBHOOK_PATH = "/connectors/webhook/slack";

/**
 * A connector whose inbound transport is an HTTP request rather than a poll loop
 * or a socket.
 *
 * Declared HERE, structurally, rather than as a field on the core `Connector`
 * type: a webhook seam consumes it by duck-typing
 * (`(connector as { webhook?: ConnectorWebhookBinding }).webhook`), so adding
 * Slack still costs the core exactly zero lines. When a second webhook channel
 * lands, lift this shape into `connector/types.ts` once — generically, never as
 * `if (provider === "slack")`.
 */
export interface ConnectorWebhookBinding {
  /**
   * Where the install key comes from. `"payload"` = the request body carries it
   * (Slack's `team_id`/`enterprise_id`); a `credential-bound` channel would use a
   * per-install path segment instead.
   */
  keySource: "payload";
  /** The path this connector's events arrive on. */
  path: string;
  /**
   * Verify the request and extract the install key, or `null` to drop it.
   *
   * The router MUST use this to pick which mounted install handles the request.
   * It is the SAME derivation the adapter's own `resolveTokenForTeam` performs
   * (`enterprise_id ?? team_id`), so the workspace and the bot token can never be
   * resolved from two different keys — that divergence is the confused-deputy
   * vector this single function exists to close.
   *
   * A bad signature, an unparseable body or an envelope with no team is a `null`
   * (drop it), never a throw: a hostile body must not take the bridge down.
   */
  extractInstallKey(request: Request): Promise<string | null>;
}

export interface SlackConnector extends Connector<unknown> {
  webhook: ConnectorWebhookBinding;
}

export interface SlackConnectorOptions {
  /**
   * The Slack app's signing secret — APP-WIDE (see the header). Used to verify
   * every inbound request, whichever tenant it belongs to.
   */
  signingSecret: string;
  /** Slack app client id — required for the OAuth (Add-to-Slack) exchange. */
  clientId: string;
  /** Slack app client secret. */
  clientSecret: string;
  /**
   * The install table. `installationProvider` reads it on EVERY inbound event to
   * resolve that team's bot token — so a revoked/deleted install stops working
   * immediately, with no adapter rebuild and no restart.
   */
  installs: InstallsLookup;
  /**
   * Open a sealed `credential_ref` into a usable bot token.
   *
   * The injection point for the credential cipher: the bridge passes its
   * `decrypt` here and this module never learns the scheme. Defaults to identity,
   * which is the CURRENT honest state of `connector_installs.credential_ref` —
   * it holds the raw secret (documented as a KNOWN GAP in `tenant/installs.ts`).
   * When the cipher lands, this default is replaced at the ONE call site in
   * `index.ts`; nothing in this file changes.
   */
  decryptCredential?: (credentialRef: string) => string | Promise<string>;
  /** Override the Slack API base (tests point it at a local recorder). */
  apiUrl?: string;
}

/**
 * The ONE install-key composer. Every derivation in this module — the webhook
 * extractor, the payload resolver, the OAuth callback — funnels through it, so
 * "which install is this?" has exactly one answer everywhere.
 *
 * ENTERPRISE GRID: an org-wide install is keyed by `enterprise_id`, not
 * `team_id` — the SDK's `resolveTokenForTeam` is called with
 * `is_enterprise_install ? enterprise_id : team_id` (index.js:1515-1519). Key the
 * row any other way and every org-wide event resolves to no install and is
 * fail-closed dropped.
 */
export function slackInstallKey(source: {
  enterpriseId?: string | null | undefined;
  teamId?: string | null | undefined;
}): string | null {
  const enterpriseId = blankToNull(source.enterpriseId);
  if (enterpriseId) return enterpriseId;
  return blankToNull(source.teamId);
}

function blankToNull(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

/**
 * Verify + parse an inbound Slack request and derive its install key.
 *
 * Uses the SDK's exported `readSlackWebhook` (HMAC verify, timestamp skew check,
 * then a typed parse) rather than a hand-rolled body reader — the signature check
 * is the ONLY thing standing between a forged `team_id` and a tenant's bot token,
 * and it is not ours to reimplement.
 *
 * `url_verification` (Slack's endpoint handshake) legitimately carries no team,
 * so it yields `null`. The webhook seam must answer that one directly — the
 * adapter's `handleWebhook` already does, without a token.
 */
export function createSlackInstallKeyExtractor(
  signingSecret: string,
): (request: Request) => Promise<string | null> {
  return async (request: Request): Promise<string | null> => {
    try {
      // Clones the request: `readSlackWebhook` consumes the body, and the router
      // must still be able to hand the SAME request to `adapter.handleWebhook`.
      const payload = await readSlackWebhook(request.clone(), { signingSecret });
      if (payload.kind === "url_verification" || payload.kind === "unsupported") {
        return null;
      }
      return slackInstallKey(payload);
    } catch {
      // Bad signature, stale timestamp, malformed body → no install key, drop.
      // Never a throw: a hostile request must not take the process down.
      return null;
    }
  };
}

/**
 * The install key as seen from a Chat SDK `Message`, for the payload-resolver
 * fallback.
 *
 * READS `team_id` AND NEVER `team`. This is a real cross-tenant trap: on an
 * inner Slack message event, `team` is the AUTHOR's team — in a Slack Connect
 * external shared channel that is a DIFFERENT org than the one that installed the
 * app. Routing on it would hand one tenant's message to another tenant's Session.
 * `team_id` is the value the SDK stamps from the signature-verified ENVELOPE
 * (`processEventPayload`: `if (!(event.team || event.team_id)) event.team_id = payload.team_id`).
 *
 * Note the envelope's `enterprise_id` is NOT forwarded onto the inner event, so
 * this fallback cannot see it. That is exactly why the TRANSPORT key (derived by
 * `extractInstallKey` from the envelope) takes precedence in `resolveTenant`.
 */
export function slackInstallKeyFromMessage(payload: unknown): string | null {
  if (!isRecord(payload)) return null;
  // A Chat SDK `Message` keeps the raw Slack event on `.raw`; a raw event may
  // also be handed in directly (unit tests, a future transport).
  const raw = isRecord(payload["raw"]) ? payload["raw"] : payload;
  return slackInstallKey({
    enterpriseId: raw["enterprise_id"] as string | undefined,
    teamId: raw["team_id"] as string | undefined,
  });
}

/**
 * Build the `installationProvider` for ONE install.
 *
 * SCOPED ON PURPOSE. The adapter mounted for install `T_A` will only ever serve
 * `T_A`'s token: an envelope naming any other installation resolves to `null`,
 * the SDK logs "No installation found from provider", answers `200 ok`, and never
 * reaches `processEventPayload`. So a mis-routing bug in the webhook seam degrades
 * to a DROPPED event, never to a cross-tenant reply. Tenant isolation stops being
 * a property of the router and becomes a property of the adapter (D1).
 */
function createScopedInstallationProvider(
  install: ConnectorInstall,
  options: SlackConnectorOptions,
): { getInstallation: (id: string, isEnterpriseInstall: boolean) => Promise<SlackInstallation | null> } {
  const decrypt = options.decryptCredential ?? ((ref: string) => ref);

  return {
    async getInstallation(
      installationId: string,
      _isEnterpriseInstall: boolean,
    ): Promise<SlackInstallation | null> {
      // Fail closed on a mis-route: this adapter is ONE tenant's.
      if (blankToNull(installationId) !== install.installKey) return null;

      // Read-through on EVERY event, never cached in the adapter: a revoked or
      // re-keyed install takes effect on the next message, with no restart.
      const row = await options.installs.lookupInstall(
        SLACK_PROVIDER,
        installationId,
      );
      if (!row) return null;

      const botToken = blankToNull(await decrypt(row.credentialRef));
      if (!botToken) return null;

      return { botToken };
    },
  };
}

/**
 * Slack, as ONE registry entry.
 *
 * `registry.register(createSlackConnector({ … }))` — and that is the entire
 * footprint outside this file, its OAuth module, its test and its doc.
 */
export function createSlackConnector(
  options: SlackConnectorOptions,
): SlackConnector {
  if (!blankToNull(options.signingSecret)) {
    throw new Error(
      "createSlackConnector: signingSecret is required — it is the app-wide HMAC key " +
        "that proves an inbound request really came from Slack. Without it a forged " +
        "team_id would be enough to pull a tenant's bot token.",
    );
  }

  const extractInstallKey = createSlackInstallKeyExtractor(options.signingSecret);
  // The core's own payload-team-id strategy helper — zero lines added to it.
  const payloadResolver = createPayloadTeamIdResolver(slackInstallKeyFromMessage);

  return {
    id: SLACK_PROVIDER,
    direction: "channel",
    auth: "oauth",
    // The tenant comes from the (signature-verified) payload envelope, not from
    // which credential received the request — Slack has only one endpoint and one
    // signing secret for every tenant.
    tenantResolution: "payload-team-id",

    adapterFactory(install: ConnectorInstall): SlackAdapter {
      return createSlackAdapter({
        // 1. WEBHOOK, always. See the header: socket mode bypasses per-team token
        //    resolution entirely and would serve every tenant one static token.
        mode: "webhook",
        // 2. The app-wide HMAC key. Not per-install — SlackInstallation has no
        //    place to put one.
        signingSecret: options.signingSecret,
        // 3. OAuth (Add-to-Slack) credentials, for handleOAuthCallback.
        clientId: options.clientId,
        clientSecret: options.clientSecret,
        // 4. NO `botToken`. A static one sets `defaultBotTokenProvider`, and
        //    handleWebhook then SKIPS resolveTokenForTeam — every tenant would
        //    reply with it. NO `encryptionKey`, and setInstallation is never
        //    called: the SDK's state-pg store must not become a second home for
        //    a bot token.
        installationProvider: createScopedInstallationProvider(install, options),
        ...(options.apiUrl ? { apiUrl: options.apiUrl } : {}),
      });
    },

    async resolveTenant(
      event: InboundEvent,
      ctx: TenantContext,
    ): Promise<WorkspaceId | null> {
      // Candidate keys, most authoritative first. Both are produced by
      // slackInstallKey() — one composer, two vantage points, never two
      // independent parsers.
      //
      // 1. THE TRANSPORT KEY. Set by the webhook seam from `extractInstallKey`,
      //    i.e. from the SIGNATURE-VERIFIED envelope. It is the only view that can
      //    see `enterprise_id`, and it is the SAME key the SDK used to pick the
      //    bot token — so the workspace and the token cannot diverge.
      // 2. THE PAYLOAD KEY (`message.raw.team_id`, envelope-stamped). Covers a
      //    transport that sets no install key. Also the reason an org-wide Grid
      //    event still routes: (1) supplies the enterprise id, (2) would only ever
      //    see the team id and would miss.
      //
      // Both candidates end in `installs.resolveWorkspace`, so the fail-closed
      // semantics are the core's, uniformly. A miss on both is a DROP — there is
      // no default workspace here and there must never be one.
      const transportKey = blankToNull(event.installKey);
      if (transportKey) {
        const workspaceId = await ctx.installs.resolveWorkspace(
          event.provider,
          transportKey,
        );
        if (workspaceId) return workspaceId;
      }
      return payloadResolver(event, ctx);
    },

    // No `listen`/`stopListening`: for a webhook channel the transport IS the HTTP
    // request. The boot path calls `connector.listen?.(adapter)` and, finding
    // nothing, moves on — never learning that Slack is different.

    webhook: {
      keySource: "payload",
      path: SLACK_WEBHOOK_PATH,
      extractInstallKey,
    },
  };
}
