import {
  createSlackAdapter,
  type SlackAdapter,
  type SlackInstallation,
} from "@chat-adapter/slack";
import {
  parseSlackWebhookBody,
  verifySlackSignature,
} from "@chat-adapter/slack/webhook";

import type {
  Connector,
  ConnectorInstall,
  ConnectorWebhook,
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

/**
 * The route Slack posts events to — one APP-WIDE URL for every tenant, which is
 * what makes Slack `keySource: "payload"`. The webhook seam owns the routing
 * (`{prefix}/webhooks/slack`); this constant is what the install doc and the app
 * manifest quote, so they cannot drift from the router.
 */
export const SLACK_WEBHOOK_PATH = "/connectors/webhooks/slack";

export interface SlackConnector extends Connector<unknown> {
  webhook: ConnectorWebhook;
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
   * OPTIONAL extra unsealing step for `credential_ref`.
   *
   * Normally UNUSED and it should stay that way: `createInstallsLookup(pool,
   * cipher)` already opens both sealed columns on the way out of SQL (D35/D37), so
   * the `install.credentialRef` this module reads is already the plaintext bot
   * token. The hook survives only as an injection point for a test (or a future
   * store that hands back a POINTER rather than the bytes). Defaults to identity.
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
 * Takes the RAW BODY BYTES and the headers, which is the webhook seam's contract
 * (D39): the seam reads the body exactly once and hands the same bytes to the
 * extractor and to the adapter, because Slack HMACs the raw bytes and any
 * re-serialisation (whitespace, unicode escapes) would fail verification for
 * reasons impossible to debug from the 401.
 *
 * `verifySlackSignature` (HMAC over `v0:{ts}:{body}` + a timestamp skew check)
 * then `parseSlackWebhookBody` — the SDK's own exports, not a hand-rolled reader:
 * the signature check is the ONLY thing standing between a forged `team_id` and a
 * tenant's bot token, and it is not ours to reimplement.
 *
 * `url_verification` (Slack's endpoint handshake) legitimately carries no team, so
 * it yields `null` — and {@link createSlackHandshakeResponder} is what answers it.
 */
export function createSlackInstallKeyExtractor(
  signingSecret: string,
): (rawBody: string, headers: Headers) => Promise<string | null> {
  return async (rawBody: string, headers: Headers): Promise<string | null> => {
    try {
      await verifySlackSignature(rawBody, headers, { signingSecret });
      const payload = parseSlackWebhookBody(rawBody, { headers });
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
 * Answer Slack's endpoint-verification handshake — the ONE inbound request that
 * has no tenant and must still succeed.
 *
 * Slack POSTs `{"type":"url_verification","challenge":"…"}` the moment you set the
 * Events request_url, BEFORE any workspace has installed the app. It carries no
 * `team_id`, so the demux finds no install and (correctly) would 404 — and the
 * app could then never be configured at all. This is the seam's generic
 * `handleUnkeyed` hook, not a provider branch in the router.
 *
 * It is signature-VERIFIED against the app-wide signing secret (so an unsigned
 * challenge gets nothing) and it touches NO tenant credential and NO Chat: it
 * echoes the challenge and stops. A non-handshake body returns null and falls
 * through to the router's opaque 404.
 */
export function createSlackHandshakeResponder(
  signingSecret: string,
): (rawBody: string, headers: Headers) => Promise<Response | null> {
  return async (rawBody: string, headers: Headers): Promise<Response | null> => {
    try {
      await verifySlackSignature(rawBody, headers, { signingSecret });
      const payload = parseSlackWebhookBody(rawBody, { headers });
      if (payload.kind !== "url_verification") return null;
      // The shape Slack accepts, and the shape the adapter's own handleWebhook
      // answers with (`index.js:1511` — `Response.json({ challenge })`).
      return Response.json({ challenge: payload.challenge });
    } catch {
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
): {
  getInstallation: (
    id: string,
    isEnterpriseInstall: boolean,
  ) => Promise<SlackInstallation | null>;
} {
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

      // A Slack install with no bot token is not a token to fall back FROM — it
      // is an install that cannot speak. Return null: `resolveTokenForTeam` then
      // answers 200 and never calls `processEventPayload` (no session, no post).
      // Absent and null are the same nothing (`credentialRef` is optional in the
      // TYPE since D52 — absent means "leave the column alone" on the write path).
      if (!row.credentialRef) return null;

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

    // The ONE generic member the HTTP seam reads (D39). `keySource: "payload"`
    // because Slack's request_url is app-wide; `handleUnkeyed` because the
    // endpoint-verification handshake legitimately has no tenant.
    webhook: {
      keySource: "payload",
      extractInstallKey,
      handleUnkeyed: createSlackHandshakeResponder(options.signingSecret),
    },
  };
}
