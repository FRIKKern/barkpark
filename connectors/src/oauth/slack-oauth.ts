import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

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
 * HOW THE WORKSPACE IS BOUND — AND WHY THE `state` MUST BE SIGNED
 * ─────────────────────────────────────────────────────────────────────────────
 * Slack's callback tells us WHICH SLACK TEAM installed the app. It cannot tell us
 * which BARKPARK WORKSPACE that install belongs to — only the operator who
 * started the flow knows that. So the workspace rides the OAuth `state`
 * round-trip.
 *
 * An UNSIGNED state is an open tenant-assignment hole: anyone who can get a user
 * to hit `…/callback?code=…&state=<victim-workspace>` mounts their Slack team
 * inside someone else's workspace, and from then on their messages open Sessions
 * there. So `state` is HMAC-SHA256(workspaceId | nonce | issuedAt) with a
 * bridge-held secret, compared in constant time, and expired after 10 minutes.
 * The bridge is the only party that can mint one.
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

/** How long a minted `state` stays valid. Long enough to click through, no longer. */
export const OAUTH_STATE_TTL_MS = 10 * 60 * 1000;

export class SlackOAuthStateError extends Error {
  constructor(message: string) {
    super(`slack oauth state: ${message}`);
    this.name = "SlackOAuthStateError";
  }
}

function base64url(input: Buffer): string {
  return input.toString("base64url");
}

function hmac(secret: string, body: string): Buffer {
  return createHmac("sha256", secret).update(body).digest();
}

/**
 * Mint an integrity-protected `state` binding this install flow to ONE workspace.
 *
 * Wire shape: `<base64url(json)>.<base64url(hmac-sha256)>`. The payload is
 * readable (it is not a secret — it is a workspace id the operator already knows);
 * it is the SIGNATURE that makes it unforgeable. The nonce keeps two flows for the
 * same workspace from producing an identical, replayable string.
 */
export function signOAuthState(
  workspaceId: WorkspaceId,
  stateSecret: string,
  options: { now?: () => number; nonce?: string } = {},
): string {
  if (!stateSecret || stateSecret.trim() === "") {
    throw new SlackOAuthStateError(
      "a state secret is required — an unsigned state lets anyone mount their " +
        "Slack team into another tenant's workspace",
    );
  }
  if (!workspaceId || workspaceId.trim() === "") {
    throw new SlackOAuthStateError("workspaceId is required");
  }

  const payload = JSON.stringify({
    w: workspaceId,
    n: options.nonce ?? base64url(randomBytes(12)),
    t: (options.now ?? Date.now)(),
  });
  const body = base64url(Buffer.from(payload, "utf8"));
  return `${body}.${base64url(hmac(stateSecret, body))}`;
}

/**
 * Verify a `state` and return the workspace it was minted for.
 *
 * Throws on ANY doubt — bad shape, bad signature, expired. The caller answers 400
 * and installs nothing: an install we cannot attribute to a workspace must never
 * be written, because the only alternatives are guessing a tenant or leaving an
 * orphan row that a later flow could adopt.
 */
export function verifyOAuthState(
  state: string | null | undefined,
  stateSecret: string,
  options: { now?: () => number; maxAgeMs?: number } = {},
): WorkspaceId {
  if (!state || state.trim() === "") {
    throw new SlackOAuthStateError("missing");
  }

  const dot = state.indexOf(".");
  if (dot <= 0 || dot === state.length - 1) {
    throw new SlackOAuthStateError("malformed");
  }

  const body = state.slice(0, dot);
  const signature = Buffer.from(state.slice(dot + 1), "base64url");
  const expected = hmac(stateSecret, body);

  // Length-check first: timingSafeEqual THROWS on a length mismatch, and an
  // attacker-supplied signature controls that length.
  if (
    signature.length !== expected.length ||
    !timingSafeEqual(signature, expected)
  ) {
    throw new SlackOAuthStateError("bad signature — not minted by this bridge");
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
  } catch {
    throw new SlackOAuthStateError("malformed payload");
  }

  if (typeof parsed !== "object" || parsed === null) {
    throw new SlackOAuthStateError("malformed payload");
  }
  const { w, t } = parsed as { w?: unknown; t?: unknown };
  if (typeof w !== "string" || w.trim() === "") {
    throw new SlackOAuthStateError("no workspace bound");
  }
  if (typeof t !== "number") {
    throw new SlackOAuthStateError("no issued-at");
  }

  const now = (options.now ?? Date.now)();
  const maxAgeMs = options.maxAgeMs ?? OAUTH_STATE_TTL_MS;
  // A future-dated state is as suspicious as an expired one (clock skew or a
  // replay with a tampered — but somehow valid — payload).
  if (now - t > maxAgeMs || t - now > maxAgeMs) {
    throw new SlackOAuthStateError("expired");
  }

  return w;
}

export interface SlackInstallUrlOptions {
  clientId: string;
  redirectUri: string;
  workspaceId: WorkspaceId;
  stateSecret: string;
  scopes?: readonly string[];
  now?: () => number;
  nonce?: string;
}

/** The "Add to Slack" URL for ONE workspace, carrying its signed state. */
export function buildSlackInstallUrl(options: SlackInstallUrlOptions): string {
  const url = new URL(SLACK_AUTHORIZE_URL);
  url.searchParams.set("client_id", options.clientId);
  url.searchParams.set("scope", (options.scopes ?? SLACK_BOT_SCOPES).join(","));
  url.searchParams.set("redirect_uri", options.redirectUri);
  url.searchParams.set(
    "state",
    signOAuthState(options.workspaceId, options.stateSecret, {
      ...(options.now ? { now: options.now } : {}),
      ...(options.nonce ? { nonce: options.nonce } : {}),
    }),
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
  /** The HMAC key that makes the workspace binding unforgeable. */
  stateSecret: string;
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
   * point; defaults to identity, which is the honest current state of the column
   * (plaintext — see `tenant/installs.ts`).
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

  // The workspace binding — verified BEFORE the code is spent, so a forged state
  // never even reaches Slack.
  let workspaceId: WorkspaceId;
  try {
    workspaceId = verifyOAuthState(
      url.searchParams.get("state"),
      deps.stateSecret,
      {
        ...(deps.now ? { now: deps.now } : {}),
      },
    );
  } catch (err) {
    return {
      status: 400,
      installed: false,
      error: err instanceof Error ? err.message : "invalid state",
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

  const seal = deps.sealCredential ?? ((token: string) => token);
  const install: ConnectorInstall = {
    provider: SLACK_PROVIDER,
    installKey,
    workspaceId,
    credentialRef: await seal(exchange.access_token),
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
