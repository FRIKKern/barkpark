import { createTeamsAdapter, type TeamsAdapter } from "@chat-adapter/teams";

import type {
  Connector,
  ConnectorInstall,
  InboundEvent,
  TenantContext,
} from "../connector/types.js";
import { createPayloadTeamIdResolver } from "../tenant/resolve.js";

/**
 * Microsoft Teams — the heavy pair's first half (charter D3/D29/D30, D42).
 *
 * THE RULING THAT SAVES A WEEK: **Teams needs no per-workspace credential.**
 *
 * `TeamsAdapterConfig` is `apiUrl / appId / appPassword / appTenantId / appType /
 * federated / logger / userName` — there is no `installationProvider` and no
 * per-tenant credential map (contrast Slack, whose adapter takes one). And
 * `appTenantId` is the BOT's own Azure home tenant, NOT the customer's. So with
 * `appType: "MultiTenant"`, ONE operator Azure app serves every Teams org, and the
 * customer's tenancy arrives in the PAYLOAD.
 *
 * Consequences, all of which fall out of the generic Connector shape:
 *
 *   - `tenantResolution: "payload-team-id"` — the same strategy Slack uses; the
 *     Microsoft tenant id IS the team id. Zero core change: `resolveTenant` is
 *     built by the core's own `createPayloadTeamIdResolver`.
 *   - `install_key` = the Microsoft tenant id (`connector_installs.install_key`).
 *   - `credential_ref` stays **NULL**. The column is already nullable (`db/schema.ts`),
 *     so this is a zero-schema-change fact — Teams simply has no per-workspace provider
 *     secret to store. What IS per-workspace is the Barkpark `chat` token, and that
 *     lives in `chat_token_ref` (D35), not here.
 *   - **We do NOT copy Slack's OAuth machinery.** There is nothing to OAuth: the
 *     operator's app credentials are process-global config (env: `TEAMS_APP_ID` /
 *     `TEAMS_APP_PASSWORD`), and the per-org install is an act of that org's Teams
 *     admin inside their own tenant (see `docs/ops/teams-azure-bot.md`) — it produces
 *     no token for us to store. Adding an OAuth surface here would add a credential to
 *     protect for exactly zero benefit.
 *
 * TRANSPORT: webhook only. `TeamsAdapter.handleWebhook` is a pure `Request -> Response`
 * handler that binds no port ("We never own the HTTP server" — the adapter's own
 * `BridgeHttpAdapter` docstring), so `listen` stays undefined and the HTTP seam drives
 * `chat.webhooks.teams(request)`. Never call `adapter.handleWebhook` directly: an
 * uninitialised adapter answers 500 "No handler registered".
 *
 * FAIL-CLOSED, observed not asserted: an activity with no Bot Framework JWT is
 * rejected by the adapter with **401 in ~2ms**, before any handler runs. That is why a
 * successful Teams turn is UNPROVABLE without the Azure gate — and why the 401 is the
 * behaviour we ship, not a bug (`test/teams-connector.test.ts`).
 */

export const TEAMS_PROVIDER = "teams";

/** `object` but not `null` and not an array-with-no-keys — the safe cast for hostile bodies. */
function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null
    ? (value as Record<string, unknown>)
    : null;
}

/** A non-blank string, or null. Blank ids must never become install keys. */
function asKey(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

/**
 * THE ONE Teams tenant derivation (D42). Precedence is exactly:
 *
 *     activity.conversation?.tenantId ?? activity.channelData?.tenant?.id
 *
 * which is what the adapter's own `cacheUserContext` uses. This single function backs
 * BOTH `webhook.extractInstallKey` (route the raw webhook body to a tenant) and
 * `resolveTenant` (route the dispatched event to a workspace). Two independent
 * derivations with different precedence would be a confused-deputy vector: a payload
 * carrying both fields with DIFFERENT values would route the HTTP request to one
 * tenant and the Session to another. There is one function, so they cannot desync.
 *
 * It accepts either shape it can be handed:
 *   - the raw Bot Framework `Activity` (the webhook body, pre-adapter), or
 *   - the SDK `Message` the dispatch loop carries, whose `raw` IS that activity
 *     (`parseTeamsMessage` sets `raw: activity`) — so this works with zero core change.
 *
 * Everything unreadable is `null`: a hostile or truncated body resolves to NO tenant
 * and the event is dropped, never routed to a guess.
 */
// @canonical capability:teams-tenant-id aka:teams,tenant,tenantId,channelData,install-key,confused-deputy doc:docs/ops/teams-azure-bot.md
export function teamsTenantId(payload: unknown): string | null {
  const outer = asRecord(payload);
  if (!outer) return null;

  // An SDK Message carries the activity on `.raw`; a webhook body IS the activity.
  const activity = asRecord(outer["raw"]) ?? outer;

  const conversation = asRecord(activity["conversation"]);
  const fromConversation = asKey(conversation?.["tenantId"]);
  if (fromConversation !== null) return fromConversation;

  const channelData = asRecord(activity["channelData"]);
  const tenant = asRecord(channelData?.["tenant"]);
  return asKey(tenant?.["id"]);
}

/**
 * The inbound-HTTP contract the webhook seam reads (structural — the seam consumes
 * this shape, it does not import this type).
 */
export interface TeamsWebhookDescriptor {
  /**
   * `payload`: the tenant id lives in the body. Safe here — and ONLY here — because
   * routing on an unverified body cannot bypass authentication: every tenant's Chat
   * verifies the SAME operator app's Bot Framework JWT, so a forged body is 401'd
   * whichever install it is routed to. (A credential-bound provider like WhatsApp
   * cannot do this: there, the body selects the secret that would verify it, so its
   * key MUST come from the path.)
   */
  keySource: "payload";
  /** Bot Framework posts activities. There is no GET handshake. */
  allowedMethods: readonly ["POST"];
  extractInstallKey(payload: unknown): string | null;
}

export type TeamsConnector = Connector & { webhook: TeamsWebhookDescriptor };

/**
 * Operator-level Azure app credentials — process-global, NOT per workspace.
 * Every field falls back to the adapter's own env defaults (`TEAMS_APP_ID`,
 * `TEAMS_APP_PASSWORD`, `TEAMS_APP_TENANT_ID`, `TEAMS_API_URL`).
 */
export interface TeamsConnectorOptions {
  /** Microsoft App ID of the ONE operator Azure app. */
  appId?: string;
  /** Its client secret. */
  appPassword?: string;
  /** The BOT's own Azure home tenant — never a customer's. */
  appTenantId?: string;
  /** Bot Framework service URL override (GCC-High). */
  apiUrl?: string;
  /**
   * MultiTenant is the whole point: one app, every customer org. SingleTenant is
   * exposed only for an operator who runs Barkpark inside a single Azure tenant.
   */
  appType?: "MultiTenant" | "SingleTenant";
}

export function createTeamsConnector(
  options: TeamsConnectorOptions = {},
): TeamsConnector {
  const appType = options.appType ?? "MultiTenant";
  // The core's own strategy helper — Teams adds NO routing code of its own.
  const resolver = createPayloadTeamIdResolver(teamsTenantId);

  return {
    id: TEAMS_PROVIDER,
    direction: "channel",
    // Not "oauth": there is no per-workspace token to obtain. The operator's app
    // credential is config; the per-org install is a Teams-admin act in the customer's
    // own tenant and hands us nothing to store.
    auth: "token",
    tenantResolution: "payload-team-id",

    /**
     * One adapter per install — all built from the SAME operator app credentials.
     * `install.credentialRef` is deliberately unread (and NULL in the table): a Teams
     * install has no per-workspace provider secret. Isolation between tenants is
     * carried by the Barkpark `chat` token (D35) and by the composite-keyed
     * `thread_session_map`, not by a Teams credential that does not exist.
     */
    adapterFactory(_install: ConnectorInstall): TeamsAdapter {
      return createTeamsAdapter({
        appType,
        ...(options.appId !== undefined ? { appId: options.appId } : {}),
        ...(options.appPassword !== undefined
          ? { appPassword: options.appPassword }
          : {}),
        ...(options.appTenantId !== undefined
          ? { appTenantId: options.appTenantId }
          : {}),
        ...(options.apiUrl !== undefined ? { apiUrl: options.apiUrl } : {}),
      });
    },

    async resolveTenant(
      event: InboundEvent,
      ctx: TenantContext,
    ): Promise<string | null> {
      return resolver(event, ctx);
    },

    // No `listen`: the transport IS the HTTP request (chat.webhooks.teams).

    webhook: {
      keySource: "payload",
      allowedMethods: ["POST"],
      // The SAME function that backs resolveTenant. Identity, not a copy.
      extractInstallKey: teamsTenantId,
    },
  };
}
