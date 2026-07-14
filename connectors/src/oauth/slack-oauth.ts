import {
  signConnectTicket,
  verifyConnectTicket,
  type SignConnectTicketOptions,
} from "../connect/ticket.js";
import type { ConnectorInstall, WorkspaceId } from "../connector/types.js";
import { SLACK_PROVIDER, slackInstallKey } from "../connectors/slack.js";

/**
 * Add-to-Slack — the OAuth v2 install flow (charter D40).
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * WHY THIS DOES NOT CALL `adapter.handleOAuthCallback()`
 * ─────────────────────────────────────────────────────────────────────────────
 * The SDK's `SlackAdapter.handleOAuthCallback` looks like the obvious seam, and
 * it is a trap on two counts (read it: `@chat-adapter/slack` index.js, the
 * `handleOAuthCallback` body):
 *
 *   1. It ends in `await this.setInstallation(teamId, installation)` — writing
 *      the bot token into the SDK's OWN state-pg rows, sealed by
 *      `@chat-adapter/shared`'s no-AAD `encryptToken`. That is a SECOND home for
 *      a credential we deliberately keep in exactly one place
 *      (`connector_installs`). There is no flag to skip it.
 *   2. It returns only `{ teamId, installation }` — the `enterprise` and
 *      `is_enterprise_install` fields of Slack's `oauth.v2.access` response are
 *      DISCARDED. An Enterprise Grid org-wide install must be keyed by
 *      `enterprise_id` (that is the `installationId` the SDK itself later passes
 *      to `getInstallation`), so keying it by `team_id` would strand every
 *      org-wide event on a fail-closed drop.
 *
 * So the code exchange is done here against Slack's documented public endpoint.
 * It is one form POST; the SDK's version is the same call plus the two problems
 * above.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * HOW THE WORKSPACE IS BOUND — AND WHY THE `state` IS A SIGNED CONNECT TICKET
 * ─────────────────────────────────────────────────────────────────────────────
 * Slack's callback tells us WHICH SLACK TEAM installed the app. It cannot tell us
 * which BARKPARK WORKSPACE that install belongs to — only the operator who
 * started the flow knows that. So the workspace rides the OAuth `state`
 * round-trip.
 *
 * An UNSIGNED state is an open tenant-assignment hole: anyone who can get a user
 * to hit `…/callback?code=…&state=<victim-workspace>` mounts their Slack team
 * inside someone else's workspace, and from then on their messages open Sessions
 * there. So the `state` IS a `connect/ticket.ts` CONNECT TICKET — the same
 * HMAC-signed `{w,p,n,t}` primitive Studio mints for the paste flow (connectors
 * D65). One signer, one verifier, one golden vector across two languages: the
 * Elixir Studio catalog signs a `{w,p:"slack",n,t}` ticket and this module
 * verifies it with `provider:"slack"`. That unification is why the ticket's
 * `nonce` is available here to JOIN the pending-connect row (D63) — the OAuth
 * `state` and the loopback-staged chat token share ONE nonce.
 *
 * NAMED BEHAVIOUR DELTA (connectors D65): the connect ticket tolerates future
 * clock-skew of only 30 s (`CONNECT_TICKET_MAX_SKEW_MS`), where the retired
 * `verifyOAuthState` tolerated the full 10-minute TTL in both directions. No
 * existing test future-dates a Slack state, so the tighten is invisible except in
 * the (correct) direction.
 */

/** Slack's authorize endpoint (where "Add to Slack" points). */
const SLACK_AUTHORIZE_URL = "https://slack.com/oauth/v2/authorize";
/** Slack's public token-exchange endpoint. */
const SLACK_OAUTH_ACCESS_URL = "https://slack.com/api/oauth.v2.access";

/** The route Slack redirects back to. Registered in the Slack app's manifest. */
export const SLACK_OAUTH_CALLBACK_PATH = "/connectors/oauth/slack/callback";

/**
 * The bot scopes the app requests. Kept in code (not just the manifest doc) so
 * the install URL and `connectors/docs/slack-install.md` can never drift.
 */
export const SLACK_BOT_SCOPES: readonly string[] = [
  "app_mentions:read",
  "channels:history",
  "channels:read",
  "chat:write",
  "groups:history",
  "groups:read",
  "im:history",
  "im:read",
  "mpim:history",
  "mpim:read",
  "reactions:read",
  "reactions:write",
  "users:read",
];

export interface SlackInstallUrlOptions {
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
 * The "Add to Slack" URL for ONE workspace, carrying a signed connect ticket as
 * its `state`.
 *
 * The bridge itself has no reason to build this in production — the Elixir Studio
 * catalog does, so it can stage the pending-connect row under the SAME nonce
 * first. This exists so the wire has one executable definition and a smoke script
 * can drive the flow without Studio.
 */
export function buildSlackInstallUrl(options: SlackInstallUrlOptions): string {
  const url = new URL(SLACK_AUTHORIZE_URL);
  url.searchParams.set("client_id", options.clientId);
  url.searchParams.set("scope", (options.scopes ?? SLACK_BOT_SCOPES).join(","));
  url.searchParams.set("redirect_uri", options.redirectUri);

  const ticketOptions: SignConnectTicketOptions = {};
  if (options.now) ticketOptions.now = options.now;
  if (options.nonce) ticketOptions.nonce = options.nonce;
  url.searchParams.set(
    "state",
    signConnectTicket(
      options.workspaceId,
      SLACK_PROVIDER,
      options.stateSecret,
      ticketOptions,
    ),
  );
  return url.toString();
}

/** The subset of Slack's `oauth.v2.access` response the bridge depends on. */
export interface SlackOAuthAccessResponse {
  ok: boolean;
  error?: string;
  access_token?: string;
  bot_user_id?: string;
  is_enterprise_install?: boolean;
  team?: { id?: string; name?: string } | null;
  enterprise?: { id?: string; name?: string } | null;
}

export interface SlackCodeExchangeOptions {
  clientId: string;
  clientSecret: string;
  redirectUri: string;
  /** Injectable for tests; defaults to the global fetch. */
  fetch?: typeof fetch;
  /** Override the token endpoint (tests point it at a local recorder). */
  oauthAccessUrl?: string;
}

/**
 * Exchange the one-time `code` for the workspace's bot token.
 *
 * `client_secret` goes in the POST BODY, never the URL — a query string lands in
 * access logs and proxy history.
 */
export async function exchangeSlackCode(
  code: string,
  options: SlackCodeExchangeOptions,
): Promise<SlackOAuthAccessResponse> {
  const doFetch = options.fetch ?? fetch;
  const body = new URLSearchParams({
    client_id: options.clientId,
    client_secret: options.clientSecret,
    code,
    redirect_uri: options.redirectUri,
  });

  const response = await doFetch(options.oauthAccessUrl ?? SLACK_OAUTH_ACCESS_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });

  // Slack answers 200 with `{ok:false,error:…}` for a bad code; a non-200 is a
  // transport failure. Both are refusals, and neither may install anything.
  if (!response.ok) {
    return { ok: false, error: `slack oauth.v2.access HTTP ${response.status}` };
  }
  return (await response.json()) as SlackOAuthAccessResponse;
}

/**
 * Derive the install key from an `oauth.v2.access` response.
 *
 * `enterprise_id` ONLY when `is_enterprise_install` is true. Slack also sends an
 * `enterprise` object for a WORKSPACE-level install inside a Grid — and there the
 * install id is still the team id. Keying on `enterprise` unconditionally would
 * collapse every workspace of one Grid onto a single install row: one tenant's
 * bot token serving all of them. That is the exact bug this narrow condition
 * exists to prevent, and it mirrors the SDK's own inbound derivation
 * (`is_enterprise_install ? payload.enterprise_id : payload.team_id`).
 */
export function installKeyFromOAuth(
  response: SlackOAuthAccessResponse,
): string | null {
  return slackInstallKey({
    enterpriseId: response.is_enterprise_install
      ? (response.enterprise?.id ?? null)
      : null,
    teamId: response.team?.id ?? null,
  });
}

export interface SlackOAuthCallbackDeps {
  clientId: string;
  clientSecret: string;
  /** MUST byte-match the redirect URL registered in the Slack app. */
  redirectUri: string;
  /** The connect-ticket HMAC key that makes the workspace binding unforgeable. */
  stateSecret: string;
  /**
   * Consume the LOOPBACK-staged pending-connect row by the ticket's `nonce`
   * (`connect/pending-connect.ts#consumePendingConnect`), returning the OPENED
   * chat token this workspace's traffic will authenticate with — single-use, so a
   * replayed callback consumes it at most once.
   *
   * A missing/expired row is `null`, and the callback then installs NOTHING: the
   * bridge cannot mint a chat token itself (D48), so an install with no chat token
   * would be a routable-but-unreachable tenant. Fail closed.
   */
  consumePendingConnect(
    nonce: string,
  ): Promise<{ workspaceId: WorkspaceId; chatToken: string } | null>;
  /**
   * THE INCUMBENT-OWNER CHECK (connectors D64). `tenant/installs.ts#resolveWorkspace`
   * reads `workspace_id` ALONE for `(provider, installKey)`. This is a PUBLIC entry
   * and `UPSERT_INSTALL` repoints `workspace_id` unconditionally, so without this
   * an attacker with a valid state for their OWN workspace could re-auth a Slack
   * team another tenant owns and REPOINT the victim's row. Returns the owning
   * workspace, or null when nobody owns the key yet.
   */
  resolveWorkspace(
    provider: string,
    installKey: string,
  ): Promise<WorkspaceId | null>;
  /** Write (or replace) the install row. `tenant/installs.ts#upsertInstall`. */
  upsertInstall(install: ConnectorInstall): Promise<void>;
  /**
   * Mount the install into the RUNNING bridge — `Bridge.mount`. This is what
   * makes the connect button feel like a button: the team can message the bot the
   * second the callback returns, with no restart and no deploy.
   */
  mountInstall(install: ConnectorInstall): Promise<unknown>;
  /**
   * Seal the bot token for `credential_ref`. The credential-cipher injection
   * point; defaults to identity because the production `upsertInstall` seals both
   * columns itself (`createInstallsLookup(pool, cipher)` — D35/D37), so the
   * callback hands it PLAINTEXT. The hook survives only for a test that supplies a
   * non-sealing `upsertInstall`.
   */
  sealCredential?(botToken: string): string | Promise<string>;
  fetch?: typeof fetch;
  oauthAccessUrl?: string;
  now?: () => number;
}

/** What the callback did, for the caller to log/render. Never carries the token. */
export interface SlackOAuthCallbackResult {
  status: number;
  installed: boolean;
  installKey?: string;
  workspaceId?: WorkspaceId;
  teamName?: string;
  error?: string;
}

/**
 * `GET /connectors/oauth/slack/callback` — the whole install, end to end.
 *
 * A pure(ish) function of the Request, returning a typed result: an HTTP seam can
 * mount it as a route, and the test drives it directly. Every failure path
 * installs NOTHING — a half-written install row is a tenant with a bot token and
 * no owner.
 */
export async function handleSlackOAuthCallback(
  request: Request,
  deps: SlackOAuthCallbackDeps,
): Promise<SlackOAuthCallbackResult> {
  const url = new URL(request.url);

  // The user hit "Cancel", or Slack refused. Nothing to install.
  const denied = url.searchParams.get("error");
  if (denied) {
    return {
      status: 400,
      installed: false,
      error: `slack denied the install: ${denied}`,
    };
  }

  const code = url.searchParams.get("code");
  if (!code) {
    return { status: 400, installed: false, error: "missing code" };
  }

  // The workspace binding — a signed CONNECT TICKET, verified BEFORE the code is
  // spent, so a forged state never even reaches Slack. The ticket also carries the
  // `nonce` that joins the loopback-staged pending-connect row.
  let workspaceId: WorkspaceId;
  let nonce: string;
  try {
    const ticket = verifyConnectTicket(
      url.searchParams.get("state"),
      deps.stateSecret,
      {
        provider: SLACK_PROVIDER,
        ...(deps.now ? { now: deps.now } : {}),
      },
    );
    workspaceId = ticket.workspaceId;
    nonce = ticket.nonce;
  } catch (err) {
    return {
      status: 400,
      installed: false,
      error: err instanceof Error ? err.message : "invalid state",
    };
  }

  if (!nonce || nonce.trim() === "") {
    // A ticket with no nonce cannot join a pending row — there is no chat token to
    // install, and the bridge cannot mint one (D48). Fail closed.
    return {
      status: 400,
      installed: false,
      error: "connect ticket carried no nonce",
    };
  }

  const exchange = await exchangeSlackCode(code, {
    clientId: deps.clientId,
    clientSecret: deps.clientSecret,
    redirectUri: deps.redirectUri,
    ...(deps.fetch ? { fetch: deps.fetch } : {}),
    ...(deps.oauthAccessUrl ? { oauthAccessUrl: deps.oauthAccessUrl } : {}),
  });

  if (!exchange.ok || !exchange.access_token) {
    return {
      status: 400,
      installed: false,
      error: `slack oauth exchange failed: ${exchange.error ?? "no access_token"}`,
    };
  }

  const installKey = installKeyFromOAuth(exchange);
  if (!installKey) {
    // No team id and no enterprise id: nothing to key the row on, so there is no
    // safe row to write.
    return {
      status: 400,
      installed: false,
      error: "slack returned no team or enterprise id",
    };
  }

  // THE INCUMBENT-OWNER CHECK (D64), BEFORE we consume the pending row or write
  // anything. `resolveWorkspace` reads `workspace_id` alone, so a row whose seals
  // no longer open still guards its tenant. A key another workspace owns is a typed
  // 409 — never a silent takedown of the incumbent's install via the unconditional
  // `workspace_id = EXCLUDED.workspace_id`.
  const owner = await deps.resolveWorkspace(SLACK_PROVIDER, installKey);
  if (owner !== null && owner !== workspaceId) {
    return {
      status: 409,
      installed: false,
      installKey,
      error:
        "install_owned_elsewhere: that Slack team is already connected to a " +
        "different Barkpark workspace. Disconnect it there first.",
    };
  }

  // Join the loopback-staged pending row by the ticket's nonce (D63). This is
  // where the workspace-bound chat token — which only Studio could mint — enters
  // the flow. Single-use: consuming deletes the row. Missing/expired ⇒ fail closed.
  const pending = await deps.consumePendingConnect(nonce);
  if (pending === null) {
    return {
      status: 400,
      installed: false,
      installKey,
      error:
        "this connect session has expired or was already used — start again from " +
        "the Studio Connectors page.",
    };
  }

  // Defence in depth: the workspace the ticket authorises and the workspace the
  // pending row was staged for MUST agree. They are minted together by Studio, so
  // a mismatch is either a bug or a crossed-wire attack — either way, install
  // nothing.
  if (pending.workspaceId !== workspaceId) {
    return {
      status: 400,
      installed: false,
      installKey,
      error: "connect session workspace mismatch",
    };
  }

  const seal = deps.sealCredential ?? ((token: string) => token);
  const install: ConnectorInstall = {
    provider: SLACK_PROVIDER,
    installKey,
    workspaceId,
    // BOTH secrets in ONE write (D63): a non-blank credential AND a non-blank chat
    // token fire the `EXCLUDED IS NOT NULL` arm for both columns, so the sibling
    // preserve never runs on the Slack path and a fresh install lands with both
    // columns populated (the D61 fresh-install-NULL gap, closed).
    credentialRef: await seal(exchange.access_token),
    chatToken: pending.chatToken,
  };

  await deps.upsertInstall(install);
  // Live immediately — the point of the dynamic mount.
  await deps.mountInstall(install);

  return {
    status: 200,
    installed: true,
    installKey,
    workspaceId,
    ...(exchange.team?.name ? { teamName: exchange.team.name } : {}),
  };
}
