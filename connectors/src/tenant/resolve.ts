/**
 * Tenant routing — inbound provider event → the workspace that owns it (charter D29).
 *
 * TWO strategies, because the providers genuinely differ:
 *
 *   credential-bound   Telegram. Each workspace brings its own bot (BYO-bot), so the
 *                      inbound path — which bot's webhook/polling loop produced this —
 *                      IS the tenant binding. The tenant is known BEFORE the payload is
 *                      inspected. A Telegram `Update` carries no team/org field at all,
 *                      which is exactly why the abstraction must not assume one exists.
 *
 *   payload-team-id    Slack. The event envelope stamps a workspace id (`team_id`).
 *                      Dig it out, then look it up in `connector_installs` like any
 *                      other install key.
 *
 * `provider_team_id → workspace` is therefore ONE strategy of two, not the model. That
 * is what lets P3's Slack land with zero core change.
 *
 * Everything here is FAIL-CLOSED: unknown provider, missing install key, unknown install,
 * or a payload we cannot read all resolve to `null` — drop the event. There is no
 * "default workspace" fallback anywhere in this file, and there must never be one: a
 * fallback would hand one tenant's message to another tenant's agent and Session.
 */
import type {
  Connector,
  InboundEvent,
  TenantContext,
  WorkspaceId,
} from "../connector/types.js";
import {
  connectorRegistry,
  type ConnectorRegistry,
} from "../connector/registry.js";

/**
 * Strategy: `credential-bound`.
 *
 * The event's `installKey` (set by the transport that received it) is the tenant key.
 * Use this as a connector's `resolveTenant` directly:
 *
 *     const telegramConnector: Connector = {
 *       id: 'telegram',
 *       tenantResolution: 'credential-bound',
 *       resolveTenant: resolveCredentialBound,
 *       // …
 *     };
 */
export async function resolveCredentialBound(
  event: InboundEvent,
  ctx: TenantContext,
): Promise<WorkspaceId | null> {
  return ctx.installs.resolveWorkspace(event.provider, event.installKey);
}

/**
 * The `credential-bound` strategy as a factory, mirroring
 * {@link createPayloadTeamIdResolver} so a Connector declares its tenant routing
 * the same way whichever strategy it uses.
 */
export function credentialBoundResolver(): (
  event: InboundEvent,
  ctx: TenantContext,
) => Promise<WorkspaceId | null> {
  return resolveCredentialBound;
}

/**
 * Strategy: `payload-team-id`.
 *
 * Builds a `resolveTenant` from a connector-supplied extractor. The extractor owns the
 * ONLY provider-specific knowledge (where the team id lives in that provider's envelope);
 * the lookup and the fail-closed semantics stay here, shared. An extractor that throws
 * on a malformed payload is treated as a miss, not a crash — a hostile or truncated
 * webhook body must not take the bridge down, and must not route anywhere.
 *
 *     const slackConnector: Connector = {
 *       id: 'slack',
 *       tenantResolution: 'payload-team-id',
 *       resolveTenant: createPayloadTeamIdResolver(
 *         (payload) => (payload as SlackEnvelope).team_id ?? null,
 *       ),
 *       // …
 *     };
 */
export function createPayloadTeamIdResolver<TPayload = unknown>(
  extractTeamId: (payload: TPayload | undefined) => string | null | undefined,
): (
  event: InboundEvent<TPayload>,
  ctx: TenantContext,
) => Promise<WorkspaceId | null> {
  return async (event, ctx) => {
    let teamId: string | null | undefined;
    try {
      // `payload` is optional on the event: a transport that hands us no payload
      // at all must resolve to NO tenant, never to a default one. The extractor
      // sees `undefined` and is expected to return null.
      teamId = extractTeamId(event.payload);
    } catch {
      // Malformed payload → no tenant. Drop it.
      return null;
    }
    return ctx.installs.resolveWorkspace(event.provider, teamId);
  };
}

/**
 * The CORE router. This function is the thing P3 must never have to edit.
 *
 * It does exactly two things: find the connector registered for the event's provider,
 * and ask it for the tenant. All provider-specific knowledge lives in the connector's
 * declaration; none of it lives here. Adding Slack/Discord/Teams/WhatsApp/iMessage is a
 * `registry.register(...)` call and nothing else.
 */
// @canonical capability:connector-tenant-routing aka:tenant,multi-tenant,workspace-routing,resolveTenant,connector_installs doc:.claude/workflows/bp-connectors-charter.md
export async function resolveTenantForEvent(
  event: InboundEvent,
  ctx: TenantContext,
  registry: ConnectorRegistry = connectorRegistry,
): Promise<WorkspaceId | null> {
  const connector: Connector | undefined = registry.get(event.provider);

  // Unknown provider → fail closed. An unregistered connector has no credentials and
  // no owner; there is nothing safe to do with its traffic.
  if (!connector) return null;

  const workspaceId = await connector.resolveTenant(event, ctx);

  // Normalise a blank/whitespace workspace id to a hard miss, so a sloppy connector
  // cannot smuggle an empty-string "tenant" past the callers' `if (!workspaceId)` guards.
  if (typeof workspaceId !== "string" || workspaceId.trim() === "") return null;

  return workspaceId;
}
