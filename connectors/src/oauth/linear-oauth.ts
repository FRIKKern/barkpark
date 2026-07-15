import {
  signConnectTicket,
  verifyConnectTicket,
  type SignConnectTicketOptions,
} from "../connect/ticket.js";
import type { ConnectorInstall, WorkspaceId } from "../connector/types.js";
import { LINEAR_PROVIDER } from "../connectors/linear.js";

/**
 * Connect-to-Linear — the OAuth 2.1 install flow (charter D77/D78/D79/D80).
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE OUTBOUND DUAL OF SLACK — WITH TWO DELIBERATE SUBTRACTIONS
 * ─────────────────────────────────────────────────────────────────────────────
 * This module mirrors `oauth/slack-oauth.ts` (the channel OAuth we already ship)
 * MINUS two things, because a TOOL install is not a CHANNEL install:
 *
 *   1. NO pending-connect row (D78). Slack's pending row exists SOLELY to stage
 *      the workspace-bound CHAT token across the redirect (D48/D63). A tool
 *      install has NO chat token (`chat_token_ref` stays NULL) — there is nothing
 *      to stage — so the HMAC-signed connect ticket riding `state` carries the
 *      WHOLE workspace binding, and the callback needs no `consumePendingConnect`
 *      dep and no nonce join.
 *   2. NO mount (D78). A tool connector is never a channel: `registry.channels()`
 *      excludes it, the agent reaches Linear through the MCP `tool-descriptors`
 *      seam, and the WRITE is the connect. There is nothing to bring up, so the
 *      callback needs no `mountInstall` dep.
 *
 * What survives, unchanged from Slack: the `state` is a `connect/ticket.ts`
 * CONNECT TICKET — the same HMAC-signed `{w,p,n,t}` primitive Studio mints — bound
 * to provider `"linear"`, verified BEFORE the code is spent (so a forged state
 * never even reaches Linear), and the D64 incumbent-owner check runs BEFORE any
 * write (so re-authing an org another workspace owns is a typed 409, never a
 * silent takedown of the incumbent's install via `ON CONFLICT`).
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * TWO HOSTS, DON'T UNIFY THEM (D78)
 * ─────────────────────────────────────────────────────────────────────────────
 * Linear's authorize endpoint is on `linear.app`; its token-exchange endpoint is
 * on `api.linear.app`; its GraphQL API is on `api.linear.app/graphql`. These are
 * DIFFERENT hosts and MUST NOT be collapsed into one base — the exchange host is
 * not the authorize host.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * INSTALL KEY = THE IMMUTABLE ORGANIZATION ID (D79)
 * ─────────────────────────────────────────────────────────────────────────────
 * The GraphQL analogue of GitHub's `GET /user` is the root Query field
 * `organization { id urlKey }` — argument-free, one round trip. `Organization.id`
 * is `ID!` and is ABSENT from `OrganizationUpdateInput` (immutable); `urlKey` IS in
 * that input (an admin can rename it). An install key must never silently change
 * under a workspace (D64 depends on it), so the key is `id`, and `urlKey` feeds
 * `displayName` ONLY. This deliberately diverges from GitHub's login-as-key.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * SEAL THE BARE TOKEN, PKCE OMITTED (D80/D81)
 * ─────────────────────────────────────────────────────────────────────────────
 * `credential_ref` is the BARE `access_token` — never a `{access,refresh,expires}`
 * JSON bundle — because `tool-headers` (`http/connect.ts`) prints
 * `Bearer ${credentialRef}` RAW: a blob would become the bearer and break MCP auth
 * unless the shared generic route learned to parse it, violating this wave's whole
 * point. `scope=read` only (Linear's default; they discourage broad `write`). PKCE
 * is OMITTED: it is optional-additive in Linear's flow and the bridge is a
 * confidential client (client_secret held server-side, the code leg is
 * server-to-server), so the interception threat PKCE targets does not apply. Both
 * are cheap to add later; both are deferred with named rationale.
 */

/** Linear's authorize endpoint (where the connect button points). On `linear.app`. */
const LINEAR_AUTHORIZE_URL = "https://linear.app/oauth/authorize";
/** Linear's token-exchange endpoint. A DIFFERENT host (`api.linear.app`) — D78. */
const LINEAR_OAUTH_TOKEN_URL = "https://api.linear.app/oauth/token";
/** Linear's GraphQL API — the `organization { id urlKey }` round trip runs here. */
const LINEAR_GRAPHQL_URL = "https://api.linear.app/graphql";

/** The route Linear redirects back to. Registered in the Linear OAuth app. */
export const LINEAR_OAUTH_CALLBACK_PATH = "/connectors/oauth/linear/callback";

/**
 * The scopes the app requests. `read` ONLY (D81) — enough for the agent to query
 * Linear over MCP, and Linear's always-present default. Kept in code (not just the
 * app config) so the install URL and any doc can never drift.
 */
export const LINEAR_SCOPES: readonly string[] = ["read"];

export interface LinearInstallUrlOptions {
  clientId: string;
  redirectUri: string;
  workspaceId: WorkspaceId;
  /** The connect-ticket HMAC secret (`CONNECTORS_CONNECT_SECRET`). */
  stateSecret: string;
  scopes?: readonly string[];
  now?: () => number;
  nonce?: string;
}

/**
 * The "Connect Linear" URL for ONE workspace, carrying a signed connect ticket as
 * its `state`.
 *
 * The bridge itself has no reason to build this in production — the Elixir Studio
 * catalog does. This exists so the wire has one executable definition and a smoke
 * script can drive the flow without Studio. Unlike Slack there is NO pending row
 * to stage first (a tool install has no chat token — D78), so the ticket's nonce
 * is unused downstream; it is still minted so the ticket shape is uniform.
 */
export function buildLinearInstallUrl(options: LinearInstallUrlOptions): string {
  const url = new URL(LINEAR_AUTHORIZE_URL);
  url.searchParams.set("client_id", options.clientId);
  url.searchParams.set("redirect_uri", options.redirectUri);
  // Authorization-code flow — Linear returns `?code=…` to the redirect URI.
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", (options.scopes ?? LINEAR_SCOPES).join(","));

  const ticketOptions: SignConnectTicketOptions = {};
  if (options.now) ticketOptions.now = options.now;
  if (options.nonce) ticketOptions.nonce = options.nonce;
  url.searchParams.set(
    "state",
    signConnectTicket(
      options.workspaceId,
      LINEAR_PROVIDER,
      options.stateSecret,
      ticketOptions,
    ),
  );
  return url.toString();
}

/** The subset of Linear's token response the bridge depends on. */
export interface LinearTokenResponse {
  access_token?: string;
  token_type?: string;
  expires_in?: number;
  /**
   * The rotating refresh token (charter D80/D90). Present on both the
   * authorization-code exchange and every refresh; Linear ROTATES it per call, so
   * the fresh value must be stored and the old one discarded. Untyped ANYWHERE
   * before this wave — the code exchange simply threw it away with the bare-token
   * seal (D80). Optional because a token response can legitimately omit it.
   */
  refresh_token?: string;
  scope?: string;
  /** Present on a refusal (`invalid_grant`, …). */
  error?: string;
  error_description?: string;
}

/**
 * The credential `credential_ref` holds for an OAUTH tool install (charter
 * D90) — a small JSON bundle instead of the bare access token D80 shipped.
 *
 *   { "access_token": "…", "refresh_token": "…", "expires_at": <epoch-ms> }
 *
 * Only `access_token` is required. `refresh_token` and `expires_at` are absent on a
 * legacy row (a pre-refresh install sealed the bare string) and on any credential
 * that cannot refresh — which is why the read-path (`tool-headers`) accepts BOTH a
 * bundle and a bare string, and this shape is ADDITIVE, never a migration (D89).
 *
 * `expires_at` is EPOCH-MS (`now + expires_in*1000`), the same absolute-instant
 * shape the WhatsApp 24h-window policy uses — not a relative TTL, so the skew
 * decision is one subtraction against the wall clock with no "issued at" to track.
 */
export interface LinearCredentialBundle {
  access_token: string;
  refresh_token?: string;
  /** Epoch-ms the access token expires. Absent ⇒ unknown, treated as refreshable. */
  expires_at?: number;
}

/**
 * Parse a stored `credential_ref` into a Linear bundle, or `null` when it is NOT a
 * bundle (charter D89).
 *
 * `null` covers every non-bundle input — a bare-string paste credential, malformed
 * JSON, a JSON array, a JSON object with no usable `access_token`. A `null` here is
 * NOT an error: the refresher reads it as "nothing to refresh, serve as-is", and
 * the generic read-path serves the raw string byte-for-byte. NEVER throws.
 */
export function parseLinearBundle(raw: string): LinearCredentialBundle | null {
  const trimmed = raw.trim();
  // Cheap gate: a bundle is a JSON object, so it starts with `{`. A bare token
  // (`lin_oauth_…`) never does, and skipping the parse keeps the common legacy
  // path allocation-free.
  if (!trimmed.startsWith("{")) return null;

  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return null;
  }

  const record = parsed as {
    access_token?: unknown;
    refresh_token?: unknown;
    expires_at?: unknown;
  };
  const accessToken = record.access_token;
  if (typeof accessToken !== "string" || accessToken.trim() === "") return null;

  const bundle: LinearCredentialBundle = { access_token: accessToken };
  if (
    typeof record.refresh_token === "string" &&
    record.refresh_token.trim() !== ""
  ) {
    bundle.refresh_token = record.refresh_token;
  }
  if (typeof record.expires_at === "number" && Number.isFinite(record.expires_at)) {
    bundle.expires_at = record.expires_at;
  }
  return bundle;
}

/**
 * Build the credential bundle a token response seals into (charter D90).
 *
 * `expires_at` is derived HERE (`now + expires_in*1000`) so the stored value is an
 * absolute instant; a response with no `expires_in` (Linear always sends one, but a
 * stub or a future provider might not) simply omits it, and an omitted `expires_at`
 * is treated as "unknown → refreshable" downstream.
 */
export function buildLinearBundle(
  token: LinearTokenResponse,
  now: number,
): LinearCredentialBundle {
  const accessToken = token.access_token ?? "";
  const bundle: LinearCredentialBundle = { access_token: accessToken };
  if (token.refresh_token) bundle.refresh_token = token.refresh_token;
  if (typeof token.expires_in === "number" && Number.isFinite(token.expires_in)) {
    bundle.expires_at = now + token.expires_in * 1000;
  }
  return bundle;
}

export interface LinearCodeExchangeOptions {
  clientId: string;
  clientSecret: string;
  redirectUri: string;
  /** Injectable for tests; defaults to the global fetch. */
  fetch?: typeof fetch;
  /** Override the token endpoint (tests point it at a local recorder). */
  oauthTokenUrl?: string;
}

/**
 * Exchange the one-time `code` for the workspace's Linear access token.
 *
 * `grant_type=authorization_code`; `client_secret` goes in the POST BODY, never
 * the URL — a query string lands in access logs and proxy history. Linear answers
 * 200 with the token, or a non-2xx / `{error}` on a bad code; both are refusals
 * and neither may install anything.
 */
export async function exchangeLinearCode(
  code: string,
  options: LinearCodeExchangeOptions,
): Promise<LinearTokenResponse> {
  const doFetch = options.fetch ?? fetch;
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: options.clientId,
    client_secret: options.clientSecret,
    code,
    redirect_uri: options.redirectUri,
  });

  let response: Response;
  try {
    response = await doFetch(options.oauthTokenUrl ?? LINEAR_OAUTH_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });
  } catch (error) {
    return {
      error: "network",
      error_description: error instanceof Error ? error.message : String(error),
    };
  }

  if (!response.ok) {
    return { error: `linear oauth token HTTP ${response.status}` };
  }

  try {
    return (await response.json()) as LinearTokenResponse;
  } catch {
    return { error: "linear oauth token: non-JSON body" };
  }
}

/** What `organization { id urlKey }` returns — the identity of the connected org. */
export interface LinearOrganization {
  /** Immutable — the install key (D79). */
  id: string;
  /** Admin-renameable — feeds `displayName` ONLY (D79). */
  urlKey: string;
}

export interface LinearOrganizationOptions {
  fetch?: typeof fetch;
  /** Override the GraphQL endpoint (tests point it at a local recorder). */
  graphqlUrl?: string;
}

/**
 * Derive the install identity from ONE argument-free GraphQL round trip (D79).
 *
 * `organization { id urlKey }` against Linear's GraphQL API with the OAuth access
 * token as a Bearer. Returns `null` on any failure — unreachable, non-2xx, GraphQL
 * `errors`, or a missing/blank `id` — so the callback installs NOTHING for an
 * organization it could not identify. `id` is immutable (the key); `urlKey` is
 * display-only.
 */
export async function fetchLinearOrganization(
  accessToken: string,
  options: LinearOrganizationOptions = {},
): Promise<LinearOrganization | null> {
  const doFetch = options.fetch ?? fetch;

  let response: Response;
  try {
    response = await doFetch(options.graphqlUrl ?? LINEAR_GRAPHQL_URL, {
      method: "POST",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ query: "{ organization { id urlKey } }" }),
    });
  } catch {
    return null;
  }

  if (!response.ok) return null;

  let payload: {
    data?: { organization?: { id?: unknown; urlKey?: unknown } | null } | null;
    errors?: unknown;
  };
  try {
    payload = (await response.json()) as typeof payload;
  } catch {
    return null;
  }

  // A GraphQL 200 can still carry `errors` (e.g. an expired token). Fail closed.
  if (payload.errors !== undefined && payload.errors !== null) return null;

  const org = payload.data?.organization;
  const id = org?.id;
  if (typeof id !== "string" || id.trim() === "") return null;
  const urlKey = typeof org?.urlKey === "string" ? org.urlKey : "";

  return { id, urlKey };
}

export interface LinearOAuthCallbackDeps {
  clientId: string;
  clientSecret: string;
  /** MUST byte-match the redirect URL registered in the Linear OAuth app. */
  redirectUri: string;
  /** The connect-ticket HMAC key that makes the workspace binding unforgeable. */
  stateSecret: string;
  /**
   * THE INCUMBENT-OWNER CHECK (connectors D64). `tenant/installs.ts#resolveWorkspace`
   * reads `workspace_id` ALONE for `(provider, installKey)`. `upsertInstall`
   * repoints `workspace_id` unconditionally, so without this an attacker with a
   * valid state for their OWN workspace could re-auth a Linear org another tenant
   * owns and REPOINT the victim's row. Returns the owning workspace, or null when
   * nobody owns the key yet.
   */
  resolveWorkspace(
    provider: string,
    installKey: string,
  ): Promise<WorkspaceId | null>;
  /**
   * Write the install row. `tenant/installs.ts#upsertInstall`. A tool install
   * carries ONLY `credentialRef` (the sealed access token) — NEVER a `chatToken`
   * (its `chat_token_ref` stays NULL, D78).
   */
  upsertInstall(install: ConnectorInstall): Promise<void>;
  /**
   * Seal the access token for `credential_ref`. Defaults to identity because the
   * production `upsertInstall` seals the column itself (`createInstallsLookup(pool,
   * cipher)`), so the callback hands it PLAINTEXT. The hook survives only for a
   * test that supplies a non-sealing `upsertInstall`.
   */
  sealCredential?(accessToken: string): string | Promise<string>;
  fetch?: typeof fetch;
  oauthTokenUrl?: string;
  graphqlUrl?: string;
  now?: () => number;
}

/** What the callback did, for the caller to log/render. Never carries the token. */
export interface LinearOAuthCallbackResult {
  status: number;
  installed: boolean;
  installKey?: string;
  workspaceId?: WorkspaceId;
  displayName?: string;
  error?: string;
}

/**
 * `GET /connectors/oauth/linear/callback` — the whole tool install, end to end.
 *
 * A pure(ish) function of the Request, returning a typed result: the HTTP seam
 * mounts it as a route, and the test drives it directly. Every failure path
 * installs NOTHING — a half-written install row is a tenant with a token and no
 * owner. The order is load-bearing: refuse on `error=` → verify the ticket BEFORE
 * spending the code → exchange → derive the immutable install key → the D64
 * incumbent check BEFORE any write → ONE upsert.
 */
export async function handleLinearOAuthCallback(
  request: Request,
  deps: LinearOAuthCallbackDeps,
): Promise<LinearOAuthCallbackResult> {
  const url = new URL(request.url);

  // The user hit "Cancel", or Linear refused. Nothing to install.
  const denied = url.searchParams.get("error");
  if (denied) {
    return {
      status: 400,
      installed: false,
      error: `linear denied the install: ${denied}`,
    };
  }

  const code = url.searchParams.get("code");
  if (!code) {
    return { status: 400, installed: false, error: "missing code" };
  }

  // The workspace binding — a signed CONNECT TICKET, verified BEFORE the code is
  // spent, so a forged state never even reaches Linear. Unlike Slack there is no
  // nonce join (a tool install has no chat token to stage — D78), so the ticket's
  // workspace binding is the whole authorization.
  let workspaceId: WorkspaceId;
  try {
    const ticket = verifyConnectTicket(
      url.searchParams.get("state"),
      deps.stateSecret,
      {
        provider: LINEAR_PROVIDER,
        ...(deps.now ? { now: deps.now } : {}),
      },
    );
    workspaceId = ticket.workspaceId;
  } catch (err) {
    return {
      status: 400,
      installed: false,
      error: err instanceof Error ? err.message : "invalid state",
    };
  }

  const exchange = await exchangeLinearCode(code, {
    clientId: deps.clientId,
    clientSecret: deps.clientSecret,
    redirectUri: deps.redirectUri,
    ...(deps.fetch ? { fetch: deps.fetch } : {}),
    ...(deps.oauthTokenUrl ? { oauthTokenUrl: deps.oauthTokenUrl } : {}),
  });

  if (exchange.error || !exchange.access_token) {
    return {
      status: 400,
      installed: false,
      error: `linear oauth exchange failed: ${
        exchange.error_description ?? exchange.error ?? "no access_token"
      }`,
    };
  }

  // The install key is the IMMUTABLE organization id (D79), derived from the token
  // — never caller-supplied. One argument-free GraphQL round trip.
  const org = await fetchLinearOrganization(exchange.access_token, {
    ...(deps.fetch ? { fetch: deps.fetch } : {}),
    ...(deps.graphqlUrl ? { graphqlUrl: deps.graphqlUrl } : {}),
  });
  if (org === null) {
    return {
      status: 400,
      installed: false,
      error:
        "linear accepted the token but its organization could not be identified, " +
        "so the install cannot be keyed. Refusing to install an unidentifiable credential.",
    };
  }
  const installKey = org.id;

  // THE INCUMBENT-OWNER CHECK (D64), BEFORE any write. `resolveWorkspace` reads
  // `workspace_id` alone, so a row whose seal no longer opens still guards its
  // tenant. An org another workspace owns is a typed 409 — never a silent takedown
  // via the unconditional `workspace_id = EXCLUDED.workspace_id`.
  const owner = await deps.resolveWorkspace(LINEAR_PROVIDER, installKey);
  if (owner !== null && owner !== workspaceId) {
    return {
      status: 409,
      installed: false,
      installKey,
      error:
        "install_owned_elsewhere: that Linear organization is already connected to a " +
        "different Barkpark workspace. Disconnect it there first.",
    };
  }

  const seal = deps.sealCredential ?? ((token: string) => token);
  // A TOOL install carries ONLY the sealed credential as `credential_ref` — NO
  // `chatToken` key, so `chat_token_ref` stays NULL (D78). The credential is now a
  // JSON BUNDLE `{access_token, refresh_token?, expires_at?}` (D90), not the bare
  // token D80 shipped: `refresh_token` is what lets `tool-headers` re-token before
  // expiry, and `expires_at` is what tells it when. The generic read-path extracts
  // `.access_token` for the `Bearer` (D89), so the MCP bearer is unchanged — the
  // bundle is additive, and a bare-string legacy install still opens byte-for-byte.
  const now = deps.now?.() ?? Date.now();
  const bundle = buildLinearBundle(exchange, now);
  const install: ConnectorInstall = {
    provider: LINEAR_PROVIDER,
    installKey,
    workspaceId,
    credentialRef: await seal(JSON.stringify(bundle)),
  };

  await deps.upsertInstall(install);
  // NO mount (D78): a tool connector is never a channel. The write IS the connect.

  return {
    status: 200,
    installed: true,
    installKey,
    workspaceId,
    ...(org.urlKey ? { displayName: org.urlKey } : {}),
  };
}
