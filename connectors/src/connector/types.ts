/**
 * The Connector contract (charter D30).
 *
 * A Connector is a plain TypeScript declaration in a registry — NOT an Elixir
 * `Barkpark.Plugin` (that is a compile-time BEAM construct; this is a runtime TS map).
 * Adding a P3 channel (Slack / Discord / Teams / WhatsApp / iMessage) must be ONE
 * registry entry plus its `@chat-adapter/*` dependency, with ZERO edits to the core
 * router (`tenant/resolve.ts`) or the registry (`connector/registry.ts`). That
 * zero-core-change invariant is this slice's acceptance bar.
 */
import type { Adapter } from 'chat';

/** A Barkpark workspace UUID (`workspaces.id`). The tenant key for everything downstream. */
export type WorkspaceId = string;

/** Inbound (you talk to the agent) vs outbound (the agent acts) vs both. */
export type ConnectorDirection = 'channel' | 'tool' | 'both';

/** How a workspace proves it owns this install. */
export type ConnectorAuth = 'oauth' | 'token' | 'signing-secret';

/**
 * How an inbound event is mapped to a tenant (charter D29).
 *
 * - `credential-bound` — the inbound path IS the tenant binding. Telegram: each
 *   workspace brings its own bot, so the bot token / webhook path identifies the
 *   tenant BEFORE the payload is inspected. There is no team/org field in a
 *   Telegram Update, so the abstraction must never assume one is extractable.
 * - `payload-team-id` — the provider stamps a workspace/team id into the event
 *   envelope (Slack `team_id`). Extract it, then look it up in `connector_installs`.
 */
export type TenantResolution = 'credential-bound' | 'payload-team-id';

/**
 * Credentials for one install, as loaded from the workspace's credential store.
 * Opaque to the core: only the owning connector's `adapterFactory` interprets them.
 * The core NEVER logs or forwards these.
 */
export type ConnectorCredentials = Record<string, string>;

/**
 * A raw inbound provider event as it reaches the bridge (webhook body or poll update).
 *
 * `installKey` is the credential/inbound-path binding the event arrived through — for
 * `credential-bound` connectors it is populated by the transport (which bot's webhook
 * path or polling loop produced this), and is the ONLY thing needed to find the tenant.
 * For `payload-team-id` connectors it is absent and the id is dug out of `payload`.
 */
export interface InboundEvent<TPayload = unknown> {
  /** The connector id this event arrived on — matches `Connector.id` (e.g. 'telegram'). */
  provider: string;
  /**
   * The install binding this event arrived through (bot id, webhook path secret, …).
   * Absent/null for `payload-team-id` connectors. Never guessed — a missing key is a
   * fail-closed null tenant, never a fallback to "the only workspace".
   */
  installKey?: string | null;
  /** The provider's raw payload (a Telegram `Update`, a Slack event envelope, …). */
  payload: TPayload;
}

/**
 * The fail-closed installs lookup a resolver consults.
 *
 * Backed in production by `chat_bridge.connector_installs` over W3-1's `pg.Pool`
 * (see `tenant/installs.ts`); trivially faked in tests. Declared as an interface so
 * this slice never hard-imports a concrete DB module — the core stays disjoint from,
 * and testable without, the database.
 */
export interface InstallsLookup {
  /**
   * `(provider, installKey)` → `workspace_id`, or `null` when the install is unknown,
   * absent, or unmapped. Fail-closed: a miss is ALWAYS null, never a cross-tenant
   * fallback (mirrors `Content.Scope.scope_to_workspace/3` semantics).
   */
  resolveWorkspace(
    provider: string,
    installKey: string | null | undefined,
  ): Promise<WorkspaceId | null>;
}

/** Per-dispatch context handed to a connector's `resolveTenant`. */
export interface TenantContext {
  installs: InstallsLookup;
}

/**
 * A channel or tool connector (charter D30).
 *
 * Telegram registers as a first-class Connector, identical in shape to every future
 * channel — the P2 smoke adapter is an adapter swap, not a special case.
 */
export interface Connector<TPayload = unknown> {
  /** Stable provider id. Matches `InboundEvent.provider` and the `provider` column. */
  id: string;
  direction: ConnectorDirection;
  auth: ConnectorAuth;
  /** Declares which routing strategy `resolveTenant` implements. Metadata for the catalog. */
  tenantResolution: TenantResolution;
  /**
   * Build the Chat SDK adapter for one install's credentials. Called once per install;
   * the resulting adapter is handed to `new Chat({ adapters })`.
   */
  adapterFactory(creds: ConnectorCredentials): Adapter;
  /**
   * Map an inbound event to the workspace that owns it, or `null` to drop it.
   * Implementations should compose the strategy helpers in `tenant/resolve.ts` rather
   * than hand-rolling a lookup, so fail-closed semantics stay uniform.
   */
  resolveTenant(
    event: InboundEvent<TPayload>,
    ctx: TenantContext,
  ): Promise<WorkspaceId | null>;
}
