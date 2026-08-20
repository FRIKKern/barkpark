import type { ConnectorInstall, RefreshContext } from "../connector/types.js";
import {
  buildLinearBundle,
  parseLinearBundle,
  type LinearCredentialBundle,
  type LinearTokenResponse,
} from "./linear-oauth.js";

/**
 * Linear OAuth token refresh (charter D90/D91/D92) — the CONNECTOR-OWNED half of
 * the dual-shape credential seam.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * WHY THIS EXISTS
 * ─────────────────────────────────────────────────────────────────────────────
 * D80 sealed the BARE Linear access token as `credential_ref`, with a NAMED
 * consequence: Linear OAuth access tokens live ~24h (`expires_in: 86399`), so an
 * expired install opens fine at connect and then 401s INVISIBLY at the provider —
 * the bridge only PRINTS headers into an MCP config, it never makes the tool call,
 * so it never sees the 401. There is nowhere to hang an on-401 retry. The only
 * place a refresh can honestly fire is at HEADER-BUILD time (`tool-headers`), BEFORE
 * the token is handed out, inside a skew window.
 *
 * So this module is the connector's `refreshCredential` hook (D92): given THIS
 * install's opened credential and the current time, it decides whether the token is
 * inside its skew window and, if so, exchanges a fresh one against
 * `api.linear.app/oauth/token` with `grant_type=refresh_token`. The shared
 * `tool-headers` route calls it generically and never learns Linear's bundle shape.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THREE THINGS THAT ARE LOAD-BEARING
 * ─────────────────────────────────────────────────────────────────────────────
 *  1. REFRESH TOKEN ROTATES (D91). Linear returns a NEW `refresh_token` on every
 *     refresh and the old one enters a ~30-min replay-grace window before it is
 *     rejected. So the fresh bundle MUST carry the new refresh token; storing the
 *     old one would spend a single-use grant twice and eventually brick the install.
 *  2. SINGLE-FLIGHT (D91, invented — no prior art). A runner re-connecting an MCP
 *     server can fire several `tool-headers` requests near-simultaneously; without
 *     de-duplication each would POST a refresh, and because the token rotates the
 *     LOSERS would exchange an already-superseded refresh token. An in-process
 *     promise-cache keyed `(provider, install_key)` collapses concurrent refreshes
 *     of the same install into ONE exchange — every caller awaits the same result.
 *     The cross-REPLICA double-exchange this cannot stop is exactly what Linear's
 *     30-min grace models; that residual is honestly named, not claimed away.
 *  3. FAIL LOUD, NEVER FAIL CLOSED (D90). A refusal or a network fault THROWS out of
 *     here; the `tool-headers` route catches it, logs loudly, and serves the STORED
 *     token (serve-stale-loud). A failed refresh must degrade to a maybe-stale
 *     header, never to a hard connect failure.
 *
 * The write-back is NOT done here: this hook returns the fresh PLAINTEXT bundle and
 * the route persists it via `upsertInstall` (which does the ONE seal — a pre-sealed
 * blob would double-seal). Blind LWW, never a pinned CAS: a rotating exchange is
 * non-replayable, so a lost pin would discard the fresh bundle and brick the
 * install (D91).
 */

/** Linear's token-exchange endpoint (`api.linear.app`, a DIFFERENT host from authorize). */
const LINEAR_OAUTH_TOKEN_URL = "https://api.linear.app/oauth/token";

/**
 * How close to `expires_at` a token may drift before `tool-headers` refreshes it
 * (charter D90). Mirrors `CONNECT_TICKET_MAX_SKEW_MS`'s named-constant style.
 *
 * One hour: comfortably wider than a single chat turn, so a token refreshed on ANY
 * (re)connect inside the last hour of its ~24h life carries a full fresh lifetime
 * through the session that follows. Wider than needed is cheap here (a refresh is
 * one POST and one blind upsert); the only cost of a too-NARROW window is a token
 * that expires mid-session and 401s invisibly, which is the exact failure D80 named
 * and this wave closes.
 */
export const LINEAR_TOKEN_REFRESH_SKEW_MS = 60 * 60 * 1000;

export interface LinearTokenRefreshDeps {
  clientId: string;
  clientSecret: string;
  /** Injectable for tests; defaults to the global fetch. */
  fetch?: typeof fetch;
  /** Override the token endpoint (tests point it at a rotating stub). */
  oauthTokenUrl?: string;
  /** Override the skew window (tests drive both branches with a fixed `now`). */
  skewMs?: number;
}

/**
 * True when a bundle is inside its skew window — expired, or expiring within
 * `skewMs`. A bundle with NO `expires_at` (unknown lifetime) is treated as
 * refreshable: better one unnecessary refresh than a silently-expired token.
 */
function needsRefresh(
  bundle: LinearCredentialBundle,
  now: number,
  skewMs: number,
): boolean {
  if (bundle.expires_at === undefined) return true;
  return bundle.expires_at - now < skewMs;
}

/**
 * The refresh exchange itself. Returns the FRESH PLAINTEXT bundle JSON, or THROWS
 * on any refusal (network, non-2xx, `{error}` body, or a response missing an
 * access token). The caller (`tool-headers`) turns a throw into serve-stale-loud.
 */
async function exchangeRefresh(
  refreshToken: string,
  deps: LinearTokenRefreshDeps,
  now: number,
): Promise<string> {
  const doFetch = deps.fetch ?? fetch;
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    client_id: deps.clientId,
    client_secret: deps.clientSecret,
    refresh_token: refreshToken,
  });

  let response: Response;
  try {
    response = await doFetch(deps.oauthTokenUrl ?? LINEAR_OAUTH_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });
  } catch (error) {
    throw new Error(
      `linear token refresh: could not reach ${deps.oauthTokenUrl ?? LINEAR_OAUTH_TOKEN_URL}: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
  }

  if (!response.ok) {
    throw new Error(`linear token refresh: HTTP ${response.status}`);
  }

  let token: LinearTokenResponse;
  try {
    token = (await response.json()) as LinearTokenResponse;
  } catch {
    throw new Error("linear token refresh: non-JSON body");
  }
  if (token.error || !token.access_token) {
    throw new Error(
      `linear token refresh refused: ${
        token.error_description ?? token.error ?? "no access_token"
      }`,
    );
  }

  // Linear ROTATES the refresh token per call (D91). Prefer the new one; keep the
  // one we just spent only if the response omitted it, so the bundle is never left
  // with NO refresh token when one was available.
  const rotated: LinearTokenResponse = {
    ...token,
    refresh_token: token.refresh_token ?? refreshToken,
  };
  return JSON.stringify(buildLinearBundle(rotated, now));
}

/** The composite single-flight key. JSON-encoded so no separator can collide. */
function flightKey(provider: string, installKey: string): string {
  return JSON.stringify([provider, installKey]);
}

/**
 * Build Linear's `refreshCredential` hook, closed over its client credentials and
 * its OWN single-flight cache (charter D92). Created once per connector instance
 * (`createLinearConnector`), so the cache lives for the process and de-duplicates
 * across every `tool-headers` call.
 */
export function createLinearTokenRefresher(
  deps: LinearTokenRefreshDeps,
): (install: ConnectorInstall, ctx: RefreshContext) => Promise<string | null> {
  const skewMs = deps.skewMs ?? LINEAR_TOKEN_REFRESH_SKEW_MS;
  // The single-flight promise-cache (D91, invented). An entry lives only while its
  // refresh is in flight — cleared on settle — so a LATER refresh of the same
  // install (its new token expiring in turn) starts fresh.
  const inFlight = new Map<string, Promise<string>>();

  return async function refreshCredential(
    install: ConnectorInstall,
    ctx: RefreshContext,
  ): Promise<string | null> {
    const raw = install.credentialRef;
    // Nothing stored, a bare-string legacy install, or a non-bundle credential:
    // NULL means "nothing to refresh, serve as-is". Never throws on legacy input.
    if (raw === null || raw === undefined || raw.trim() === "") return null;
    const bundle = parseLinearBundle(raw);
    if (bundle === null) return null;
    // A bundle with no refresh token cannot be refreshed (a paste-mode credential,
    // or a scope Linear did not issue one for). Serve it as-is until it is re-auth'd.
    if (bundle.refresh_token === undefined) return null;
    if (!needsRefresh(bundle, ctx.now, skewMs)) return null;

    const key = flightKey(install.provider, install.installKey);
    const existing = inFlight.get(key);
    if (existing) return existing;

    const flight = exchangeRefresh(bundle.refresh_token, deps, ctx.now).finally(
      () => {
        inFlight.delete(key);
      },
    );
    inFlight.set(key, flight);
    return flight;
  };
}
