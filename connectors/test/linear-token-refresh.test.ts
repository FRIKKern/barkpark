/**
 * LINEAR OAUTH TOKEN REFRESH (charter D89–D92) — the dual-shape credential seam.
 *
 * W8 sealed the BARE Linear access token (D80) with a named consequence: a ~24h
 * token opens fine at connect and then 401s INVISIBLY at the provider. W9 closes it
 * at HEADER-BUILD time with a connector-owned refresh, WITHOUT breaking the
 * zero-core-change invariant. This file proves the whole mechanism with NO network
 * and NO database — a rotating fetch stub models Linear's token endpoint (rotation +
 * 30-min replay grace), and the route is driven directly through
 * `handleConnectRequest`.
 *
 * THREE layers:
 *   1. `createLinearTokenRefresher` — the connector hook: skew-window decision,
 *      rotation, single-flight, throw-on-failure, and the two backward-compat NULLs
 *      (bare string, no-refresh-token bundle).
 *   2. the ROTATION + GRACE model — a fresh bundle carries the NEW refresh token;
 *      an old token succeeds within grace and is rejected outside it.
 *   3. `tool-headers` end-to-end — happy-path write-back (blind LWW, plaintext in,
 *      NO chatToken key) and serve-stale-LOUD on a refresh failure.
 *
 * The LIVE Linear refresh rides the human gate `connectors-linear-live-oauth-gate`,
 * never faked here.
 */
import { afterEach, describe, expect, it, vi } from "vitest";

import { signConnectTicket, TOOL_TICKET_PROVIDER } from "../src/connect/ticket.js";
import { createConnectorRegistry } from "../src/connector/registry.js";
import type { ConnectorInstall, WorkspaceId } from "../src/connector/types.js";
import { createLinearConnector } from "../src/connectors/linear.js";
import { handleConnectRequest, type ConnectDeps } from "../src/http/connect.js";
import {
  createLinearTokenRefresher,
  LINEAR_TOKEN_REFRESH_SKEW_MS,
} from "../src/oauth/linear-token-refresh.js";
import type { LinearCredentialBundle } from "../src/oauth/linear-oauth.js";
import { createInMemoryInstallsLookup } from "../src/tenant/installs.js";

const CLIENT = { clientId: "lin_client", clientSecret: "lin_secret" } as const;
const CONNECT_SECRET = "connect-secret-for-the-linear-refresh-test";
const WS_A = "aaaaaaaa-1111-4111-8111-111111111111";
const ORG_A = "12345678-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const NOW = 1_700_000_000_000;

const jsonResp = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

/** A stored credential bundle, JSON-serialised as it would sit in `credential_ref`. */
const bundle = (over: Partial<LinearCredentialBundle> = {}): string =>
  JSON.stringify({
    access_token: "at_0",
    refresh_token: "rt_0",
    expires_at: NOW,
    ...over,
  });

const installWith = (credentialRef: string): ConnectorInstall => ({
  provider: "linear",
  installKey: ORG_A,
  workspaceId: WS_A,
  credentialRef,
  chatToken: null,
});

/**
 * A fake Linear token endpoint that models `grant_type=refresh_token` with rotation
 * and a 30-min replay grace (D91):
 *   - the CURRENT refresh token is accepted and ROTATES to a fresh one;
 *   - the immediately-PREVIOUS token is accepted iff `grace` (Linear's ~30-min
 *     window), else rejected `invalid_grant`;
 *   - anything else is rejected.
 * `hits` records every call so a test can prove single-flight (exactly one).
 */
function rotatingLinearTokenStub(
  cfg: {
    hits?: string[];
    grace?: boolean;
    fail?: () => Response | null;
    initialRefresh?: string;
  } = {},
): typeof fetch {
  let counter = 0;
  let current = cfg.initialRefresh ?? "rt_0";
  let previous: string | null = null;
  return (async (input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    cfg.hits?.push(typeof input === "string" ? input : String(input));
    const forced = cfg.fail?.();
    if (forced) return forced;

    const body = new URLSearchParams(String(init?.body ?? ""));
    expect(body.get("grant_type")).toBe("refresh_token");
    // The client secret rides the BODY, never the URL.
    expect(body.get("client_secret")).toBe(CLIENT.clientSecret);
    const presented = body.get("refresh_token");
    const acceptable =
      presented === current || (cfg.grace === true && presented === previous);
    if (!acceptable) {
      return jsonResp({ error: "invalid_grant" }, 400);
    }
    counter += 1;
    previous = current;
    current = `rt_${counter}`;
    return jsonResp({
      access_token: `at_${counter}`,
      token_type: "Bearer",
      expires_in: 86399,
      refresh_token: current,
      scope: "read",
    });
  }) as unknown as typeof fetch;
}

// ── LAYER 1: the refresher hook ──────────────────────────────────────────────

describe("createLinearTokenRefresher — the connector's refresh hook (D90/D92)", () => {
  it("does NOT refresh a bundle comfortably inside its lifetime — returns null, no exchange", async () => {
    const hits: string[] = [];
    const refresh = createLinearTokenRefresher({
      ...CLIENT,
      fetch: rotatingLinearTokenStub({ hits }),
    });
    // 10h left, far beyond the 1h skew.
    const install = installWith(bundle({ expires_at: NOW + 10 * 3_600_000 }));
    expect(await refresh(install, { now: NOW })).toBeNull();
    expect(hits).toEqual([]);
  });

  it("refreshes a bundle INSIDE the skew window — fresh access_token, ROTATED refresh_token, updated expires_at", async () => {
    const hits: string[] = [];
    const refresh = createLinearTokenRefresher({
      ...CLIENT,
      fetch: rotatingLinearTokenStub({ hits }),
    });
    // 5 minutes left — inside the 1h skew (LINEAR_TOKEN_REFRESH_SKEW_MS).
    const install = installWith(bundle({ expires_at: NOW + 5 * 60_000 }));
    const fresh = await refresh(install, { now: NOW });
    expect(fresh).not.toBeNull();
    const parsed = JSON.parse(fresh as string) as LinearCredentialBundle;
    expect(parsed.access_token).toBe("at_1");
    // The refresh token ROTATED — the stale rt_0 is gone (D91).
    expect(parsed.refresh_token).toBe("rt_1");
    // expires_at re-derived as now + expires_in*1000 (epoch-ms).
    expect(parsed.expires_at).toBe(NOW + 86399 * 1000);
    expect(hits).toHaveLength(1);
  });

  it("refreshes an ALREADY-EXPIRED bundle (expires_at in the past)", async () => {
    const hits: string[] = [];
    const refresh = createLinearTokenRefresher({
      ...CLIENT,
      fetch: rotatingLinearTokenStub({ hits }),
    });
    const install = installWith(bundle({ expires_at: NOW - 1_000 }));
    const fresh = await refresh(install, { now: NOW });
    expect(JSON.parse(fresh as string).access_token).toBe("at_1");
    expect(hits).toHaveLength(1);
  });

  it("refreshes a bundle with NO expires_at — unknown lifetime is treated as refreshable", async () => {
    const refresh = createLinearTokenRefresher({
      ...CLIENT,
      fetch: rotatingLinearTokenStub({}),
    });
    const install = installWith(
      JSON.stringify({ access_token: "at_0", refresh_token: "rt_0" }),
    );
    expect(await refresh(install, { now: NOW })).not.toBeNull();
  });

  it("returns null for a BARE-STRING legacy credential — nothing to refresh, never throws (D89 backward-compat)", async () => {
    const hits: string[] = [];
    const refresh = createLinearTokenRefresher({
      ...CLIENT,
      fetch: rotatingLinearTokenStub({ hits }),
    });
    const install = installWith("lin_oauth_bare_access_token_from_before_W9");
    expect(await refresh(install, { now: NOW })).toBeNull();
    expect(hits).toEqual([]);
  });

  it("returns null for MALFORMED JSON — never throws, no exchange (D89)", async () => {
    const hits: string[] = [];
    const refresh = createLinearTokenRefresher({
      ...CLIENT,
      fetch: rotatingLinearTokenStub({ hits }),
    });
    const install = installWith('{ "access_token": ');
    expect(await refresh(install, { now: NOW })).toBeNull();
    expect(hits).toEqual([]);
  });

  it("returns null for a bundle with NO refresh_token — it cannot be refreshed", async () => {
    const hits: string[] = [];
    const refresh = createLinearTokenRefresher({
      ...CLIENT,
      fetch: rotatingLinearTokenStub({ hits }),
    });
    const install = installWith(
      JSON.stringify({ access_token: "at_0", expires_at: NOW }),
    );
    expect(await refresh(install, { now: NOW })).toBeNull();
    expect(hits).toEqual([]);
  });

  it("respects an injected skewMs override", async () => {
    const hits: string[] = [];
    const refresh = createLinearTokenRefresher({
      ...CLIENT,
      fetch: rotatingLinearTokenStub({ hits }),
      skewMs: 1_000, // 1s window
    });
    // 5 min left: OUTSIDE a 1s window, so no refresh.
    const install = installWith(bundle({ expires_at: NOW + 5 * 60_000 }));
    expect(await refresh(install, { now: NOW })).toBeNull();
    expect(hits).toEqual([]);
  });

  it("exports the skew constant as a positive number", () => {
    expect(LINEAR_TOKEN_REFRESH_SKEW_MS).toBeGreaterThan(0);
  });

  // ── SINGLE-FLIGHT ──────────────────────────────────────────────────────────

  it("single-flight: N concurrent refreshes of ONE install hit the token endpoint EXACTLY once (D91)", async () => {
    const hits: string[] = [];
    const refresh = createLinearTokenRefresher({
      ...CLIENT,
      fetch: rotatingLinearTokenStub({ hits }),
    });
    const install = installWith(bundle({ expires_at: NOW }));

    const results = await Promise.all(
      Array.from({ length: 8 }, () => refresh(install, { now: NOW })),
    );

    // Exactly ONE exchange despite eight concurrent callers.
    expect(hits).toHaveLength(1);
    // Every caller got the SAME fresh bundle.
    expect(new Set(results).size).toBe(1);
    expect(JSON.parse(results[0] as string).access_token).toBe("at_1");
  });

  it("single-flight clears after settle — a LATER refresh of the same install exchanges again", async () => {
    const hits: string[] = [];
    // grace=true so the SECOND sequential call (still presenting rt_0 — the literal
    // was never written back) is accepted; single-flight de-dupes CONCURRENT calls,
    // NOT sequential ones, so the endpoint is hit twice.
    const refresh = createLinearTokenRefresher({
      ...CLIENT,
      fetch: rotatingLinearTokenStub({ hits, grace: true }),
    });
    const install = installWith(bundle({ expires_at: NOW }));

    const first = await refresh(install, { now: NOW });
    const second = await refresh(install, { now: NOW });
    expect(JSON.parse(first as string).access_token).toBe("at_1");
    expect(JSON.parse(second as string).access_token).toBe("at_2");
    expect(hits).toHaveLength(2);
  });

  // ── ROTATION + 30-MIN GRACE (D91) ────────────────────────────────────────────

  it("an OLD refresh token succeeds WITHIN grace and is REJECTED outside it (Linear's 30-min window)", async () => {
    // WITHIN grace: a second replica still holding the old bundle refreshes and wins.
    const graceHits: string[] = [];
    const refreshG = createLinearTokenRefresher({
      ...CLIENT,
      fetch: rotatingLinearTokenStub({ hits: graceHits, grace: true }),
    });
    const install0 = installWith(bundle({ expires_at: NOW }));
    const first = await refreshG(install0, { now: NOW });
    expect(JSON.parse(first as string).refresh_token).toBe("rt_1");
    // The SAME old bundle (rt_0) refreshes again — accepted within grace.
    const withinGrace = await refreshG(install0, { now: NOW });
    expect(withinGrace).not.toBeNull();
    expect(graceHits).toHaveLength(2);

    // OUTSIDE grace: the stale token is rejected → the refresher THROWS (upstream
    // serve-stale-loud). Single-flight is per-instance, so a fresh refresher.
    const noGraceHits: string[] = [];
    const refreshN = createLinearTokenRefresher({
      ...CLIENT,
      fetch: rotatingLinearTokenStub({ hits: noGraceHits, grace: false }),
    });
    await refreshN(install0, { now: NOW }); // rotates rt_0 -> rt_1
    await expect(refreshN(install0, { now: NOW })).rejects.toThrow(/HTTP 400/);
    expect(noGraceHits).toHaveLength(2);
  });

  // ── SERVE-STALE-LOUD (D90): the refresher THROWS on failure ───────────────────

  it("THROWS on a refresh failure (HTTP 500) so the route can serve stale + log loud", async () => {
    const refresh = createLinearTokenRefresher({
      ...CLIENT,
      fetch: rotatingLinearTokenStub({
        fail: () => new Response("upstream boom", { status: 500 }),
      }),
    });
    const install = installWith(bundle({ expires_at: NOW }));
    await expect(refresh(install, { now: NOW })).rejects.toThrow(/HTTP 500/);
  });

  it("THROWS on a network fault", async () => {
    const refresh = createLinearTokenRefresher({
      ...CLIENT,
      fetch: (async () => {
        throw new Error("ECONNREFUSED");
      }) as unknown as typeof fetch,
    });
    const install = installWith(bundle({ expires_at: NOW }));
    await expect(refresh(install, { now: NOW })).rejects.toThrow(/could not reach/);
  });
});

// ── LAYER 3: tool-headers end-to-end (no DB, in-memory installs) ──────────────

describe("tool-headers refresh leg — write-back + serve-stale-loud (D89/D90/D91)", () => {
  // Signed AT `NOW` so it verifies under `deps.now = () => NOW` — the route uses the
  // same injected clock for the tool-ticket check and the refresh skew window.
  const toolTicket = (workspaceId: WorkspaceId): string =>
    signConnectTicket(workspaceId, TOOL_TICKET_PROVIDER, CONNECT_SECRET, {
      now: () => NOW,
    });

  /** Drive `handleConnectRequest("tool-headers", …)` for the linear provider. */
  async function callToolHeaders(opts: {
    stored: string;
    refreshFetch: typeof fetch;
    now: number;
    upsertInstall: ConnectDeps["upsertInstall"];
    skewMs?: number;
  }) {
    const registry = createConnectorRegistry();
    registry.register(
      createLinearConnector({
        refresh: {
          ...CLIENT,
          fetch: opts.refreshFetch,
          ...(opts.skewMs !== undefined ? { skewMs: opts.skewMs } : {}),
        },
      }),
    );
    const installs = createInMemoryInstallsLookup([installWith(opts.stored)]);
    const deps: ConnectDeps = {
      secret: CONNECT_SECRET,
      registry,
      installs,
      upsertInstall: opts.upsertInstall,
      deleteInstall: async () => false,
      mountInstall: async () => undefined,
      unmountInstall: async () => false,
      now: () => opts.now,
    };
    const body = JSON.stringify({ ticket: toolTicket(WS_A) });
    return handleConnectRequest("tool-headers", body, deps, "linear");
  }

  it("HAPPY PATH: refreshes, writes the re-sealed bundle back (plaintext, NO chatToken key), serves the FRESH Bearer", async () => {
    const captured: ConnectorInstall[] = [];
    const reply = await callToolHeaders({
      stored: bundle({ expires_at: NOW }),
      refreshFetch: rotatingLinearTokenStub({}),
      now: NOW,
      upsertInstall: async (install) => {
        captured.push(install);
      },
    });

    expect(reply?.status).toBe(200);
    // The Bearer is the FRESH access token, not the stored one.
    expect(reply?.body).toEqual({ Authorization: "Bearer at_1" });

    // Blind LWW write-back: ONE upsert, PLAINTEXT bundle in, same workspace, and NO
    // `chatToken` key (D91 — absent means PRESERVE, keeping chat_token_ref NULL).
    expect(captured).toHaveLength(1);
    const written = captured[0] as ConnectorInstall;
    expect(written.provider).toBe("linear");
    expect(written.installKey).toBe(ORG_A);
    expect(written.workspaceId).toBe(WS_A);
    expect("chatToken" in written).toBe(false);
    const writtenBundle = JSON.parse(
      written.credentialRef as string,
    ) as LinearCredentialBundle;
    expect(writtenBundle.access_token).toBe("at_1");
    expect(writtenBundle.refresh_token).toBe("rt_1");
    expect(writtenBundle.expires_at).toBe(NOW + 86399 * 1000);
  });

  it("SERVE-STALE-LOUD: a refresh failure serves the STORED token, does NOT write back, and logs loudly (D90)", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const captured: ConnectorInstall[] = [];
    const reply = await callToolHeaders({
      stored: bundle({ access_token: "at_stored", expires_at: NOW }),
      refreshFetch: rotatingLinearTokenStub({
        fail: () => new Response("boom", { status: 500 }),
      }),
      now: NOW,
      upsertInstall: async (install) => {
        captured.push(install);
      },
    });

    expect(reply?.status).toBe(200);
    // The STORED token is served — a failed refresh never hard-fails the connect.
    expect(reply?.body).toEqual({ Authorization: "Bearer at_stored" });
    // Nothing was written back.
    expect(captured).toHaveLength(0);
    // LOUD: the failure was logged.
    expect(errorSpy).toHaveBeenCalled();
    errorSpy.mockRestore();
  });

  it("NO REFRESH when the bundle is fresh — the STORED Bearer is served, no write-back", async () => {
    const captured: ConnectorInstall[] = [];
    const reply = await callToolHeaders({
      stored: bundle({
        access_token: "at_fresh",
        expires_at: NOW + 10 * 3_600_000,
      }),
      refreshFetch: rotatingLinearTokenStub({}),
      now: NOW,
      upsertInstall: async (install) => {
        captured.push(install);
      },
    });
    expect(reply?.body).toEqual({ Authorization: "Bearer at_fresh" });
    expect(captured).toHaveLength(0);
  });

  it("MALFORMED bundle is served BYTE-FOR-BYTE and never throws (D89 read-path)", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const captured: ConnectorInstall[] = [];
    const malformed = '{ "access_token": '; // starts with { but does not parse
    const reply = await callToolHeaders({
      stored: malformed,
      refreshFetch: rotatingLinearTokenStub({}),
      now: NOW,
      upsertInstall: async (install) => {
        captured.push(install);
      },
    });
    expect(reply?.status).toBe(200);
    expect(reply?.body).toEqual({ Authorization: `Bearer ${malformed}` });
    // No refresh attempted (parse → null) and nothing written.
    expect(captured).toHaveLength(0);
    errorSpy.mockRestore();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });
});
