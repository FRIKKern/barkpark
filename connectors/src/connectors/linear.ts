import type { Adapter } from "chat";

import type {
  Connector,
  ConnectorInstall,
  ToolDescriptor,
} from "../connector/types.js";
import {
  createLinearTokenRefresher,
  type LinearTokenRefreshDeps,
} from "../oauth/linear-token-refresh.js";

/**
 * Linear — the SECOND tool connector (charter D77), and the proof that the
 * tool-connector abstraction is TRUE rather than asserted.
 *
 * GitHub (D69, the first tool connector) reused the paste-a-PAT `connect_mode`.
 * Until a SECOND tool connector lands, "a second tool connector is a second
 * registry entry with ZERO core-loop change" is a claim about a seam nobody has
 * run a current through a second time. Linear is that current — and it is the
 * HARD version, on purpose: Linear's hosted MCP server is OAuth-only, so landing
 * it proves the tool seam survives a NON-paste auth. It is the OUTBOUND dual of
 * Slack (the channel OAuth already shipped): a signed connect ticket rides the
 * OAuth `state`, and the callback writes ONE sealed tool install.
 *
 * WHY OAUTH-ONLY, NO PERSONAL-API-KEY MODE (D77)
 * ----------------------------------------------
 * Linear's GraphQL header format differs by credential KIND: `Authorization:
 * Bearer <token>` for an OAuth access token, vs a RAW `<API_KEY>` (no scheme) for
 * a personal API key. Supporting both would fork the header-building code the
 * generic `tool-headers` route prints — for zero epic value. So Linear is OAuth
 * ONLY this wave: no `connect` (paste) member at all, no personal-key mode. The
 * `connect?` member is OPTIONAL on the shared `Connector` shape (`types.ts` —
 * `connect?:`), so Linear registers with NO connect member — no paste mode, no
 * fake mode. It is connectable exclusively through `oauth/linear-oauth.ts`.
 *
 * WHY LINEAR'S MCP TAKES A STATIC BEARER (D77)
 * --------------------------------------------
 * Linear's own docs, verbatim: its hosted Streamable-HTTP MCP server accepts a
 * static `Authorization: Bearer <token>` from "an existing Linear OAuth
 * application without an extra authentication hop". That is EXACTLY the shape the
 * generic tool seam already emits — `tool-headers` prints `Bearer ${credentialRef}`
 * provider-agnostically (`http/connect.ts`) — so the ALREADY-MERGED Elixir
 * injection (`mcp_config/2`, keyed only on provider/type/url) consumes a Linear
 * install with ZERO change. Nothing in the core loop special-cases Linear.
 *
 * WHY `direction:"tool"` / no channel transport (mirrors GitHub, D69)
 * -------------------------------------------------------------------
 * A tool connector is never inbound: no webhook, no poll loop, no `listen`. It is
 * excluded from `registry.channels()`, so `startBridge` never mounts a Chat for
 * it. `adapterFactory` therefore THROWS — a tool connector has no Chat adapter,
 * and a caller reaching it is a bug, not a fallback. `tenantResolution` is a
 * required field on the shared shape; `"credential-bound"` is its honest value
 * (the OAuth token is the tenant binding) even though `resolveTenant` is never
 * called for a connector with no inbound events.
 *
 * D38 — THE TOKEN NEVER TRANSITS ELIXIR
 * -------------------------------------
 * The OAuth callback derives a stable, non-secret install key (the Linear
 * organization id) and SEALS the bare access token under the SAME per-workspace
 * credential cipher every channel uses (`provider="linear"`, `chat_token_ref`
 * NULL). At runtime the agent's subprocess fetches
 * `{"Authorization":"Bearer <token>"}` from the bridge's loopback `tool-headers`
 * route via claude's `headersHelper`; Elixir writes only that helper command + a
 * non-secret session ticket and never sees the plaintext.
 *
 * D80→D90 — TOKEN STALENESS: NAMED IN W8, CLOSED IN W9
 * ----------------------------------------------------
 * W8 (D80) sealed the BARE access token, because `tool-headers` printed
 * `Bearer ${credentialRef}` RAW — a JSON blob would have become the bearer and
 * broken MCP auth unless the SHARED route learned to parse it. Named consequence:
 * Linear access tokens live ~24h, so an expired install opened fine and 401'd
 * invisibly AT THE PROVIDER until re-connected. W9 (D89–D92) closes it WITHOUT
 * breaking the zero-core-change invariant: the read-path learned ONE generic,
 * shape-blind parse (a `{`-prefixed JSON object with a non-empty `access_token` is a
 * bundle; anything else — including GitHub's bare PAT — passes byte-for-byte), so
 * `credential_ref` can now hold a `{access_token, refresh_token?, expires_at?}`
 * bundle. This connector owns a `refreshCredential` hook (below) that `tool-headers`
 * calls generically: inside a skew window it exchanges a fresh token against
 * `api.linear.app/oauth/token` and the route write-backs the re-sealed bundle. A
 * LIVE refresh rides the human gate `connectors-linear-live-oauth-gate` — never
 * fabricated. The refresh hook is present ONLY when the bridge is configured with
 * Linear OAuth client credentials (see `createLinearConnector`); without them the
 * connector still serves any bare-string install byte-for-byte.
 *
 * THE ONE-INCH HUMAN GATE
 * -----------------------
 * Everything up to a LIVE Linear call is built and unit-proven with an injected
 * `fetch` and a real loopback curl. The live call itself needs a real OAuth token
 * a human must authorize (`connectors-linear-live-oauth-gate`). NO live tool call
 * is fabricated anywhere: ZERO live installs exist and that is the honest state.
 */

export const LINEAR_PROVIDER = "linear";

/** Linear's hosted first-party MCP server (Streamable HTTP). Fixed, non-secret. */
export const LINEAR_MCP_URL = "https://mcp.linear.app/mcp";

export interface LinearConnectorOptions {
  /** Override the MCP server URL (tests point it at a local stub). */
  mcpUrl?: string;
  /**
   * Linear OAuth client credentials (charter D92). Present ⇒ the connector carries
   * a `refreshCredential` hook that re-tokens an expiring install at header-build
   * time. Absent ⇒ NO hook — a bare-string or bundle install is served as-is (the
   * common state on a box with no Linear app configured). Threaded from
   * `registerBuiltinConnectors`' deps bag, exactly as Slack's credentials are.
   */
  refresh?: LinearTokenRefreshDeps;
}

export function createLinearConnector(
  options: LinearConnectorOptions = {},
): Connector {
  const mcpUrl = options.mcpUrl ?? LINEAR_MCP_URL;

  const toolDescriptor: ToolDescriptor = { type: "http", url: mcpUrl };

  // The refresh hook is CONNECTOR-OWNED and OPTIONAL (D92): only present when the
  // bridge has Linear OAuth client credentials to drive the exchange. The shared
  // `tool-headers` route calls `connector.refreshCredential?.()` generically, so its
  // absence simply means "serve the stored credential" — never a broken read-path.
  const refreshCredential = options.refresh
    ? createLinearTokenRefresher(options.refresh)
    : undefined;

  return {
    id: LINEAR_PROVIDER,
    // The OTHER direction: the agent ACTS on Linear, so this is a TOOL, not a
    // channel. It is excluded from `registry.channels()` and never mounted as a
    // Chat; it appears in `registry.tools()` and drives the MCP config instead.
    direction: "tool",
    // OAuth 2.1 — landed through `oauth/linear-oauth.ts`, never a pasted key.
    auth: "oauth",
    // The OAuth token is the tenant binding — but a tool connector has no inbound
    // events, so `resolveTenant` below is never consulted. The field is required
    // by the shared shape; this is its honest value.
    tenantResolution: "credential-bound",

    toolDescriptor,

    // The refresh hook (D92), present only when Linear OAuth creds were threaded in.
    // Spread rather than assigned `undefined` to keep `exactOptionalPropertyTypes`
    // happy: an absent hook is a MISSING member, not a member set to undefined.
    ...(refreshCredential ? { refreshCredential } : {}),

    // NO `connect` member (D77): Linear is OAuth-only, so it is NOT paste-
    // connectable. The paste-mode `/connect` routes answer the same opaque 404
    // they answer for an unknown provider; the OAuth callback in
    // `oauth/linear-oauth.ts` is the only way to install it.

    /**
     * A tool connector has NO Chat adapter — it is never mounted as a channel.
     * Throwing here is the honest fail-closed answer: `startBridge` iterates
     * `registry.channels()`, which excludes this connector, so nothing legitimate
     * ever calls this. A caller that does has confused a tool for a channel.
     */
    adapterFactory(install: ConnectorInstall): Adapter {
      throw new Error(
        `linear is a TOOL connector (D77) — it has no channel adapter and is never ` +
          `mounted as a Chat. install="${install.installKey}" workspace=` +
          `"${install.workspaceId}". The agent reaches Linear through its MCP server ` +
          `(${mcpUrl}), not through an inbound adapter.`,
      );
    },

    /** No inbound events ever reach a tool connector. Fail closed. */
    async resolveTenant(): Promise<string | null> {
      return null;
    },
  };
}
