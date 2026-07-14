/**
 * The Connector contract (charter D29/D30).
 *
 * A Connector is a plain TypeScript declaration in a registry — NOT an Elixir
 * `Barkpark.Plugin` (that is a compile-time BEAM construct; this is a runtime TS
 * map). The Chat SDK already gives us "register an adapter, no core change" via
 * `new Chat({ adapters })`; a Connector adds the three things the SDK does not
 * model: which DIRECTION it runs in, how an inbound event resolves to a Barkpark
 * WORKSPACE, and how its inbound TRANSPORT is started.
 *
 * Adding a P3 channel (Slack / Discord / Teams / WhatsApp / iMessage) must be ONE
 * registry entry plus its `@chat-adapter/*` dependency, with ZERO edits to the
 * core router (`tenant/resolve.ts`), the registry, or the dispatch loop
 * (`core/dispatch.ts`). That zero-core-change invariant IS this wave's acceptance
 * bar, and `test/tenant.test.ts` enforces it with a structural tripwire.
 */
import type { Adapter } from "chat";

/** A Barkpark workspace UUID. The tenant key for everything downstream. */
export type WorkspaceId = string;

/** Inbound (you talk to the agent) vs outbound (the agent acts) vs both. */
export type ConnectorDirection = "channel" | "tool" | "both";

/** How a workspace proves it owns this install. */
export type ConnectorAuth = "oauth" | "token" | "signing-secret";

/**
 * How an inbound event is mapped to a tenant (charter D29).
 *
 * - `credential-bound` — the inbound path IS the tenant binding. Telegram: each
 *   workspace brings its own bot (BYO-bot), so the bot that received the message
 *   identifies the tenant BEFORE the payload is inspected. A Telegram `Update`
 *   carries no team/org field AT ALL, which is exactly why the abstraction must
 *   never assume a payload-extractable tenant id.
 * - `payload-team-id` — the provider stamps a workspace/team id into the event
 *   envelope (Slack's `team_id`). Extract it, then look it up like any other
 *   install key. Declared now; P3 Slack lands with zero core change.
 */
export type TenantResolution = "credential-bound" | "payload-team-id";

/**
 * One workspace's install of one connector — a row of
 * `chat_bridge.connector_installs` (D29).
 *
 * This is what `adapterFactory` is handed, and it is the whole of per-workspace
 * credential isolation (D1): a tenant's adapter is constructed from that tenant's
 * credential and nothing else. The core never logs or forwards `credentialRef`.
 */
export interface ConnectorInstall {
  /** The connector id this install belongs to (e.g. "telegram"). */
  provider: string;
  /**
   * The provider-side identity of the install — a Telegram bot id, a Slack
   * team_id. Non-secret by construction: it is a PRIMARY KEY column, so a raw
   * secret must never be used here.
   */
  installKey: string;
  /** The workspace that owns this install. */
  workspaceId: WorkspaceId;
  /**
   * Reference to the provider secret (bot token, signing secret) — or NULL when the
   * connector has NO per-workspace provider credential.
   *
   * NULL is a first-class case, not an error (D42): Microsoft Teams runs on ONE
   * operator Azure app for every customer org (`appType: "MultiTenant"`), so a Teams
   * install has no per-workspace secret to store. The `credential_ref` column was
   * already nullable in `db/schema.ts`; the TYPE said otherwise, which would have
   * fail-closed every Teams row out of `lookupInstall`/`listInstalls`. The tenant-safety
   * fail-closed rule lives on `workspace_id` (a routable install MUST have one), not on
   * the credential.
   *
   * A connector that DOES need a credential (Telegram's bot token, WhatsApp's Meta
   * four) must reject a null here in its own `adapterFactory` — loudly, at mount.
   *
   * KNOWN GAP: today this column holds the raw secret in plaintext. Encrypting it
   * (or pointing it at a real per-workspace credential store) is filed as
   * `connectors-encrypt-install-credentials` and blocked on D9's run-secrets
   * workspace scoping. Named here so nobody mistakes the name for a promise.
   */
  credentialRef: string | null;
}

/**
 * A raw inbound provider event as it reaches the bridge (webhook body or poll
 * update), normalised to the two things the core loop needs (`threadId`, `text`)
 * plus the two things tenant routing needs (`installKey`, `payload`).
 */
export interface InboundEvent<TPayload = unknown> {
  /** The connector id this event arrived on — matches `Connector.id`. */
  provider: string;
  /** The SDK thread id, already namespaced by the adapter. The map's key. */
  threadId: string;
  /** The user's text for this turn. */
  text: string;
  /**
   * The install binding this event arrived through, set by the TRANSPORT (which
   * knows which credential/adapter received it). This is what makes
   * `credential-bound` resolution possible for providers whose payload carries no
   * tenant id. Absent for `payload-team-id` connectors — and a missing key is a
   * fail-closed null tenant, NEVER a fallback to "the only workspace".
   */
  installKey?: string | null;
  /** The provider's raw payload (a Telegram `Update`, a Slack envelope, …). */
  payload?: TPayload;
}

/**
 * The fail-closed installs lookup a resolver consults.
 *
 * Backed in production by `chat_bridge.connector_installs` (see `tenant/installs.ts`);
 * trivially faked in tests. Declared as an interface so the core never hard-imports
 * a database module — it stays disjoint from, and testable without, Postgres.
 */
export interface InstallsLookup {
  /**
   * `(provider, installKey)` -> the full install, or `null` when unknown/absent.
   * The core needs this (not just the workspace id) because `adapterFactory` must
   * be handed THAT tenant's credential.
   */
  lookupInstall(
    provider: string,
    installKey: string | null | undefined,
  ): Promise<ConnectorInstall | null>;
  /**
   * `(provider, installKey)` -> `workspace_id`, or `null` when the install is
   * unknown, absent, or unmapped. Fail-closed: a miss is ALWAYS null, never a
   * cross-tenant fallback (mirrors `Content.Scope.scope_to_workspace/3`).
   */
  resolveWorkspace(
    provider: string,
    installKey: string | null | undefined,
  ): Promise<WorkspaceId | null>;
  /** Every install of a connector — the boot path mounts one Chat per install. */
  listInstalls(provider: string): Promise<ConnectorInstall[]>;
}

/** Per-dispatch context handed to a connector's `resolveTenant`. */
export interface TenantContext {
  installs: InstallsLookup;
}

/**
 * A channel or tool connector (charter D30).
 *
 * Telegram registers as a first-class Connector, identical in shape to every
 * future channel — the P2 smoke adapter is an adapter SWAP, not a special case.
 */
export interface Connector<TPayload = unknown> {
  /** Stable provider id. Also the key in `new Chat({ adapters })`. */
  id: string;
  direction: ConnectorDirection;
  auth: ConnectorAuth;
  /** Declares which routing strategy `resolveTenant` implements. */
  tenantResolution: TenantResolution;
  /**
   * Build the Chat SDK adapter for ONE install's credentials (D1 isolation).
   * Called once per install; the adapter is handed to `new Chat({ adapters })`.
   */
  adapterFactory(install: ConnectorInstall): Adapter;
  /**
   * Map an inbound event to the workspace that owns it, or `null` to drop it.
   * MUST fail closed: return null rather than guess a tenant. Implementations
   * should compose the strategy helpers in `tenant/resolve.ts` rather than
   * hand-rolling a lookup, so fail-closed semantics stay uniform.
   */
  resolveTenant(
    event: InboundEvent<TPayload>,
    ctx: TenantContext,
  ): Promise<WorkspaceId | null>;
  /**
   * Start the inbound transport for a mounted adapter — Telegram's getUpdates
   * poll loop, and in P3 Discord's gateway socket. Webhook-driven connectors
   * (Slack, Teams) leave it undefined: the transport IS the HTTP request.
   *
   * This is what keeps the core free of `if (provider === "telegram")`. The boot
   * path calls `connector.listen?.(adapter)` and never learns the channel.
   */
  listen?(adapter: Adapter): Promise<void>;
  stopListening?(adapter: Adapter): Promise<void>;
}
