/**
 * THE LINEAR OAUTH INSTALL FLOW + THE TOOL SEAM, END TO END (charter D77–D82).
 *
 * Linear is the SECOND tool connector, and it is OAuth-only — so this file proves
 * the OUTBOUND (tool) OAuth callback the way `oauth/slack-oauth.ts` proves the
 * inbound one, MINUS the two things a tool install does not have (a pending-connect
 * row and a mount), and then proves the ALREADY-MERGED generic tool seam
 * (tool-descriptors / tool-headers) serves a Linear install with ZERO Linear-
 * specific code.
 *
 * Four layers, ascending in what they touch:
 *   1. helpers — buildLinearInstallUrl / exchangeLinearCode / fetchLinearOrganization,
 *      injected `fetch`, no DB.
 *   2. handleLinearOAuthCallback — the callback battery, injected `fetch`, REAL
 *      Postgres (forged/wrong-provider/denied/bad-code refusals write nothing; the
 *      code is never spent before the ticket verifies; the D64 incumbent 409; ONE
 *      upsert with chat_token NULL; a urlKey rename does not move the key).
 *   3. the FIFTH webhook-server route class — GET {prefix}/oauth/linear/callback
 *      dispatches to the callback, 404s when unconfigured or on a non-GET.
 *   4. the tool seam through the REAL startBridge — a connected workspace lists
 *      linear's http descriptor + headersHelper, tool-headers returns the flat
 *      Bearer, an unconnected workspace sees nothing, cross-tenant is the opaque 404.
 *
 * NO NETWORK anywhere: `fetch` is injected into every Linear call. The live Linear
 * call is the human gate `connectors-linear-live-oauth-gate`, never fabricated.
 */
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import pg from "pg";

import type { BridgeConfig } from "../src/config.js";
import {
  signConnectTicket,
  TOOL_TICKET_PROVIDER,
  verifyConnectTicket,
  verifyToolTicket,
} from "../src/connect/ticket.js";
import {
  createConnectorRegistry,
  type ConnectorRegistry,
} from "../src/connector/registry.js";
import type {
  ConnectorInstall,
  InstallsLookup,
  WorkspaceId,
} from "../src/connector/types.js";
import { createGithubConnector } from "../src/connectors/github.js";
import {
  createLinearConnector,
  LINEAR_PROVIDER,
} from "../src/connectors/linear.js";
import { createCredentialCipher } from "../src/crypto/credential-cipher.js";
import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import { createWebhookMountIndex } from "../src/http/mounts.js";
import { startWebhookServer } from "../src/http/webhook-server.js";
import {
  buildLinearInstallUrl,
  exchangeLinearCode,
  fetchLinearOrganization,
  handleLinearOAuthCallback,
  type LinearOAuthCallbackDeps,
} from "../src/oauth/linear-oauth.js";
import { startBridge, type Bridge } from "../src/index.js";
import { createInstallsLookup, upsertInstall } from "../src/tenant/installs.js";

const CREDENTIAL_KEY = Buffer.alloc(32, 7).toString("base64");
const cipher = createCredentialCipher({ key: CREDENTIAL_KEY });

const CONNECT_SECRET = "connect-secret-for-the-linear-oauth-test";
const WS_A = "aaaaaaaa-1111-4111-8111-111111111111";
const WS_B = "bbbbbbbb-2222-4222-8222-222222222222";

/** The org id the fake Linear blesses — the immutable install key (D79). */
const ORG_A = "12345678-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const ORG_URLKEY = "acme";
/** The OAuth access token the fake Linear returns for a good code. */
const ACCESS_TOKEN = "lin_oauth_access_token_A";
/** The rotating refresh token the fake Linear returns (D90 bundle). */
const REFRESH_TOKEN = "lin_oauth_refresh_token_A";
/** The lifetime the fake Linear reports — ~24h, so expires_at = now + this*1000. */
const EXPIRES_IN = 86399;

/** Parse the bundle a callback sealed into `credential_ref` (D90). */
function parseBundle(credentialRef: string | null | undefined): {
  access_token?: string;
  refresh_token?: string;
  expires_at?: number;
} {
  return JSON.parse(credentialRef as string) as {
    access_token?: string;
    refresh_token?: string;
    expires_at?: number;
  };
}

const jsonResp = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

/**
 * A fake Linear. It answers the TOKEN endpoint (`/oauth/token`) and the GRAPHQL
 * endpoint (`/graphql`) — the two DIFFERENT hosts the callback hits (D78) — and
 * records every URL it was called with, so a test can prove the ORDER (the code is
 * never spent before the ticket verifies).
 */
function linearFetch(cfg: {
  token?: () => Response;
  org?: () => Response;
  calls?: string[];
}): typeof fetch {
  return (async (input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    const url = typeof input === "string" ? input : String(input);
    cfg.calls?.push(url);
    if (url.includes("/oauth/token")) {
      // Prove client_secret is in the BODY, never the URL.
      const body = String(init?.body ?? "");
      if (!body.includes("grant_type=authorization_code")) {
        return jsonResp({ error: "missing grant_type" }, 400);
      }
      return (
        cfg.token ??
        (() =>
          jsonResp({
            access_token: ACCESS_TOKEN,
            token_type: "Bearer",
            expires_in: EXPIRES_IN,
            refresh_token: REFRESH_TOKEN,
            scope: "read",
          }))
      )();
    }
    if (url.includes("/graphql")) {
      return (
        cfg.org ??
        (() =>
          jsonResp({ data: { organization: { id: ORG_A, urlKey: ORG_URLKEY } } }))
      )();
    }
    return jsonResp({ error: `unexpected url ${url}` }, 500);
  }) as unknown as typeof fetch;
}

// ── LAYER 1: the helpers, no DB ──────────────────────────────────────────────

describe("Linear OAuth helpers — injected fetch, no DB (D78/D79/D81)", () => {
  it("buildLinearInstallUrl authorizes on linear.app with response_type=code, scope=read, and a signed state", () => {
    const raw = buildLinearInstallUrl({
      clientId: "lin_client",
      redirectUri: "https://example.test/connectors/oauth/linear/callback",
      workspaceId: WS_A,
      stateSecret: CONNECT_SECRET,
    });
    const url = new URL(raw);
    // authorize is on linear.app — a DIFFERENT host from the token exchange (D78).
    expect(url.origin).toBe("https://linear.app");
    expect(url.pathname).toBe("/oauth/authorize");
    expect(url.searchParams.get("client_id")).toBe("lin_client");
    expect(url.searchParams.get("response_type")).toBe("code");
    // scope=read ONLY (D81) — no broad write.
    expect(url.searchParams.get("scope")).toBe("read");

    // The state is a REAL connect ticket bound to provider "linear" + WS_A.
    const state = url.searchParams.get("state");
    const ticket = verifyConnectTicket(state, CONNECT_SECRET, {
      provider: LINEAR_PROVIDER,
    });
    expect(ticket.workspaceId).toBe(WS_A);
    expect(ticket.provider).toBe(LINEAR_PROVIDER);
  });

  it("exchangeLinearCode POSTs to api.linear.app/oauth/token with client_secret in the BODY", async () => {
    const calls: string[] = [];
    let capturedBody = "";
    const doFetch = (async (
      input: Parameters<typeof fetch>[0],
      init?: RequestInit,
    ) => {
      calls.push(typeof input === "string" ? input : String(input));
      capturedBody = String(init?.body ?? "");
      return jsonResp({ access_token: ACCESS_TOKEN, expires_in: 86399 });
    }) as unknown as typeof fetch;

    const res = await exchangeLinearCode("the-code", {
      clientId: "cid",
      clientSecret: "the-secret",
      redirectUri: "https://example.test/cb",
      fetch: doFetch,
    });
    expect(res.access_token).toBe(ACCESS_TOKEN);
    // token exchange host is api.linear.app (NOT linear.app) — D78.
    expect(calls[0]).toBe("https://api.linear.app/oauth/token");
    expect(capturedBody).toContain("client_secret=the-secret");
    expect(capturedBody).toContain("grant_type=authorization_code");
    // The secret is NOT in the URL.
    expect(calls[0]).not.toContain("the-secret");
  });

  it("exchangeLinearCode surfaces a non-2xx as a refusal, not a throw", async () => {
    const doFetch = (async () =>
      jsonResp({ error: "invalid_grant" }, 400)) as unknown as typeof fetch;
    const res = await exchangeLinearCode("bad", {
      clientId: "cid",
      clientSecret: "sec",
      redirectUri: "cb",
      fetch: doFetch,
    });
    expect(res.access_token).toBeUndefined();
    expect(res.error).toContain("HTTP 400");
  });

  it("fetchLinearOrganization returns id (the key) + urlKey (display), and null on GraphQL errors", async () => {
    const ok = (async () =>
      jsonResp({
        data: { organization: { id: ORG_A, urlKey: "acme" } },
      })) as unknown as typeof fetch;
    expect(await fetchLinearOrganization(ACCESS_TOKEN, { fetch: ok })).toEqual({
      id: ORG_A,
      urlKey: "acme",
    });

    // A GraphQL 200 that carries `errors` (e.g. an expired token) is a null — the
    // callback must not install an org it could not identify.
    const errs = (async () =>
      jsonResp({
        errors: [{ message: "authentication failed" }],
      })) as unknown as typeof fetch;
    expect(await fetchLinearOrganization(ACCESS_TOKEN, { fetch: errs })).toBeNull();

    // A missing id is a null too.
    const noId = (async () =>
      jsonResp({
        data: { organization: { urlKey: "x" } },
      })) as unknown as typeof fetch;
    expect(await fetchLinearOrganization(ACCESS_TOKEN, { fetch: noId })).toBeNull();
  });
});

// ── LAYER 3: the fifth webhook-server route class (no DB) ─────────────────────

describe("the FIFTH webhook-server route class — GET {prefix}/oauth/linear/callback (D77/D78)", () => {
  function linearRegistry(): ConnectorRegistry {
    const registry = createConnectorRegistry();
    registry.register(createLinearConnector());
    return registry;
  }
  // The route uses only the linearOAuth deps; the installs lookup is irrelevant to
  // it, so a stub that answers nothing is fine.
  const stubInstalls: InstallsLookup = {
    lookupInstall: async () => null,
    resolveWorkspace: async () => null,
    listInstalls: async () => [],
    lookupByWorkspace: async () => null,
  };

  it("dispatches a good GET to the callback: 200, an HTML 'Connected to Linear' page, and the install is written", async () => {
    let written: ConnectorInstall | undefined;
    const linearOAuth: LinearOAuthCallbackDeps = {
      clientId: "cid",
      clientSecret: "sec",
      redirectUri: "https://example.test/connectors/oauth/linear/callback",
      stateSecret: CONNECT_SECRET,
      resolveWorkspace: async () => null,
      upsertInstall: async (install) => {
        written = install;
      },
      fetch: linearFetch({}),
    };
    const server = await startWebhookServer({
      registry: linearRegistry(),
      installs: stubInstalls,
      mounts: createWebhookMountIndex(),
      linearOAuth,
      host: "127.0.0.1",
      port: 0,
      pathPrefix: "/connectors",
    });
    try {
      const state = signConnectTicket(WS_A, LINEAR_PROVIDER, CONNECT_SECRET);
      const res = await fetch(
        `http://127.0.0.1:${server.port}/connectors/oauth/linear/callback?code=CODE&state=${encodeURIComponent(state)}`,
      );
      expect(res.status).toBe(200);
      expect(res.headers.get("content-type")).toContain("text/html");
      const html = await res.text();
      expect(html).toContain("Connected to Linear");
      // The install the route wrote is a TOOL install: a credential BUNDLE (D90),
      // NO chat token. The bundle carries the rotating refresh token so tool-headers
      // can re-token before expiry; the generic read-path extracts .access_token.
      expect(written?.provider).toBe(LINEAR_PROVIDER);
      expect(written?.installKey).toBe(ORG_A);
      expect(written?.workspaceId).toBe(WS_A);
      const writtenBundle = parseBundle(written?.credentialRef);
      expect(writtenBundle.access_token).toBe(ACCESS_TOKEN);
      expect(writtenBundle.refresh_token).toBe(REFRESH_TOKEN);
      expect(typeof writtenBundle.expires_at).toBe("number");
      expect(written?.chatToken).toBeUndefined();
    } finally {
      await server.close();
    }
  });

  it("is the opaque 404 when linearOAuth is NOT configured", async () => {
    const server = await startWebhookServer({
      registry: linearRegistry(),
      installs: stubInstalls,
      mounts: createWebhookMountIndex(),
      host: "127.0.0.1",
      port: 0,
      pathPrefix: "/connectors",
    });
    try {
      const res = await fetch(
        `http://127.0.0.1:${server.port}/connectors/oauth/linear/callback?code=X&state=Y`,
      );
      expect(res.status).toBe(404);
      expect(await res.text()).toBe('{"error":"not_found"}');
    } finally {
      await server.close();
    }
  });

  it("a POST to the callback is the opaque 404 — a browser redirect is a GET", async () => {
    const linearOAuth: LinearOAuthCallbackDeps = {
      clientId: "cid",
      clientSecret: "sec",
      redirectUri: "https://example.test/cb",
      stateSecret: CONNECT_SECRET,
      resolveWorkspace: async () => null,
      upsertInstall: async () => undefined,
      fetch: linearFetch({}),
    };
    const server = await startWebhookServer({
      registry: linearRegistry(),
      installs: stubInstalls,
      mounts: createWebhookMountIndex(),
      linearOAuth,
      host: "127.0.0.1",
      port: 0,
      pathPrefix: "/connectors",
    });
    try {
      const res = await fetch(
        `http://127.0.0.1:${server.port}/connectors/oauth/linear/callback?code=X&state=Y`,
        { method: "POST" },
      );
      expect(res.status).toBe(404);
    } finally {
      await server.close();
    }
  });
});

// ── LAYERS 2 & 4: real Postgres ──────────────────────────────────────────────

const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";
const TEST_DB = `connectors_linear_oauth_test_${process.pid}_${Date.now()}`;

function urlForDatabase(base: string, database: string): string {
  const url = new URL(base);
  url.pathname = `/${database}`;
  return url.toString();
}

async function postgresReachable(): Promise<boolean> {
  const client = new pg.Client({ connectionString: ADMIN_URL });
  try {
    await client.connect();
    await client.end();
    return true;
  } catch {
    return false;
  }
}

const reachable = await postgresReachable();

describe.skipIf(!reachable && !REQUIRE_DB)(
  "handleLinearOAuthCallback — the tool OAuth callback, real Postgres, injected fetch (D78/D79/D80)",
  () => {
    let admin: pg.Client;
    let pool: pg.Pool;

    beforeAll(async () => {
      if (!reachable && REQUIRE_DB) {
        throw new Error(
          `CONNECTORS_REQUIRE_DB=1 but no Postgres is reachable at ${ADMIN_URL}`,
        );
      }
      admin = new pg.Client({ connectionString: ADMIN_URL });
      await admin.connect();
      await admin.query(`CREATE DATABASE ${TEST_DB}`);
      pool = createBridgePool({
        connectionString: urlForDatabase(ADMIN_URL, TEST_DB),
      });
      await ensureBridgeSchema(pool);
    }, 30_000);

    afterAll(async () => {
      await pool?.end();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)`);
        await admin.end();
      }
    }, 30_000);

    afterEach(async () => {
      await pool.query("DELETE FROM chat_bridge.connector_installs");
    });

    const lookup = () => createInstallsLookup(pool, cipher);

    const rawRow = async (installKey: string) => {
      const { rows } = await pool.query<{
        workspace_id: string | null;
        credential_ref: string | null;
        chat_token_ref: string | null;
      }>(
        `SELECT workspace_id, credential_ref, chat_token_ref
           FROM chat_bridge.connector_installs
          WHERE provider = 'linear' AND install_key = $1`,
        [installKey],
      );
      return rows[0] ?? null;
    };

    const countLinear = async (): Promise<number> => {
      const { rows } = await pool.query<{ n: string }>(
        "SELECT count(*)::text AS n FROM chat_bridge.connector_installs WHERE provider = 'linear'",
      );
      return Number(rows[0]?.n ?? "0");
    };

    /** The production deps, with an injected fetch — real seal, real Postgres. */
    function depsWith(
      overrides: Partial<LinearOAuthCallbackDeps> = {},
    ): LinearOAuthCallbackDeps {
      return {
        clientId: "cid",
        clientSecret: "csec",
        redirectUri: "https://example.test/connectors/oauth/linear/callback",
        stateSecret: CONNECT_SECRET,
        resolveWorkspace: (provider, installKey) =>
          lookup().resolveWorkspace(provider, installKey),
        upsertInstall: (install) => upsertInstall(pool, cipher, install),
        fetch: linearFetch({}),
        ...overrides,
      };
    }

    const callbackReq = (state: string, code = "CODE", extra = ""): Request =>
      new Request(
        `https://example.test/connectors/oauth/linear/callback?code=${code}&state=${encodeURIComponent(state)}${extra}`,
      );

    it("writes ONE tool install: credential_ref sealed to a JSON BUNDLE, chat_token_ref NULL, and it OPENS", async () => {
      const now = 1_700_000_000_000;
      // Sign the state AT `now` so it verifies under the callback's injected clock —
      // the same `now` that stamps the bundle's expires_at.
      const state = signConnectTicket(WS_A, LINEAR_PROVIDER, CONNECT_SECRET, {
        now: () => now,
      });
      const result = await handleLinearOAuthCallback(
        callbackReq(state),
        depsWith({ now: () => now }),
      );

      expect(result.installed).toBe(true);
      expect(result.status).toBe(200);
      expect(result.installKey).toBe(ORG_A);
      expect(result.workspaceId).toBe(WS_A);
      // urlKey feeds displayName ONLY.
      expect(result.displayName).toBe(ORG_URLKEY);

      const raw = await rawRow(ORG_A);
      expect(raw?.workspace_id).toBe(WS_A);
      expect(raw?.credential_ref).not.toBeNull();
      // SEALED — the same cipher every channel uses; no plaintext token is stored.
      expect(raw?.credential_ref).not.toContain(ACCESS_TOKEN);
      // A TOOL install has NO chat token (D78).
      expect(raw?.chat_token_ref).toBeNull();

      // …and it opens, against this row's identity, to the JSON BUNDLE (D90) —
      // {access_token, refresh_token, expires_at}. The generic tool-headers read-path
      // extracts .access_token for a working `Bearer`, and the refresh_token is what
      // lets it re-token before expiry (D89/D92).
      const install = await lookup().lookupByWorkspace("linear", WS_A);
      const bundle = parseBundle(install?.credentialRef);
      expect(bundle.access_token).toBe(ACCESS_TOKEN);
      expect(bundle.refresh_token).toBe(REFRESH_TOKEN);
      // expires_at = now + expires_in*1000 (epoch-ms).
      expect(bundle.expires_at).toBe(now + EXPIRES_IN * 1000);
      expect(install?.chatToken).toBeNull();

      expect(await countLinear()).toBe(1);
    });

    it("VERIFIES THE TICKET BEFORE SPENDING THE CODE — a forged state never reaches Linear", async () => {
      const calls: string[] = [];
      // A state signed under the WRONG secret: the signature check fails.
      const forged = signConnectTicket(WS_A, LINEAR_PROVIDER, "not-the-secret");
      const result = await handleLinearOAuthCallback(
        callbackReq(forged),
        depsWith({ fetch: linearFetch({ calls }) }),
      );
      expect(result.status).toBe(400);
      expect(result.installed).toBe(false);
      // The code was NEVER spent: the fake Linear saw zero calls.
      expect(calls).toEqual([]);
      expect(await countLinear()).toBe(0);
    });

    it("refuses a WRONG-PROVIDER ticket (bound to slack) — 400, nothing written, no code spent", async () => {
      const calls: string[] = [];
      const slackTicket = signConnectTicket(WS_A, "slack", CONNECT_SECRET);
      const result = await handleLinearOAuthCallback(
        callbackReq(slackTicket),
        depsWith({ fetch: linearFetch({ calls }) }),
      );
      expect(result.status).toBe(400);
      expect(result.installed).toBe(false);
      expect(calls).toEqual([]);
      expect(await countLinear()).toBe(0);
    });

    it("refuses error=access_denied BEFORE any exchange — 400, nothing written", async () => {
      const calls: string[] = [];
      const state = signConnectTicket(WS_A, LINEAR_PROVIDER, CONNECT_SECRET);
      const result = await handleLinearOAuthCallback(
        new Request(
          `https://example.test/connectors/oauth/linear/callback?error=access_denied&state=${encodeURIComponent(state)}`,
        ),
        depsWith({ fetch: linearFetch({ calls }) }),
      );
      expect(result.status).toBe(400);
      expect(result.installed).toBe(false);
      expect(result.error).toContain("access_denied");
      expect(calls).toEqual([]);
      expect(await countLinear()).toBe(0);
    });

    it("refuses an invalid code (exchange fails) — 400, GraphQL never called, nothing written", async () => {
      const calls: string[] = [];
      const state = signConnectTicket(WS_A, LINEAR_PROVIDER, CONNECT_SECRET);
      const result = await handleLinearOAuthCallback(
        callbackReq(state),
        depsWith({
          fetch: linearFetch({
            calls,
            token: () => jsonResp({ error: "invalid_grant" }, 400),
          }),
        }),
      );
      expect(result.status).toBe(400);
      expect(result.installed).toBe(false);
      // Only the token endpoint was tried; GraphQL was never reached.
      expect(calls).toEqual(["https://api.linear.app/oauth/token"]);
      expect(await countLinear()).toBe(0);
    });

    it("refuses a token whose org cannot be identified (GraphQL errors) — 400, nothing written", async () => {
      const state = signConnectTicket(WS_A, LINEAR_PROVIDER, CONNECT_SECRET);
      const result = await handleLinearOAuthCallback(
        callbackReq(state),
        depsWith({
          fetch: linearFetch({
            org: () => jsonResp({ errors: [{ message: "auth failed" }] }),
          }),
        }),
      );
      expect(result.status).toBe(400);
      expect(result.installed).toBe(false);
      expect(await countLinear()).toBe(0);
    });

    it("refuses a Linear org another workspace already owns — 409 BEFORE any write, incumbent untouched (D64)", async () => {
      // WS_A already owns ORG_A.
      await upsertInstall(pool, cipher, {
        provider: LINEAR_PROVIDER,
        installKey: ORG_A,
        workspaceId: WS_A,
        credentialRef: "lin_incumbent_token",
      });

      // WS_B re-auths the SAME org with a legit ticket for its OWN workspace.
      const state = signConnectTicket(WS_B, LINEAR_PROVIDER, CONNECT_SECRET);
      const result = await handleLinearOAuthCallback(
        callbackReq(state),
        depsWith(),
      );

      expect(result.status).toBe(409);
      expect(result.installed).toBe(false);
      expect(result.error).toContain("install_owned_elsewhere");

      // The incumbent's row is untouched: still WS_A, still WS_A's token.
      const raw = await rawRow(ORG_A);
      expect(raw?.workspace_id).toBe(WS_A);
      const install = await lookup().lookupByWorkspace("linear", WS_A);
      expect(install?.credentialRef).toBe("lin_incumbent_token");
      expect(await countLinear()).toBe(1);
    });

    it("a urlKey RENAME does NOT change the install key — the key is the immutable org id (D79)", async () => {
      // First connect: urlKey "acme" → install key = ORG_A.
      const state1 = signConnectTicket(WS_A, LINEAR_PROVIDER, CONNECT_SECRET);
      const first = await handleLinearOAuthCallback(
        callbackReq(state1),
        depsWith(),
      );
      expect(first.installKey).toBe(ORG_A);
      expect(first.displayName).toBe("acme");

      // The org is renamed in Linear (urlKey → "acme-renamed"), same immutable id.
      const state2 = signConnectTicket(WS_A, LINEAR_PROVIDER, CONNECT_SECRET);
      const second = await handleLinearOAuthCallback(
        callbackReq(state2),
        depsWith({
          fetch: linearFetch({
            org: () =>
              jsonResp({
                data: { organization: { id: ORG_A, urlKey: "acme-renamed" } },
              }),
          }),
        }),
      );
      // The KEY did not move — it is still the org id, not the renamed urlKey.
      expect(second.installKey).toBe(ORG_A);
      // The display name DID update (urlKey is display-only).
      expect(second.displayName).toBe("acme-renamed");

      // Exactly ONE row, keyed on the immutable id — the rename did not fork it.
      expect(await countLinear()).toBe(1);
      expect(await rawRow(ORG_A)).not.toBeNull();
    });
  },
);

describe.skipIf(!reachable && !REQUIRE_DB)(
  "the tool seam serves a Linear install — through startBridge, real Postgres (D77/D88)",
  () => {
    let admin: pg.Client;
    let pool: pg.Pool;
    let bridge: Bridge | undefined;

    beforeAll(async () => {
      if (!reachable && REQUIRE_DB) {
        throw new Error(
          `CONNECTORS_REQUIRE_DB=1 but no Postgres is reachable at ${ADMIN_URL}`,
        );
      }
      admin = new pg.Client({ connectionString: ADMIN_URL });
      await admin.connect();
      await admin.query(`CREATE DATABASE ${TEST_DB}_seam`);
      pool = createBridgePool({
        connectionString: urlForDatabase(ADMIN_URL, `${TEST_DB}_seam`),
      });
      await ensureBridgeSchema(pool);
    }, 30_000);

    afterAll(async () => {
      await pool?.end();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${TEST_DB}_seam WITH (FORCE)`);
        await admin.end();
      }
    }, 30_000);

    afterEach(async () => {
      await bridge?.shutdown();
      bridge = undefined;
      await pool.query("DELETE FROM chat_bridge.connector_installs");
    });

    function configFor(): BridgeConfig {
      return {
        databaseUrl: urlForDatabase(ADMIN_URL, `${TEST_DB}_seam`),
        apiUrl: "http://127.0.0.1:1",
        credentialKey: CREDENTIAL_KEY,
        previousCredentialKeys: [],
        connectSecret: CONNECT_SECRET,
        userName: "barkpark",
        webhook: {
          enabled: true,
          host: "127.0.0.1",
          port: 0,
          pathPrefix: "/connectors",
          maxBodyBytes: 65_536,
        },
      };
    }

    function linearRegistry(): ConnectorRegistry {
      const registry = createConnectorRegistry();
      registry.register(createLinearConnector());
      return registry;
    }

    async function boot(): Promise<string> {
      bridge = await startBridge(configFor(), { registry: linearRegistry() });
      return `http://127.0.0.1:${bridge.webhookServer?.port}`;
    }

    const post = (base: string, path: string, body: unknown) =>
      fetch(`${base}${path}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });

    const toolTicket = (workspaceId: WorkspaceId) =>
      signConnectTicket(workspaceId, TOOL_TICKET_PROVIDER, CONNECT_SECRET);

    /**
     * A BARE-STRING install exactly as a PRE-W9 callback (or a paste connector)
     * wrote it — proves the dual-shape read-path serves a legacy row byte-for-byte
     * (D89 backward-compat).
     */
    async function seedLinearInstall(workspaceId: WorkspaceId): Promise<void> {
      await upsertInstall(pool, cipher, {
        provider: LINEAR_PROVIDER,
        installKey: ORG_A,
        workspaceId,
        credentialRef: ACCESS_TOKEN,
      });
    }

    /**
     * A BUNDLE install exactly as the W9 callback writes it (D90) — the SECOND seed
     * shape. tool-headers must extract `.access_token` from the sealed bundle and
     * emit the same flat Bearer as the bare-string row does.
     */
    async function seedLinearBundleInstall(
      workspaceId: WorkspaceId,
    ): Promise<void> {
      await upsertInstall(pool, cipher, {
        provider: LINEAR_PROVIDER,
        installKey: ORG_A,
        workspaceId,
        credentialRef: JSON.stringify({
          access_token: ACCESS_TOKEN,
          refresh_token: REFRESH_TOKEN,
          // Far future: no refresh fires, so the seam serves the stored token.
          expires_at: Date.now() + 30 * 24 * 3_600_000,
        }),
      });
    }

    it("TOOL-DESCRIPTORS lists linear's http descriptor + a headersHelper for a connected workspace", async () => {
      const base = await boot();
      await seedLinearInstall(WS_A);

      const response = await post(base, "/connectors/connect/tool-descriptors", {
        ticket: toolTicket(WS_A),
      });
      expect(response.status).toBe(200);
      const body = (await response.json()) as {
        descriptors: Array<{
          provider: string;
          type: string;
          url: string;
          headersHelper: string;
        }>;
      };
      expect(body.descriptors).toHaveLength(1);
      const [d] = body.descriptors;
      expect(d?.provider).toBe("linear");
      expect(d?.type).toBe("http");
      expect(d?.url).toBe("https://mcp.linear.app/mcp");
      expect(d?.headersHelper).toContain("/connect/tool-headers/linear");
      expect(d?.headersHelper).toContain("http://127.0.0.1:");
      const embedded = d?.headersHelper.match(/"ticket":"([^"]+)"/)?.[1];
      expect(
        verifyToolTicket(embedded as string, CONNECT_SECRET)?.workspaceId,
      ).toBe(WS_A);
    });

    it("TOOL-HEADERS opens linear's sealed BARE-string token and returns the flat Bearer (D80/D89 legacy)", async () => {
      const base = await boot();
      await seedLinearInstall(WS_A);

      const response = await post(base, "/connectors/connect/tool-headers/linear", {
        ticket: toolTicket(WS_A),
      });
      expect(response.status).toBe(200);
      // EXACTLY the shape claude's headersHelper prints — the BARE token as Bearer.
      expect(await response.json()).toEqual({
        Authorization: `Bearer ${ACCESS_TOKEN}`,
      });
    });

    it("TOOL-HEADERS opens linear's sealed BUNDLE and returns the SAME flat Bearer (D89/D90 dual-shape)", async () => {
      const base = await boot();
      await seedLinearBundleInstall(WS_A);

      const response = await post(base, "/connectors/connect/tool-headers/linear", {
        ticket: toolTicket(WS_A),
      });
      expect(response.status).toBe(200);
      // The read-path extracted .access_token from the bundle — byte-identical to
      // what the bare-string row above emits. The bridge here has NO Linear OAuth
      // creds (startBridge reads none in this test), so no refresh fires and the
      // stored token is served: the bundle is served exactly like the legacy row.
      expect(await response.json()).toEqual({
        Authorization: `Bearer ${ACCESS_TOKEN}`,
      });
    });

    it("an UNCONNECTED workspace sees no linear descriptor, and cannot open the PAT — the opaque 404", async () => {
      const base = await boot();
      await seedLinearInstall(WS_A);

      // WS_B connected nothing: empty descriptors (and it never learns WS_A did).
      const desc = await post(base, "/connectors/connect/tool-descriptors", {
        ticket: toolTicket(WS_B),
      });
      expect(await desc.json()).toEqual({ descriptors: [] });

      // A valid tool ticket for WS_B cannot open WS_A's linear token: opaque 404.
      const headers = await post(base, "/connectors/connect/tool-headers/linear", {
        ticket: toolTicket(WS_B),
      });
      expect(headers.status).toBe(404);
      expect(await headers.text()).toBe('{"error":"not_found"}');
    });

    it("GitHub AND Linear both list for a workspace connected to both — two tool servers, ONE unchanged seam (D88 bridge half)", async () => {
      // The end state D88 proves the runner accepts: barkpark + github + linear.
      // Here we prove the BRIDGE emits both http descriptors from ONE unchanged
      // seam — the whole claim that a second tool connector is a second registry
      // entry with ZERO core-loop change.
      const registry = createConnectorRegistry();
      registry.register(createGithubConnector());
      registry.register(createLinearConnector());
      bridge = await startBridge(configFor(), { registry });
      const base = `http://127.0.0.1:${bridge.webhookServer?.port}`;

      // Both tools connected for WS_A — seed each row exactly as its connect writes.
      await seedLinearInstall(WS_A);
      await upsertInstall(pool, cipher, {
        provider: "github",
        installKey: "octocat",
        workspaceId: WS_A,
        credentialRef: "ghp_a-good-token",
      });

      const desc = await post(base, "/connectors/connect/tool-descriptors", {
        ticket: toolTicket(WS_A),
      });
      const body = (await desc.json()) as {
        descriptors: Array<{ provider: string; url: string }>;
      };
      const byProvider = new Map(body.descriptors.map((d) => [d.provider, d.url]));
      expect(byProvider.get("linear")).toBe("https://mcp.linear.app/mcp");
      expect(byProvider.get("github")).toBe("https://api.githubcopilot.com/mcp/");
      expect(body.descriptors).toHaveLength(2);
    });
  },
);
