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
 * `chat_bridge.connector_installs` (D29/D35), with both secrets OPENED.
 *
 * This is what `adapterFactory` is handed, and it is the whole of per-workspace
 * credential isolation (D1): a tenant's adapter is constructed from that tenant's
 * provider secret, and its /v1/chat traffic travels on that tenant's OWN chat
 * token — both read from the SAME row that routed the event. The core never logs
 * or forwards either secret.
 *
 * At REST both secrets are sealed (AES-256-GCM, AAD-bound to this row's
 * identity — see `src/crypto/credential-cipher.ts`). They are plaintext only in
 * this in-memory shape, opened by `tenant/installs.ts` on the way out of SQL.
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
  /** The workspace that owns this install. Part of the seal's AAD. */
  workspaceId: WorkspaceId;
  /**
   * The provider secret (bot token, signing secret), OPENED — or NULL when the
   * connector has NO per-workspace provider credential.
   *
   * Sealed at rest in `connector_installs.credential_ref` (AES-256-GCM, AAD-bound
   * to this row's identity — D35/D37). Plaintext only in this in-memory shape.
   *
   * NULL is a first-class case, not an error (D42): Microsoft Teams runs on ONE
   * operator Azure app for every customer org (`appType: "MultiTenant"`), so a
   * Teams install has no per-workspace secret to store. The `credential_ref`
   * column was already nullable in `db/schema.ts`; a non-nullable TYPE would have
   * fail-closed every Teams row out of `lookupInstall`/`listInstalls`. The
   * tenant-safety fail-closed rule lives on `workspace_id` (a routable install
   * MUST have one), not on the credential.
   *
   * A connector that DOES need a credential (Telegram's bot token, Discord's
   * triple, WhatsApp's Meta four) must reject a null here in its own
   * `adapterFactory` — LOUDLY, at mount. A silent fallback to an ambient
   * `TELEGRAM_BOT_TOKEN`/`DISCORD_BOT_TOKEN` env var would send one workspace's
   * messages in another's name: this wave's headline bug, wearing a hat.
   *
   * OPTIONAL on the WRITE path (D52), and that is the whole point of the `?`: it
   * is the only way a caller can say "do not touch the credential". Until this
   * wave the key was REQUIRED, so `upsertInstall` could not distinguish "set it to
   * NULL" from "leave it alone" — and `isBlankSecret(undefined)` is true, so the
   * Slack OAuth callback (which supplies no `chatToken`) silently WIPED the
   * sibling column on every re-auth. ABSENT now means PRESERVE (where preserving
   * is safe — see `tenant/installs.ts`), and NULL/`""` still mean "no secret".
   * On the READ path `tenant/installs.ts#toInstall` always sets it (string or
   * null), so a mounted install never carries `undefined` here.
   */
  credentialRef?: string | null;
  /**
   * THIS workspace's Barkpark `chat`-permission ApiToken, OPENED. Sealed at rest
   * in `connector_installs.chat_token_ref`.
   *
   * Nullable on purpose: an install can exist before its chat token is minted (an
   * OAuth callback lands the provider secret first). A missing token is a
   * fail-closed DROP at dispatch (`dropped_no_chat_token`) — there is no operator
   * -token fallback anywhere in the request path, because a fallback is exactly
   * how one token silently comes to serve every tenant.
   *
   * Optional in the TYPE only so the connectors that never mint a client (an
   * adapterFactory needs the provider secret, not this) can build an install
   * literal without it. Absent and null mean the same thing: drop.
   */
  chatToken?: string | null;
}

/**
 * An install whose chat token is PRESENT — the only shape allowed to mint a
 * ChatClient. Narrowing to this type at the one place it is checked (dispatch)
 * is what makes "no token => no HTTP call" a compile-time property rather than a
 * convention someone can forget.
 */
export type AuthorizedInstall = ConnectorInstall & { chatToken: string };

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
  /**
   * `(provider, workspaceId)` -> the full OPENED install, or `null` when that
   * workspace has no install of that provider (charter D69, tool connectors).
   *
   * This is the tool-connector seam's read: the runtime `tool-headers` route
   * proves the caller's WORKSPACE by verifying a signed session ticket, then opens
   * exactly THAT workspace's sealed PAT for the named provider — never a caller
   * -supplied install key. Because the seal's AAD binds `workspace_id`, a row that
   * belongs to another tenant cannot be opened here even if its `(provider,
   * install_key)` were guessed: this lookup keys on the workspace itself.
   *
   * Fail-closed: a blank provider/workspace, an unknown pair, or a blob that does
   * not open for the row's own identity all yield `null` — the tool-headers route
   * turns that into the same opaque 404 as any unknown route.
   */
  lookupByWorkspace(
    provider: string,
    workspaceId: string | null | undefined,
  ): Promise<ConnectorInstall | null>;
}

/**
 * The WRITE half of the installs table — deliberately NOT part of
 * {@link InstallsLookup} (D51/D52).
 *
 * The core (`core/dispatch.ts`) hands connectors a WITNESSED, read-only lookup; a
 * required `deleteInstall` on `InstallsLookup` would push a destructive verb into
 * the one seam every inbound event passes through, for no caller's benefit. So
 * disconnect takes this narrower capability instead, and only the two real lookups
 * ({@link InstallsLookup} implementations built by `tenant/installs.ts`) carry it.
 *
 * It exists at all because a DISCONNECT has to be durable: before this wave the
 * bridge had NO SQL DELETE anywhere — `Bridge.removeInstall` unmounts in memory
 * only, so the next restart re-read the row and mounted the "disconnected" bot
 * straight back. And since D52 made SQL NULL mean PRESERVE, revoking a secret can
 * no longer be spelled as an upsert with a null: it needs its own verb.
 */
export interface InstallsWriter {
  /** Remove the row. `true` when a row was actually deleted, `false` when none matched. */
  deleteInstall(provider: string, installKey: string): Promise<boolean>;
}

/** An installs lookup that can also delete — what `tenant/installs.ts` returns. */
export type MutableInstallsLookup = InstallsLookup & InstallsWriter;

/** The verdict of a paste-mode credential check, BEFORE anything is written. */
export type ConnectValidation =
  | { ok: true; installKey: string; displayName: string }
  | { ok: false; reason: string };

/**
 * A TOOL connector's MCP transport descriptor (charter D69/D71) — the OTHER
 * direction of the epic. A channel connector is inbound (a human talks to the
 * agent); a tool connector is OUTBOUND (the agent ACTS on a service), and it does
 * so by being an additional MCP server the runner's `claude` subprocess connects
 * to, exactly the way it already connects to the loopback `bp mcp serve` server.
 *
 * This is the STATIC, NON-SECRET half a connector declares: which MCP transport,
 * and where. The credential never appears here — the runner fetches
 * `{"Authorization":"Bearer <pat>"}` at MCP-connect time via the bridge's
 * loopback `tool-headers` route (D38: no Elixir ever holds the plaintext PAT).
 * The `headersHelper` command that does that fetch is minted by the bridge's
 * `tool-descriptors` route (it bakes in the loopback URL + the session ticket),
 * NOT by the connector — so this descriptor stays credential-free and reusable.
 *
 * `type: "http"` is the only transport a tool connector uses today: GitHub's MCP
 * server (`https://api.githubcopilot.com/mcp/`) speaks Streamable HTTP, and claude
 * 2.1.209's `--mcp-config` accepts `{type:"http", url, headersHelper}` for exactly
 * this. A second tool connector (Linear) is a second registry entry with its own
 * `toolDescriptor` — ZERO core-loop change, the same acceptance bar the channel
 * connectors meet.
 */
export interface ToolDescriptor {
  /** The MCP transport. `"http"` (Streamable HTTP) is the only one v1 uses. */
  type: "http";
  /** The MCP server endpoint the agent's subprocess connects to. Non-secret. */
  url: string;
}

/**
 * PASTE-MODE CONNECT (charter D51) — the optional member that makes a connector
 * connectable from Studio in two minutes.
 *
 * A connector WITHOUT it is catalog-visible but not connectable: Slack installs
 * over OAuth (a different flow), Teams needs per-org Azure admin consent, iMessage
 * is a self-hosted operator profile. Telegram and Discord are BYO-bot — the whole
 * credential IS a string the operator pastes — so `validate` is the entire
 * onboarding step.
 *
 * `validate` runs BEFORE any write, for two load-bearing reasons:
 *   (i) a revoked or fat-fingered token is refused AT PASTE TIME, in the UI, with
 *       a reason — not at the next restart, as a crash-looping unit (D53);
 *  (ii) it yields the `installKey`, which Studio needs BEFORE it mints the chat
 *       token so the token can be labelled `connector:<provider>:<install_key>` —
 *       the only thing that lets DISCONNECT revoke exactly that token later.
 *
 * It MUST NOT write anything and MUST NOT throw for a bad credential: a bad
 * credential is `{ok:false, reason}`, a typed refusal the route turns into a 422.
 */
export interface ConnectorConnect {
  mode: "paste";
  /** What Studio labels the paste box (e.g. "Bot token from @BotFather"). */
  credentialLabel: string;
  /** Where the operator gets the credential. Rendered as a link, never fetched. */
  helpUrl?: string;
  validate(credential: string): Promise<ConnectValidation>;
}

/** Per-dispatch context handed to a connector's `resolveTenant`. */
export interface TenantContext {
  installs: InstallsLookup;
}

/**
 * Per-refresh context handed to a connector's optional {@link Connector.refreshCredential}
 * (charter D90/D92).
 *
 * `now` is injected (not read as `Date.now()` inside the hook) so the skew-window
 * decision — "refresh when `expires_at − now < SKEW`" — is deterministic under
 * test: a fixed `now` proves both the "still fresh, no refresh" and the "inside the
 * window, refresh" branches without racing the wall clock.
 */
export interface RefreshContext {
  /** Current time as epoch-ms. Injectable so the skew window is testable. */
  now: number;
}

/**
 * Where the inbound HTTP transport finds the install key (charter D39).
 *
 * - `path` — the provider registers a per-install URL, so the key IS a path
 *   segment: `POST|GET {prefix}/webhooks/:provider/:installKey`. WhatsApp (each
 *   workspace's Meta app points at its own URL) and Telegram in webhook mode.
 * - `payload` — the provider's request_url is APP-WIDE (one URL for every
 *   workspace), so the key must be dug out of the body: Slack's `team_id`,
 *   Teams' tenant id. Route: `POST|GET {prefix}/webhooks/:provider`.
 */
export type WebhookKeySource = "path" | "payload";

/**
 * A connector's inbound-webhook declaration — the ONE generic member the HTTP
 * seam needs. This is the whole contract addition P3's webhook channels required:
 * Slack, Teams and WhatsApp all land as a registry entry with a `webhook` block,
 * and `core/dispatch.ts` / `tenant/resolve.ts` / `connector/registry.ts` /
 * `turn/turn-loop.ts` are untouched.
 *
 * A connector with no `webhook` (Telegram in polling mode) is simply not routable
 * over HTTP — its URLs 404, opaquely, like any other unknown route. (Discord runs
 * BOTH transports since D228: a Gateway socket AND a path-keyed webhook for
 * slash-command interactions, so it DOES carry a `webhook` block.)
 */
export interface ConnectorWebhook {
  keySource: WebhookKeySource;
  /**
   * Extract the install key from the RAW body bytes (required for
   * `keySource: "payload"`, ignored for `"path"`).
   *
   * Handed the raw body EXACTLY as it arrived — never a re-serialised parse —
   * because the same bytes are what the adapter's signature verification will
   * HMAC. Return `null` when the key is absent or unparseable: a null key is a
   * fail-closed 404 (or the handshake below), never a guess at "the only
   * workspace".
   *
   * May be async: Slack verifies the app-wide HMAC before it will name a team, and
   * WebCrypto's `verify` is a promise.
   *
   * Demuxing BEFORE the signature is verified is safe by construction: the key
   * only SELECTS which secret to verify against. A forged key points at another
   * tenant's install whose secret will not verify the attacker's body, so the
   * adapter rejects it cryptographically (proven: an A-signed body handed to B's
   * adapter -> 401).
   */
  extractInstallKey?(
    rawBody: string,
    headers: Headers,
  ): string | null | Promise<string | null>;
  /**
   * Answer a request that legitimately carries NO install key — the provider's
   * endpoint-VERIFICATION handshake.
   *
   * This member exists because without it the seam is unusable for Slack: Slack
   * pings the Events request_url with `{"type":"url_verification","challenge":…}`
   * BEFORE any workspace has installed the app, and that payload carries no
   * `team_id`. `extractInstallKey` correctly returns null, the demux correctly
   * finds no install — and the app could then never be configured at all. The
   * generic fix is a tenant-less hook, not a `if (provider === "slack")` in the
   * router.
   *
   * CONTRACT, and it is narrow on purpose:
   *   - consulted ONLY when `extractInstallKey` yielded null, so it can never
   *     shadow a real tenant's traffic;
   *   - it MUST NOT touch a tenant credential or a Chat — it has no install row
   *     and is not entitled to one. Slack's implementation verifies the APP-WIDE
   *     signing secret and echoes the challenge; that is the whole of it;
   *   - returning `null` falls through to the SAME opaque 404 as everything else,
   *     so a connector that does not implement it loses nothing and leaks nothing.
   */
  handleUnkeyed?(
    rawBody: string,
    headers: Headers,
  ): Response | null | Promise<Response | null>;
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
   * Inbound HTTP transport, for the channels whose transport IS an HTTP request
   * (Slack, Teams, WhatsApp). Absent for poll/socket channels (Telegram polling,
   * Discord gateway) — they start their transport in `listen()` instead.
   *
   * Declaring it is the ONLY thing a webhook channel does to become routable:
   * `http/webhook-server.ts` reads this member off the registry and nothing else.
   */
  webhook?: ConnectorWebhook;
  /**
   * Paste-mode connect (D51). Absent ⇒ catalog-visible, not connectable — the
   * connect routes answer the same opaque 404 they answer for an unknown provider.
   */
  connect?: ConnectorConnect;
  /**
   * TOOL connector's MCP transport (charter D69/D71). Present ONLY on a `tool`
   * (or `both`) connector: it declares the MCP server the agent's `claude`
   * subprocess connects to when this workspace has an install. Absent on every
   * channel connector — a channel is inbound, it has no tool transport.
   *
   * A connector with a `toolDescriptor` seals ONLY its provider credential on
   * `/connect` (a PAT), never a chat token, and is NEVER mounted as a channel
   * (`registry.channels()` excludes it) — the connect loop branches on
   * `direction`, never on the provider id.
   */
  toolDescriptor?: ToolDescriptor;
  /**
   * Refresh this install's credential at header-build time (charter D90/D92) —
   * the OPTIONAL, CONNECTOR-OWNED half of the dual-shape credential seam.
   *
   * `tool-headers` (`http/connect.ts`) calls this generically —
   * `connector.refreshCredential?.(install, ctx)` — for whatever tool connector a
   * runner is (re)connecting. The connector, not the shared route, owns the whole
   * decision: it parses its own credential shape, decides whether the token is
   * inside its skew window, and — if so — exchanges a fresh one. The shared route
   * stays provider-agnostic; only the connector knows Linear's bundle shape and its
   * `grant_type=refresh_token` exchange.
   *
   * Contract:
   *   - return `null` when NO refresh is needed or POSSIBLE — a bare-string paste
   *     credential (GitHub's PAT, which cannot refresh), a bundle still comfortably
   *     inside its lifetime, or a bundle with no `refresh_token`. `null` is the
   *     common case and must be cheap;
   *   - return a FRESH PLAINTEXT credential (Linear: the re-serialised
   *     `{access_token, refresh_token?, expires_at?}` JSON bundle) when a refresh
   *     succeeded. The route write-backs it via `upsertInstall` (which performs the
   *     single seal — the hook returns PLAINTEXT, never a pre-sealed blob) and
   *     builds the Bearer from it;
   *   - THROW on a refresh FAILURE (network, non-2xx, `invalid_grant`). The route
   *     catches it, logs LOUDLY, and serves the STORED credential (serve-stale-loud,
   *     D90): a failed refresh must never turn a maybe-stale header into a hard
   *     connect failure. There is NO on-401 leg — the bridge only PRINTS headers and
   *     never sees the provider's 401.
   *
   * Absent on every connector that has no refreshable credential (every channel;
   * GitHub, whose PAT never rotates) — its credential is served byte-for-byte.
   */
  refreshCredential?(
    install: ConnectorInstall,
    ctx: RefreshContext,
  ): Promise<string | null>;
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
   * The inbound message's own timestamp, in epoch ms — the moment the human spoke,
   * NOT when the bridge processed it. Generic by design: the core loop reads it to
   * feed durable, channel-specific policy state (WhatsApp's 24-hour customer-service
   * window) without naming a channel — the connector alone knows how to dig the
   * vendor timestamp out of its own payload.
   *
   * Returns `null` when the payload carries no readable timestamp (a status-only
   * callback, a shape we cannot parse); the core loop falls back to `Date.now()`
   * rather than skip the write. Absent on every connector whose policy state does
   * not care when the inbound landed.
   */
  inboundTimestampMs?(payload: TPayload): number | null;
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
