/**
 * THE TOOL-CONNECTOR SEAM, END TO END (charter D69/D71) — the epic's OTHER
 * direction, through the REAL `startBridge` against a REAL Postgres.
 *
 * A channel connector routes an inbound event; a tool connector lets the agent
 * ACT on a service. This file proves the four properties that make GitHub a real
 * tool connector rather than an asserted one:
 *
 *   1. `/connect` for a TOOL seals ONLY the PAT (chat_token_ref stays NULL) and
 *      does NOT mount a Chat — the write IS the connect (branch on DIRECTION, never
 *      on the provider id).
 *   2. `tool-descriptors` lists a workspace's tool connectors as MCP descriptors,
 *      each with a `headersHelper` command that fetches the PAT at MCP-connect —
 *      and it is EMPTY for a workspace that has connected nothing.
 *   3. `tool-headers/:provider` opens exactly THAT workspace's sealed PAT and
 *      returns the flat `{"Authorization":"Bearer <pat>"}` claude's headersHelper
 *      prints — and the whole helper→route→PAT chain runs for real (curl).
 *   4. Cross-tenant is UNREPRESENTABLE (a workspace's tool ticket cannot open
 *      another's PAT) and the routes are LOOPBACK-ONLY (x-forwarded-* → opaque 404).
 *
 * NO NETWORK for validation: `fetch` is injected into the GitHub connector, so the
 * paste-mode PAT check runs without GitHub on the other end. The loopback curl in
 * property 3 DOES hit the bridge's own socket — that is the point.
 */
import { exec } from "node:child_process";
import { promisify } from "node:util";

import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import pg from "pg";

import type { BridgeConfig } from "../src/config.js";
import {
  signConnectTicket,
  TOOL_TICKET_PROVIDER,
  verifyToolTicket,
} from "../src/connect/ticket.js";

const execAsync = promisify(exec);
import {
  createConnectorRegistry,
  type ConnectorRegistry,
} from "../src/connector/registry.js";
import { createGithubConnector } from "../src/connectors/github.js";
import { createLinearConnector } from "../src/connectors/linear.js";
import { createCredentialCipher } from "../src/crypto/credential-cipher.js";
import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import { startBridge, type Bridge } from "../src/index.js";
import { createInstallsLookup, upsertInstall } from "../src/tenant/installs.js";

const CREDENTIAL_KEY = Buffer.alloc(32, 9).toString("base64");
const cipher = createCredentialCipher({ key: CREDENTIAL_KEY });

const CONNECT_SECRET = "connect-secret-for-the-tool-seam-test";
const WS_A = "aaaaaaaa-1111-4111-8111-111111111111";
const WS_B = "bbbbbbbb-2222-4222-8222-222222222222";

/** The PAT the fake GitHub blesses; login = the install key. */
const GOOD_PAT = "ghp_a-good-fine-grained-token";
const GOOD_LOGIN = "octocat";

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

/** A `fetch` that answers GitHub's `GET /user` for the good PAT, 401 otherwise. */
function githubFetch(): typeof fetch {
  return (async (input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    const auth = (init?.headers as Record<string, string> | undefined)?.[
      "authorization"
    ];
    if (auth === `Bearer ${GOOD_PAT}`) {
      return json({ login: GOOD_LOGIN, id: 583231 });
    }
    return json({ message: "Bad credentials" }, 401);
  }) as unknown as typeof fetch;
}

const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";
const TEST_DB = `connectors_tool_seam_test_${process.pid}_${Date.now()}`;

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
  "the tool-connector seam — through startBridge, against a real Postgres (D69/D71)",
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
      await bridge?.shutdown();
      bridge = undefined;
      await pool.query("DELETE FROM chat_bridge.connector_installs");
    });

    /** A Linear org id — the install key an OAuth connect would have written. */
    const LINEAR_ORG = "12345678-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

    function configFor(): BridgeConfig {
      return {
        databaseUrl: urlForDatabase(ADMIN_URL, TEST_DB),
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

    interface Harness {
      base: string;
      post(
        path: string,
        body: unknown,
        headers?: Record<string, string>,
      ): Promise<Response>;
      rawRow(installKey: string): Promise<{
        workspace_id: string | null;
        credential_ref: string | null;
        chat_token_ref: string | null;
      } | null>;
    }

    async function boot(registry: ConnectorRegistry): Promise<Harness> {
      bridge = await startBridge(configFor(), { registry });
      const base = `http://127.0.0.1:${bridge.webhookServer?.port}`;
      return {
        base,
        post: (path, body, headers = {}) =>
          fetch(`${base}${path}`, {
            method: "POST",
            headers: { "content-type": "application/json", ...headers },
            body: typeof body === "string" ? body : JSON.stringify(body),
          }),
        rawRow: async (installKey: string) => {
          const { rows } = await pool.query<{
            workspace_id: string | null;
            credential_ref: string | null;
            chat_token_ref: string | null;
          }>(
            `SELECT workspace_id, credential_ref, chat_token_ref
               FROM chat_bridge.connector_installs
              WHERE provider = 'github' AND install_key = $1`,
            [installKey],
          );
          return rows[0] ?? null;
        },
      };
    }

    function githubRegistry(): ConnectorRegistry {
      const registry = createConnectorRegistry();
      registry.register(createGithubConnector({ fetch: githubFetch() }));
      return registry;
    }

    const connectTicket = (workspaceId: string) =>
      signConnectTicket(workspaceId, "github", CONNECT_SECRET);
    const toolTicket = (workspaceId: string) =>
      signConnectTicket(workspaceId, TOOL_TICKET_PROVIDER, CONNECT_SECRET);

    /** Connect GitHub for a workspace and return its install key (login). */
    async function connectGithub(h: Harness, workspaceId: string): Promise<void> {
      const response = await h.post("/connectors/connect", {
        ticket: connectTicket(workspaceId),
        credential: GOOD_PAT,
      });
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({
        ok: true,
        provider: "github",
        install_key: GOOD_LOGIN,
        workspace_id: workspaceId,
        mounted: false,
      });
    }

    // ── CONNECT: the third secret kind, credential-only, no mount ─────────────

    it("CONNECT for a TOOL seals ONLY the PAT (chat_token_ref NULL) and does NOT mount", async () => {
      const h = await boot(githubRegistry());

      // A tool connect carries NO chat_token, and the flow does not demand one.
      await connectGithub(h, WS_A);

      const row = await h.rawRow(GOOD_LOGIN);
      expect(row?.workspace_id).toBe(WS_A);
      expect(row?.credential_ref).not.toBeNull();
      // The PAT is SEALED — the same cipher every channel uses, third secret kind.
      expect(row?.credential_ref).not.toContain(GOOD_PAT);
      // A tool install has NO chat token.
      expect(row?.chat_token_ref).toBeNull();

      // …and it OPENS, against this row's identity, to the pasted PAT.
      const lookup = createInstallsLookup(pool, cipher);
      const install = await lookup.lookupByWorkspace("github", WS_A);
      expect(install?.credentialRef).toBe(GOOD_PAT);

      // NOTHING was mounted — a tool connector has no Chat.
      expect(bridge?.mounts.size()).toBe(0);
    });

    // ── TOOL-DESCRIPTORS: the runner's list ───────────────────────────────────

    it("TOOL-DESCRIPTORS returns the http descriptor + a headersHelper for a connected workspace", async () => {
      const h = await boot(githubRegistry());
      await connectGithub(h, WS_A);

      const response = await h.post("/connectors/connect/tool-descriptors", {
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
      const [descriptor] = body.descriptors;
      expect(descriptor?.provider).toBe("github");
      expect(descriptor?.type).toBe("http");
      expect(descriptor?.url).toBe("https://api.githubcopilot.com/mcp/");
      // The helper POSTs a tool ticket to the loopback tool-headers route.
      expect(descriptor?.headersHelper).toContain("/connect/tool-headers/github");
      // Loopback, never the public URL — a helper through Caddy would be 404'd.
      expect(descriptor?.headersHelper).toContain("http://127.0.0.1:");
      // The embedded ticket is a REAL tool-session ticket that verifies to WS_A —
      // not compared to a fresh sign (each sign carries a new nonce), but proven
      // to be a valid capability the tool-headers route will accept.
      const embedded = descriptor?.headersHelper.match(/"ticket":"([^"]+)"/)?.[1];
      expect(embedded).toBeTruthy();
      expect(
        verifyToolTicket(embedded as string, CONNECT_SECRET)?.workspaceId,
      ).toBe(WS_A);
    });

    it("TOOL-DESCRIPTORS is EMPTY for a workspace that has connected no tool", async () => {
      const h = await boot(githubRegistry());
      await connectGithub(h, WS_A);

      // WS_B has connected nothing — it gets no descriptors, so its agent has no
      // tool servers. This is also the cross-tenant proof: B never learns of A.
      const response = await h.post("/connectors/connect/tool-descriptors", {
        ticket: toolTicket(WS_B),
      });
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ descriptors: [] });
    });

    // ── TOOL-HEADERS: open the sealed PAT at MCP-connect ──────────────────────

    // ── D89 COMPAT PIN #1 ─────────────────────────────────────────────────────
    // A GitHub PAT is a BARE string (`ghp_…`). The dual-shape read-path (D89) must
    // pass it BYTE-FOR-BYTE — a probe-break of the Bearer builder (connect.ts) reds
    // exactly this test and the one below, so this green is not vacuous.
    it("TOOL-HEADERS opens the workspace's sealed PAT and returns the flat Bearer header", async () => {
      const h = await boot(githubRegistry());
      await connectGithub(h, WS_A);

      const response = await h.post("/connectors/connect/tool-headers/github", {
        ticket: toolTicket(WS_A),
      });
      expect(response.status).toBe(200);
      // EXACTLY the shape claude's headersHelper prints into the MCP transport.
      expect(await response.json()).toEqual({
        Authorization: `Bearer ${GOOD_PAT}`,
      });
    });

    // ── D89 dual-shape read-path — the never-throw floor ──────────────────────
    it("TOOL-HEADERS serves a MALFORMED-JSON credential BYTE-FOR-BYTE and never throws (D89)", async () => {
      const h = await boot(githubRegistry());
      // Seed a row whose sealed credential starts with `{` but does NOT parse. A
      // Linear-bundle parser that threw here would 500 the tool route for a paste
      // credential that merely happened to start with a brace — the read-path must
      // fall through to serving the raw bytes.
      const malformed = '{ "access_token": ';
      await upsertInstall(pool, cipher, {
        provider: "github",
        installKey: GOOD_LOGIN,
        workspaceId: WS_A,
        credentialRef: malformed,
      });

      const response = await h.post("/connectors/connect/tool-headers/github", {
        ticket: toolTicket(WS_A),
      });
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({
        Authorization: `Bearer ${malformed}`,
      });
    });

    it("TOOL-HEADERS serves a valid-JSON-object-without-access_token BYTE-FOR-BYTE (D89)", async () => {
      const h = await boot(githubRegistry());
      // Valid JSON, an object, but no non-empty `access_token` — NOT a bundle, so it
      // is served verbatim, not reduced to some field.
      const notABundle = '{"note":"not a bundle"}';
      await upsertInstall(pool, cipher, {
        provider: "github",
        installKey: GOOD_LOGIN,
        workspaceId: WS_A,
        credentialRef: notABundle,
      });

      const response = await h.post("/connectors/connect/tool-headers/github", {
        ticket: toolTicket(WS_A),
      });
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({
        Authorization: `Bearer ${notABundle}`,
      });
    });

    // ── D89 COMPAT PIN #2 ─────────────────────────────────────────────────────
    // The whole helper→route→PAT chain runs for real; the bare PAT must survive the
    // dual-shape read-path byte-for-byte all the way to the runner's stdout.
    it("the headersHelper command runs for real: helper → loopback route → the Bearer header (D38)", async () => {
      const h = await boot(githubRegistry());
      await connectGithub(h, WS_A);

      const body = (await (
        await h.post("/connectors/connect/tool-descriptors", {
          ticket: toolTicket(WS_A),
        })
      ).json()) as { descriptors: Array<{ headersHelper: string }> };
      const helper = body.descriptors[0]?.headersHelper;
      expect(helper).toBeTruthy();

      // Run the EXACT command the runner would run at MCP-connect. Its stdout must
      // be the JSON object claude parses as the server's request headers — the PAT
      // fetched over loopback, never held by the caller that wrote the config.
      //
      // ASYNC on purpose: the bridge serves this loopback request on THIS process's
      // event loop, so a synchronous `execFileSync` would block the loop and
      // deadlock against the very server the curl is calling. `exec` keeps the loop
      // free to answer.
      const { stdout } = await execAsync(helper as string, { timeout: 10_000 });
      expect(JSON.parse(stdout)).toEqual({
        Authorization: `Bearer ${GOOD_PAT}`,
      });
    });

    // ── W25 REAL-BRIDGE LINEAR LEG (charter D213-D216) ────────────────────────
    // The cloud shim (scripts/connectors/cloud-sandbox-runner.mjs) now POSTs the
    // turn's tool ticket to THIS route and merges the finished header into the
    // in-sandbox MCP config. tool-descriptors.test.ts previously pinned only the
    // bare-PAT (GitHub) shape; these two pin the OAUTH-BUNDLE shape the shim's
    // fetch will meet for Linear — through the REAL route, real Postgres, and a
    // registry WITHOUT refresh deps, so the byte-for-byte bundle read-path (D89)
    // is what serves the Bearer.

    it("TOOL-HEADERS opens a Linear OAUTH BUNDLE to Bearer <access_token> via the real route (W25)", async () => {
      const registry = createConnectorRegistry();
      // NO refresh deps on purpose: without OAuth client credentials the
      // connector carries no refreshCredential hook, so the route serves the
      // STORED bundle byte-for-byte — access_token out, nothing exchanged.
      registry.register(createLinearConnector());
      const h = await boot(registry);

      // The bundle shape an OAuth connect seals (linear-token-refresh.test.ts):
      // {access_token, refresh_token, expires_at}. Seeded via upsertInstall —
      // the same one-seal write path the callback uses. expires_at is in the
      // PAST to prove the no-refresh-deps path serves the stored token as-is.
      await upsertInstall(pool, cipher, {
        provider: "linear",
        installKey: LINEAR_ORG,
        workspaceId: WS_A,
        credentialRef: JSON.stringify({
          access_token: "at_w25_linear",
          refresh_token: "rt_w25_linear",
          expires_at: Date.now() - 1_000,
        }),
      });

      const response = await h.post("/connectors/connect/tool-headers/linear", {
        ticket: toolTicket(WS_A),
      });
      expect(response.status).toBe(200);
      // The bundle is reduced to its access_token — NEVER the whole JSON, and
      // never the refresh_token. This is the exact object the cloud shim merges
      // into the in-sandbox MCP config entry's headers.
      expect(await response.json()).toEqual({
        Authorization: "Bearer at_w25_linear",
      });
    });

    it("a cross-workspace ticket CANNOT open the Linear bundle — the opaque 404 (W25)", async () => {
      const registry = createConnectorRegistry();
      registry.register(createLinearConnector());
      const h = await boot(registry);

      await upsertInstall(pool, cipher, {
        provider: "linear",
        installKey: LINEAR_ORG,
        workspaceId: WS_A,
        credentialRef: JSON.stringify({
          access_token: "at_w25_linear",
          refresh_token: "rt_w25_linear",
          expires_at: Date.now() - 1_000,
        }),
      });

      // WS_B holds a VALID tool ticket — for B. The lookup keyed on B's
      // workspace finds no linear install: the opaque 404, byte-identical to an
      // unknown route. This is the server half of the shim's fail-closed leg —
      // a sandbox for workspace B can never fetch A's credential.
      const response = await h.post("/connectors/connect/tool-headers/linear", {
        ticket: toolTicket(WS_B),
      });
      expect(response.status).toBe(404);
      expect(await response.text()).toBe('{"error":"not_found"}');
    });

    // ── CROSS-TENANT + LOOPBACK BOUNDARY ──────────────────────────────────────

    it("a workspace's tool ticket CANNOT open another workspace's PAT — the opaque 404", async () => {
      const h = await boot(githubRegistry());
      await connectGithub(h, WS_A);

      // B holds a VALID tool ticket — for B — and asks for github headers. B has no
      // github install, so the lookup keyed on B's workspace finds nothing: 404,
      // byte-identical to an unknown route. B cannot even learn A connected github.
      const response = await h.post("/connectors/connect/tool-headers/github", {
        ticket: toolTicket(WS_B),
      });
      expect(response.status).toBe(404);
      expect(await response.text()).toBe('{"error":"not_found"}');

      // A's PAT is untouched and still openable for A.
      const lookup = createInstallsLookup(pool, cipher);
      expect((await lookup.lookupByWorkspace("github", WS_A))?.credentialRef).toBe(
        GOOD_PAT,
      );
    });

    it("x-forwarded-* + a VALID tool ticket is the opaque 404 — tool-headers is loopback-only", async () => {
      const h = await boot(githubRegistry());
      await connectGithub(h, WS_A);

      for (const header of ["x-forwarded-for", "x-forwarded-host"]) {
        const proxied = await h.post(
          "/connectors/connect/tool-headers/github",
          { ticket: toolTicket(WS_A) },
          { [header]: "203.0.113.7" },
        );
        expect(proxied.status).toBe(404);
        expect(await proxied.text()).toBe('{"error":"not_found"}');
      }
    });

    it("a paste ticket (wrong provider binding) cannot be replayed at the tool routes", async () => {
      const h = await boot(githubRegistry());
      await connectGithub(h, WS_A);

      // A 600 s connect ticket bound to provider "github" — valid for /connect, but
      // it is NOT a tool-session ticket, so the tool routes refuse it (401).
      const response = await h.post("/connectors/connect/tool-headers/github", {
        ticket: connectTicket(WS_A),
      });
      expect(response.status).toBe(401);
    });

    it("GET on a tool route is the opaque 404 — these are POST-only", async () => {
      const h = await boot(githubRegistry());
      const response = await fetch(`${h.base}/connectors/connect/tool-descriptors`);
      expect(response.status).toBe(404);
      expect(await response.text()).toBe('{"error":"not_found"}');
    });
  },
);
