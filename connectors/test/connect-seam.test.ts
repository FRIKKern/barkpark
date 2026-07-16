/**
 * THE CONNECT LOOP, END TO END (charter D50/D51/D53).
 *
 * Paste a token -> the install is validated by the PROVIDER -> written and SEALED
 * in one upsert -> MOUNTED LIVE, with no restart -> and the very next webhook for
 * it routes. Then disconnect: unmounted, DELETED, and gone for good.
 *
 * Everything below runs against a REAL Postgres through the REAL `startBridge`,
 * because every interesting failure in this seam is an interaction: the ticket is
 * verified in one module, the row is written in another, and the mount happens in a
 * third. A fake for any one of them would prove only that the fake agrees with
 * itself.
 *
 * NO NETWORK ANYWHERE. `fetch` is injected into both connectors, so a paste-mode
 * `validate()` is exercised for real without a bot token and without the internet.
 *
 * THE FOUR PROPERTIES THIS FILE IS REALLY ABOUT:
 *
 *   1. LOOPBACK-ONLY BY CONSTRUCTION — a request carrying `x-forwarded-for` gets
 *      the opaque 404 EVEN WITH A VALID TICKET. Caddy always appends it, so the
 *      public path can never reach these routes.
 *   2. THE PROVIDER COMES FROM THE TICKET, and the install key comes from the
 *      PROVIDER's own answer — never from the body.
 *   3. A CROSS-TENANT DISCONNECT IS UNREPRESENTABLE — byte-identical 404, so the
 *      route is not an install-enumeration oracle either.
 *   4. ONE BAD TOKEN CANNOT TAKE THE FLEET DOWN (D53) — the lowest-sorting install
 *      throwing at `chat.initialize()` used to reject `startBridge` and 503 the
 *      whole `/connectors` path for every tenant.
 */
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { Adapter } from "chat";
import pg from "pg";

import type { BridgeConfig } from "../src/config.js";
import { signConnectTicket } from "../src/connect/ticket.js";
import {
  createConnectorRegistry,
  type ConnectorRegistry,
} from "../src/connector/registry.js";
import type { Connector, ConnectorInstall } from "../src/connector/types.js";
import { createDiscordConnector } from "../src/connectors/discord.js";
import { createTelegramConnector } from "../src/connectors/telegram.js";
import { createCredentialCipher } from "../src/crypto/credential-cipher.js";
import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import { startBridge, type Bridge } from "../src/index.js";
import { createInstallsLookup, upsertInstall } from "../src/tenant/installs.js";

const CREDENTIAL_KEY = Buffer.alloc(32, 7).toString("base64");
const cipher = createCredentialCipher({ key: CREDENTIAL_KEY });

const CONNECT_SECRET = "connect-secret-for-the-seam-test";
const WS_A = "11111111-1111-4111-8111-111111111111";
const WS_B = "22222222-2222-4222-8222-222222222222";

/** The token the fake provider blesses. Anything else is refused. */
const GOOD_TOKEN = "77777777:AA-a-good-bot-token";
const GOOD_KEY = "77777777";

// ═══════════════════════════════════════════════════════════════════════════
// PART 1 — paste-mode validation, with fetch injected. No database, no network.
// ═══════════════════════════════════════════════════════════════════════════

/** A `fetch` that records what it was asked and answers a canned response. */
function recordingFetch(
  answer: (url: string, init?: RequestInit) => Response | Promise<Response>,
): { fetch: typeof fetch; calls: Array<{ url: string; init?: RequestInit }> } {
  const calls: Array<{ url: string; init?: RequestInit }> = [];
  const impl = (async (input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    const url = typeof input === "string" ? input : String(input);
    calls.push(init ? { url, init } : { url });
    return answer(url, init);
  }) as unknown as typeof fetch;
  return { fetch: impl, calls };
}

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

describe("paste-mode validate — Telegram (getMe), no network (D51)", () => {
  it("accepts a live token: the install key is the BOT ID and the display name is @username", async () => {
    const { fetch: doFetch, calls } = recordingFetch(() =>
      json({ ok: true, result: { id: 77777777, username: "acme_bot" } }),
    );
    const telegram = createTelegramConnector({ fetch: doFetch });

    const verdict = await telegram.connect?.validate(GOOD_TOKEN);

    expect(verdict).toEqual({
      ok: true,
      installKey: GOOD_KEY,
      displayName: "@acme_bot",
    });
    // It asked TELEGRAM, with the token in the path, exactly once.
    expect(calls).toHaveLength(1);
    expect(calls[0]?.url).toBe(`https://api.telegram.org/bot${GOOD_TOKEN}/getMe`);
  });

  it("REFUSES a revoked token at PASTE TIME, with Telegram's own reason — not at the next restart", async () => {
    // This is the whole argument for validate-first (D51/D53): before this wave a
    // revoked token was discovered by `chat.initialize()` throwing at BOOT, which
    // crash-looped the unit and eventually 503'd every tenant on the box.
    const { fetch: doFetch } = recordingFetch(() =>
      json({ ok: false, description: "Unauthorized" }, 401),
    );
    const telegram = createTelegramConnector({ fetch: doFetch });

    expect(await telegram.connect?.validate("11111:AA-revoked")).toEqual({
      ok: false,
      reason: "Unauthorized",
    });
  });

  it("refuses a malformed token WITHOUT spending a round trip on it", async () => {
    const { fetch: doFetch, calls } = recordingFetch(() => json({ ok: true }));
    const telegram = createTelegramConnector({ fetch: doFetch });

    const verdict = await telegram.connect?.validate("not-a-token");

    expect(verdict?.ok).toBe(false);
    expect(calls).toHaveLength(0);
  });

  it("distinguishes 'Telegram is unreachable' from 'your token is bad' (or the operator re-pastes a good token five times)", async () => {
    const { fetch: doFetch } = recordingFetch(() => {
      throw new Error("ECONNREFUSED");
    });
    const telegram = createTelegramConnector({ fetch: doFetch });

    const verdict = await telegram.connect?.validate(GOOD_TOKEN);
    expect(verdict).toMatchObject({ ok: false });
    expect((verdict as { reason: string }).reason).toContain("could not reach");
  });
});

describe("paste-mode validate — Discord (users/@me), no network (D41/D51)", () => {
  const CREDENTIAL = JSON.stringify({
    applicationId: "app-123",
    botToken: "discord-bot-token",
    publicKey: "pubkey",
  });

  it("accepts a live credential triple: install key = APPLICATION ID, auth header = `Bot <token>`", async () => {
    const { fetch: doFetch, calls } = recordingFetch(() =>
      json({ id: "app-123", username: "acme" }),
    );
    const discord = createDiscordConnector({ fetch: doFetch });

    expect(await discord.connect?.validate(CREDENTIAL)).toEqual({
      ok: true,
      installKey: "app-123",
      displayName: "@acme",
    });
    expect(calls[0]?.url).toBe("https://discord.com/api/v10/users/@me");
    expect(
      (calls[0]?.init?.headers as Record<string, string>)["authorization"],
    ).toBe("Bot discord-bot-token");
  });

  it("REFUSES a bare bot token — Discord needs the triple, and the vendor's env fallback is a cross-tenant leak", async () => {
    const { fetch: doFetch, calls } = recordingFetch(() => json({}));
    const discord = createDiscordConnector({ fetch: doFetch });

    const verdict = await discord.connect?.validate("just-a-bot-token");

    // Refused on SHAPE, before any network call. This is the mistake every
    // first-time operator makes, and `parseDiscordCredential` throwing at MOUNT is
    // exactly what we do not want them to discover later.
    expect(verdict?.ok).toBe(false);
    expect(calls).toHaveLength(0);
  });

  it("REFUSES a revoked bot token with Discord's own message", async () => {
    const { fetch: doFetch } = recordingFetch(() =>
      json({ message: "401: Unauthorized" }, 401),
    );
    const discord = createDiscordConnector({ fetch: doFetch });

    expect(await discord.connect?.validate(CREDENTIAL)).toEqual({
      ok: false,
      reason: "401: Unauthorized",
    });
  });

  it("REFUSES an applicationId that is not the token's OWN bot — a public app id must not become a caller-chosen install key", async () => {
    // THE TENANT BOUNDARY. An application id is PUBLIC (it is in every bot's invite
    // URL), and the bot token here is the CALLER'S OWN, perfectly valid one — so
    // Discord answers 200 and nothing about this request is unauthenticated.
    //
    // Taking the install key from the pasted `applicationId` would therefore let
    // workspace B name workspace A's install key: `upsertInstall`'s ON CONFLICT
    // repoints A's row to B, `addInstall` takes A's Gateway down, and A's install is
    // GONE — with no secret of A's ever changing hands. The route re-validates
    // server-side exactly so the key cannot be caller-chosen; an unverified field of
    // the pasted blob would hand that choice straight back.
    const victimsAppId = "999888777";
    const { fetch: doFetch } = recordingFetch(() =>
      // The caller's own bot. Live, authentic — and a DIFFERENT application.
      json({ id: "111222333", username: "attacker_bot" }),
    );
    const discord = createDiscordConnector({ fetch: doFetch });

    const verdict = await discord.connect?.validate(
      JSON.stringify({
        applicationId: victimsAppId,
        botToken: "the-callers-own-valid-token",
        publicKey: "pubkey",
      }),
    );

    expect(verdict?.ok).toBe(false);
    expect((verdict as { reason: string }).reason).toContain("111222333");
    expect((verdict as { reason: string }).reason).toContain(victimsAppId);
  });
});

describe("catalog-visible but NOT connectable (D51)", () => {
  it("Slack, Teams, WhatsApp and iMessage declare NO `connect` — a paste flow would be wrong for each", async () => {
    // Slack installs over OAuth; Teams needs per-org Azure admin consent; WhatsApp
    // needs a Meta app + number; iMessage is a self-hosted operator profile. The
    // connect routes 404 for all of them, opaquely.
    const { createSlackConnector } = await import("../src/connectors/slack.js");
    const { createTeamsConnector } = await import("../src/connectors/teams.js");
    const { createWhatsappConnector } =
      await import("../src/connectors/whatsapp.js");
    const { createIMessageConnector } =
      await import("../src/connectors/imessage.js");

    expect(createTeamsConnector().connect).toBeUndefined();
    expect(createWhatsappConnector().connect).toBeUndefined();
    expect(createIMessageConnector().connect).toBeUndefined();
    expect(
      createSlackConnector({
        signingSecret: "s",
        clientId: "c",
        clientSecret: "cs",
        installs: createInstallsLookup(
          { query: async () => ({ rows: [] }) },
          cipher,
        ),
      }).connect,
    ).toBeUndefined();
  });
});

// ═══════════════════════════════════════════════════════════════════════════
// PART 2 — the routes, through the REAL bridge, against a REAL Postgres.
// ═══════════════════════════════════════════════════════════════════════════

const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";
const TEST_DB = `connectors_connect_seam_test_${process.pid}_${Date.now()}`;

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

/** An adapter that initializes, and answers a webhook so a LIVE mount is observable. */
function stubAdapter(installKey: string, onInit?: () => void): Adapter {
  return {
    name: "paste",
    async initialize() {
      onInit?.();
    },
    async handleWebhook(): Promise<Response> {
      return new Response(JSON.stringify({ ok: true, installKey }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    },
  } as unknown as Adapter;
}

/**
 * A paste-mode connector with a webhook, so "mounted LIVE, no restart" is a fact we
 * can OBSERVE (its webhook route starts answering) rather than a field we assert on.
 */
function pasteConnector(
  options: {
    onAdapter?: (install: ConnectorInstall) => void;
  } = {},
): Connector {
  return {
    id: "paste",
    direction: "channel",
    auth: "token",
    tenantResolution: "credential-bound",
    webhook: { keySource: "path" },
    connect: {
      mode: "paste",
      credentialLabel: "Token",
      async validate(credential: string) {
        if (credential !== GOOD_TOKEN) {
          return { ok: false, reason: "the provider rejected that token" };
        }
        return { ok: true, installKey: GOOD_KEY, displayName: "@acme_bot" };
      },
    },
    adapterFactory(install: ConnectorInstall): Adapter {
      options.onAdapter?.(install);
      return stubAdapter(install.installKey);
    },
    async resolveTenant() {
      return null;
    },
  };
}

/** The reserved id for the tool-direction fixture. Distinct from `paste`. */
const TOOL_PROVIDER = "toolgh";

/**
 * A paste-mode TOOL connector (charter D69) — the OUTBOUND direction. Same
 * onboarding shape as `pasteConnector` (the operator pastes a PAT, `validate`
 * blesses it), but `direction: "tool"`: it seals ONLY its provider credential,
 * carries NO chat token, and is NEVER mounted as a Chat (`registry.channels()`
 * excludes it, and `connect()` branches on direction). The `onAdapter` spy is the
 * load-bearing part: it proves `adapterFactory` is never invoked for a tool row —
 * without it, "not mounted" is a claim, not a fact. A distinct id from `paste`
 * keeps the two fixtures' rows disjoint in the shared table.
 */
function toolConnector(
  options: {
    onAdapter?: (install: ConnectorInstall) => void;
  } = {},
): Connector {
  return {
    id: TOOL_PROVIDER,
    direction: "tool",
    auth: "token",
    tenantResolution: "credential-bound",
    // A tool connector's MCP transport descriptor — present on a tool, absent on
    // every channel. Non-secret; the PAT arrives per-install on /connect.
    toolDescriptor: { type: "http", url: "http://mcp.invalid/" },
    connect: {
      mode: "paste",
      credentialLabel: "Personal access token",
      async validate(credential: string) {
        if (credential !== GOOD_TOKEN) {
          return { ok: false, reason: "the provider rejected that token" };
        }
        return { ok: true, installKey: GOOD_KEY, displayName: "@acme_gh" };
      },
    },
    adapterFactory(install: ConnectorInstall): Adapter {
      // If this ever runs for a tool install, the seam mounted something it must
      // not have — the spy turns that into a hard test failure.
      options.onAdapter?.(install);
      return stubAdapter(install.installKey);
    },
    async resolveTenant() {
      return null;
    },
  };
}

describe.skipIf(!reachable && !REQUIRE_DB)(
  "the connect loop — through startBridge, against a real Postgres (D50/D51)",
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

    function configFor(overrides: Partial<BridgeConfig> = {}): BridgeConfig {
      return {
        databaseUrl: urlForDatabase(ADMIN_URL, TEST_DB),
        // Never called: the connect seam never dispatches a turn. A bogus URL keeps
        // that honest — anything that tried would fail loudly.
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
        ...overrides,
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

    async function boot(
      registry: ConnectorRegistry,
      config: BridgeConfig = configFor(),
    ): Promise<Harness> {
      bridge = await startBridge(config, { registry });
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
              WHERE provider = 'paste' AND install_key = $1`,
            [installKey],
          );
          return rows[0] ?? null;
        },
      };
    }

    function registryWith(connector: Connector): ConnectorRegistry {
      const registry = createConnectorRegistry();
      registry.register(connector);
      return registry;
    }

    const ticketFor = (workspaceId: string, provider = "paste") =>
      signConnectTicket(workspaceId, provider, CONNECT_SECRET);

    /** The raw tool-provider install row — `h.rawRow` hardcodes `paste`. */
    const toolRow = async (installKey: string) => {
      const { rows } = await pool.query<{
        workspace_id: string | null;
        credential_ref: string | null;
        chat_token_ref: string | null;
      }>(
        `SELECT workspace_id, credential_ref, chat_token_ref
           FROM chat_bridge.connector_installs
          WHERE provider = $1 AND install_key = $2`,
        [TOOL_PROVIDER, installKey],
      );
      return rows[0] ?? null;
    };

    // ── VALIDATE ────────────────────────────────────────────────────────────

    it("VALIDATE returns the install key and display name — and writes NOTHING", async () => {
      const h = await boot(registryWith(pasteConnector()));

      const response = await h.post("/connectors/connect/validate", {
        ticket: ticketFor(WS_A),
        credential: GOOD_TOKEN,
      });

      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({
        ok: true,
        provider: "paste",
        install_key: GOOD_KEY,
        display_name: "@acme_bot",
      });

      // Studio needs the install key BEFORE it mints, so the chat token can be
      // labelled `connector:paste:77777777` — the only thing that lets DISCONNECT
      // revoke exactly that token later. No row exists yet.
      expect(await h.rawRow(GOOD_KEY)).toBeNull();
      expect(bridge?.mounts.size()).toBe(0);
    });

    it("VALIDATE refuses a bad credential with a 422 and a reason a human can act on — and still writes nothing", async () => {
      const h = await boot(registryWith(pasteConnector()));

      const response = await h.post("/connectors/connect/validate", {
        ticket: ticketFor(WS_A),
        credential: "revoked-token",
      });

      expect(response.status).toBe(422);
      expect(await response.json()).toEqual({
        error: "invalid_credential",
        reason: "the provider rejected that token",
      });
      expect(await h.rawRow(GOOD_KEY)).toBeNull();
    });

    // ── CONNECT ─────────────────────────────────────────────────────────────

    it("CONNECT writes BOTH secrets in ONE upsert, SEALED, and MOUNTS LIVE — the webhook routes with no restart", async () => {
      const h = await boot(registryWith(pasteConnector()));

      const webhookUrl = `${h.base}/connectors/webhooks/paste/${GOOD_KEY}`;
      // Before: nothing is installed, so the route is the opaque 404.
      expect((await fetch(webhookUrl, { method: "POST", body: "{}" })).status).toBe(
        404,
      );

      const response = await h.post("/connectors/connect", {
        ticket: ticketFor(WS_A),
        credential: GOOD_TOKEN,
        chat_token: "bp_chat_ws_a",
      });

      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({
        ok: true,
        provider: "paste",
        install_key: GOOD_KEY,
        workspace_id: WS_A,
        mounted: true,
      });

      // The row: both secrets present, and NEITHER is plaintext.
      const row = await h.rawRow(GOOD_KEY);
      expect(row?.workspace_id).toBe(WS_A);
      expect(row?.credential_ref).not.toBeNull();
      expect(row?.chat_token_ref).not.toBeNull();
      expect(row?.credential_ref).not.toContain(GOOD_TOKEN);
      expect(row?.chat_token_ref).not.toContain("bp_chat_ws_a");

      // …and they OPEN, against this row's identity, to what was pasted.
      const lookup = createInstallsLookup(pool, cipher);
      const install = await lookup.lookupInstall("paste", GOOD_KEY);
      expect(install?.credentialRef).toBe(GOOD_TOKEN);
      expect(install?.chatToken).toBe("bp_chat_ws_a");

      // LIVE. No restart, no deploy: the webhook route answers NOW.
      const routed = await fetch(webhookUrl, { method: "POST", body: "{}" });
      expect(routed.status).toBe(200);
      expect(await routed.json()).toMatchObject({ ok: true, installKey: GOOD_KEY });
      expect(bridge?.mounts.size()).toBe(1);
    });

    it("takes the install key from the PROVIDER, never from the body — a client-supplied key cannot seize another tenant's row", async () => {
      const h = await boot(registryWith(pasteConnector()));

      // Workspace B already owns install "victim-key".
      await upsertInstall(pool, cipher, {
        provider: "paste",
        installKey: "victim-key",
        workspaceId: WS_B,
        credentialRef: "b-secret",
        chatToken: "bp_chat_ws_b",
      });

      // Workspace A holds a perfectly valid ticket for ITSELF, and asks for B's key.
      // If the route trusted `install_key`, the upsert's ON CONFLICT would repoint
      // that row's workspace_id to A — a one-request tenant takeover.
      const response = await h.post("/connectors/connect", {
        ticket: ticketFor(WS_A),
        credential: GOOD_TOKEN,
        chat_token: "bp_chat_ws_a",
        install_key: "victim-key",
        provider: "some-other-provider",
      });

      expect(response.status).toBe(200);
      // The key is what the PROVIDER said the credential is.
      expect(await response.json()).toMatchObject({
        install_key: GOOD_KEY,
        provider: "paste",
        workspace_id: WS_A,
      });

      // B's row is untouched.
      const victim = await h.rawRow("victim-key");
      expect(victim?.workspace_id).toBe(WS_B);
    });

    it("REFUSES to connect over an install that belongs to ANOTHER workspace — the row is not repointed, and the incumbent stays mounted", async () => {
      // The residue of the same hole. Even with a provider-authenticated install key,
      // `UPSERT_INSTALL` sets `workspace_id = EXCLUDED.workspace_id` UNCONDITIONALLY:
      // so a connect from workspace A against a key workspace B already owns would
      // repoint B's row, take B's adapter down, and replace B's sealed chat token.
      // No secret of B's leaks (the AAD sees to that) — B's install simply vanishes.
      const h = await boot(registryWith(pasteConnector()));

      // B owns GOOD_KEY — the very key the provider will hand back to A.
      await upsertInstall(pool, cipher, {
        provider: "paste",
        installKey: GOOD_KEY,
        workspaceId: WS_B,
        credentialRef: GOOD_TOKEN,
        chatToken: "bp_chat_ws_b",
      });

      const response = await h.post("/connectors/connect", {
        ticket: ticketFor(WS_A),
        credential: GOOD_TOKEN,
        chat_token: "bp_chat_ws_a",
      });

      expect(response.status).toBe(409);
      expect(await response.json()).toMatchObject({
        error: "install_owned_elsewhere",
      });

      // B's row is EXACTLY as it was: still B's, still B's chat token.
      const row = await h.rawRow(GOOD_KEY);
      expect(row?.workspace_id).toBe(WS_B);
      expect(
        cipher.open(row?.chat_token_ref as string, {
          provider: "paste",
          installKey: GOOD_KEY,
          workspaceId: WS_B,
        }),
      ).toBe("bp_chat_ws_b");
    });

    it("a re-connect by the SAME workspace still lands — the guard is a tenant boundary, not a write-once lock", async () => {
      const h = await boot(registryWith(pasteConnector()));

      await upsertInstall(pool, cipher, {
        provider: "paste",
        installKey: GOOD_KEY,
        workspaceId: WS_A,
        credentialRef: "an-older-token",
        chatToken: "bp_chat_ws_a_old",
      });

      const response = await h.post("/connectors/connect", {
        ticket: ticketFor(WS_A),
        credential: GOOD_TOKEN,
        chat_token: "bp_chat_ws_a_new",
      });

      expect(response.status).toBe(200);
      const row = await h.rawRow(GOOD_KEY);
      expect(row?.workspace_id).toBe(WS_A);
      expect(
        cipher.open(row?.chat_token_ref as string, {
          provider: "paste",
          installKey: GOOD_KEY,
          workspaceId: WS_A,
        }),
      ).toBe("bp_chat_ws_a_new");
    });

    it("a FAILED MOUNT deletes the row it just wrote and answers 502 mount_failed — never a row that crash-loops the next boot", async () => {
      // A credential the provider blesses but the adapter refuses. Leaving this row
      // behind is exactly the D53 scenario: it boots, it throws, and (before the
      // containment below) it took the whole unit with it.
      const connector = pasteConnector();
      const registry = createConnectorRegistry();
      registry.register({
        ...connector,
        adapterFactory(): Adapter {
          throw new Error("adapter refused the credential");
        },
      });
      const h = await boot(registry);

      const response = await h.post("/connectors/connect", {
        ticket: ticketFor(WS_A),
        credential: GOOD_TOKEN,
        chat_token: "bp_chat_ws_a",
      });

      expect(response.status).toBe(502);
      expect(await response.json()).toMatchObject({ error: "mount_failed" });

      // Rolled back. Nothing is installed, and the next boot has nothing to trip on.
      expect(await h.rawRow(GOOD_KEY)).toBeNull();
      expect(bridge?.mounts.size()).toBe(0);
    });

    // ── DISCONNECT ──────────────────────────────────────────────────────────

    it("DISCONNECT unmounts AND deletes the row — so it survives a restart", async () => {
      const h = await boot(registryWith(pasteConnector()));
      const webhookUrl = `${h.base}/connectors/webhooks/paste/${GOOD_KEY}`;

      await h.post("/connectors/connect", {
        ticket: ticketFor(WS_A),
        credential: GOOD_TOKEN,
        chat_token: "bp_chat_ws_a",
      });
      expect((await fetch(webhookUrl, { method: "POST", body: "{}" })).status).toBe(
        200,
      );

      const response = await h.post("/connectors/disconnect", {
        ticket: ticketFor(WS_A),
        install_key: GOOD_KEY,
      });

      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({ ok: true, removed: true });

      // Unrouted NOW…
      expect((await fetch(webhookUrl, { method: "POST", body: "{}" })).status).toBe(
        404,
      );
      // …and DELETED, which is the half the bridge did not have: `removeInstall`
      // is in-memory only, so before `deleteInstall` the next boot re-read this row
      // and mounted the "disconnected" bot straight back.
      expect(await h.rawRow(GOOD_KEY)).toBeNull();
    });

    it("a CROSS-TENANT disconnect is the SAME OPAQUE 404 as an unknown install — and the row survives", async () => {
      const h = await boot(registryWith(pasteConnector()));

      // A's install, connected normally.
      await h.post("/connectors/connect", {
        ticket: ticketFor(WS_A),
        credential: GOOD_TOKEN,
        chat_token: "bp_chat_ws_a",
      });

      // B holds a VALID ticket — for B — and tries to disconnect A's install.
      const attack = await h.post("/connectors/disconnect", {
        ticket: ticketFor(WS_B),
        install_key: GOOD_KEY,
      });
      const unknown = await h.post("/connectors/disconnect", {
        ticket: ticketFor(WS_B),
        install_key: "no-such-install",
      });

      expect(attack.status).toBe(404);
      // BYTE-IDENTICAL to "there is no such install": B cannot even learn that A's
      // install exists. Unrepresentable, not merely untaken.
      expect(await attack.text()).toBe(await unknown.text());
      expect(attack.status).toBe(unknown.status);

      // A is untouched and still mounted.
      expect((await h.rawRow(GOOD_KEY))?.workspace_id).toBe(WS_A);
      expect(bridge?.mounts.size()).toBe(1);
    });

    // ── THE LOOPBACK BOUNDARY ───────────────────────────────────────────────

    it("x-forwarded-for + a VALID TICKET is the SAME OPAQUE 404 as an unknown route (loopback-only by construction)", async () => {
      const h = await boot(registryWith(pasteConnector()));

      const unknownRoute = await fetch(`${h.base}/connectors/nope`, {
        method: "POST",
        body: "{}",
      });

      // Caddy appends x-forwarded-for to EVERYTHING it proxies. Its presence proves
      // the request came through the public path — so it can never connect anything,
      // ticket or no ticket, and it must not even hint that the route exists.
      for (const header of ["x-forwarded-for", "x-forwarded-host"]) {
        const proxied = await h.post(
          "/connectors/connect",
          {
            ticket: ticketFor(WS_A),
            credential: GOOD_TOKEN,
            chat_token: "bp_chat_ws_a",
          },
          { [header]: "203.0.113.7" },
        );

        expect(proxied.status).toBe(404);
        expect(await proxied.text()).toBe('{"error":"not_found"}');
        expect(proxied.status).toBe(unknownRoute.status);
      }

      // And nothing was written by any of them.
      expect(await h.rawRow(GOOD_KEY)).toBeNull();

      // The WEBHOOK routes, by contrast, MUST still work through the proxy — they
      // are the public half of this same server, and they trust those very headers
      // to build the adapter's URL. The asymmetry is the design.
      await h.post("/connectors/connect", {
        ticket: ticketFor(WS_A),
        credential: GOOD_TOKEN,
        chat_token: "bp_chat_ws_a",
      });
      const viaProxy = await fetch(
        `${h.base}/connectors/webhooks/paste/${GOOD_KEY}`,
        {
          method: "POST",
          headers: { "x-forwarded-for": "203.0.113.7" },
          body: "{}",
        },
      );
      expect(viaProxy.status).toBe(200);
    });

    // ── THE TICKET IS THE AUTHORIZATION ─────────────────────────────────────

    it("refuses an unsigned, forged, expired or missing ticket with a 401 — and installs nothing", async () => {
      const h = await boot(registryWith(pasteConnector()));

      const bodies = [
        { credential: GOOD_TOKEN, chat_token: "t" }, // no ticket at all
        { ticket: "garbage", credential: GOOD_TOKEN, chat_token: "t" },
        {
          // Correctly shaped, signed with the WRONG secret.
          ticket: signConnectTicket(WS_A, "paste", "not-our-secret"),
          credential: GOOD_TOKEN,
          chat_token: "t",
        },
        {
          // Correctly signed — and 11 minutes old.
          ticket: signConnectTicket(WS_A, "paste", CONNECT_SECRET, {
            now: () => Date.now() - 660_000,
          }),
          credential: GOOD_TOKEN,
          chat_token: "t",
        },
      ];

      for (const body of bodies) {
        const response = await h.post("/connectors/connect", body);
        expect(response.status).toBe(401);
      }
      expect(await h.rawRow(GOOD_KEY)).toBeNull();
    });

    it("a ticket minted for ANOTHER PROVIDER is a 404 — the provider comes from the ticket, and it must match", async () => {
      const h = await boot(registryWith(pasteConnector()));

      // Valid signature, valid workspace, wrong provider. The signature proves the
      // ticket was minted — not that it was minted for THIS action.
      const response = await h.post("/connectors/connect", {
        ticket: ticketFor(WS_A, "telegram"),
        credential: GOOD_TOKEN,
        chat_token: "bp_chat_ws_a",
      });

      // 404, not 401: "telegram" is not a registered connector in this bridge, and
      // saying WHICH providers exist would be an enumeration oracle.
      expect(response.status).toBe(404);
      expect(await h.rawRow(GOOD_KEY)).toBeNull();
    });

    it("a malformed body is a 400, never a 500", async () => {
      const h = await boot(registryWith(pasteConnector()));

      expect((await h.post("/connectors/connect", "not json at all")).status).toBe(
        400,
      );
      expect((await h.post("/connectors/connect", "[1,2,3]")).status).toBe(400);
      // A valid ticket with no credential is still a 400 — the shape is wrong.
      expect(
        (await h.post("/connectors/connect", { ticket: ticketFor(WS_A) })).status,
      ).toBe(400);
    });

    it("GET on a connect route is the opaque 404 — these are POST-only", async () => {
      const h = await boot(registryWith(pasteConnector()));

      const response = await fetch(`${h.base}/connectors/connect/validate`);
      expect(response.status).toBe(404);
      expect(await response.text()).toBe('{"error":"not_found"}');
    });

    // ── NOT MOUNTED WITHOUT A SECRET ────────────────────────────────────────

    it("with NO CONNECTORS_CONNECT_SECRET the routes are NOT MOUNTED — and the bridge still boots and still answers /health", async () => {
      // A `required()` here would mean every host whose .env predates this feature
      // REFUSES TO BOOT — i.e. /connectors becomes the maintenance 503 for every
      // tenant on the box, over a feature nobody is using yet.
      const config = configFor();
      delete (config as { connectSecret?: string }).connectSecret;

      const h = await boot(registryWith(pasteConnector()), config);

      const connect = await h.post("/connectors/connect", {
        ticket: ticketFor(WS_A),
        credential: GOOD_TOKEN,
        chat_token: "bp_chat_ws_a",
      });
      expect(connect.status).toBe(404);
      expect(await connect.text()).toBe('{"error":"not_found"}');

      for (const path of [
        "/connectors/connect/validate",
        "/connectors/disconnect",
      ]) {
        expect((await h.post(path, { ticket: ticketFor(WS_A) })).status).toBe(404);
      }

      // The bridge is UP. That is the whole point.
      const health = await fetch(`${h.base}/connectors/health`);
      expect(health.status).toBe(200);
      expect(await health.json()).toEqual({ status: "ok" });
      expect(await h.rawRow(GOOD_KEY)).toBeNull();
    });

    // ── D53: ONE BAD TOKEN MUST NOT TAKE THE FLEET DOWN ─────────────────────

    it("BLAST RADIUS: the LOWEST-SORTING install throwing at chat.initialize() no longer rejects startBridge — the healthy tenant IS mounted", async () => {
      // `listInstalls` is ORDER BY install_key, so "aaa-revoked" is mounted FIRST.
      // Before this wave its throw escaped startBridge -> process.exit(1) ->
      // systemd crash-loop -> instance-deploy.sh disables the unit -> /connectors
      // is the maintenance 503 FOR EVERY TENANT. The healthy install below never
      // mounted at all.
      await upsertInstall(pool, cipher, {
        provider: "paste",
        installKey: "aaa-revoked",
        workspaceId: WS_A,
        credentialRef: "revoked",
        chatToken: "bp_chat_ws_a",
      });
      await upsertInstall(pool, cipher, {
        provider: "paste",
        installKey: "zzz-healthy",
        workspaceId: WS_B,
        credentialRef: GOOD_TOKEN,
        chatToken: "bp_chat_ws_b",
      });

      const initialized: string[] = [];
      const registry = createConnectorRegistry();
      registry.register({
        ...pasteConnector(),
        adapterFactory(install: ConnectorInstall): Adapter {
          return stubAdapter(install.installKey, () => {
            // The real failure mode: the ADAPTER authenticates on initialize, and a
            // revoked token throws AuthenticationError out of `chat.initialize()`.
            if (install.credentialRef === "revoked") {
              throw new Error("AuthenticationError: 401 Unauthorized");
            }
            initialized.push(install.installKey);
          });
        },
      });

      // startBridge RESOLVES. It used to reject.
      const h = await boot(registry);

      // The healthy tenant is mounted and SERVING — the bad row is skipped, not fatal.
      expect(initialized).toEqual(["zzz-healthy"]);
      expect(bridge?.mounts.size()).toBe(1);
      const routed = await fetch(
        `${h.base}/connectors/webhooks/paste/zzz-healthy`,
        { method: "POST", body: "{}" },
      );
      expect(routed.status).toBe(200);

      // The bad one is not mounted, and its URL is the opaque 404 like any other
      // unmounted install.
      expect(
        (
          await fetch(`${h.base}/connectors/webhooks/paste/aaa-revoked`, {
            method: "POST",
            body: "{}",
          })
        ).status,
      ).toBe(404);

      // And the bridge is alive for everyone.
      expect((await fetch(`${h.base}/connectors/health`)).status).toBe(200);
    });

    it("a bridge whose ONLY install is broken still comes up and still answers /health", async () => {
      // The deploy's liveness probe must be able to tell "the process is fine, one
      // tenant's token is not" from "the process is dead".
      await upsertInstall(pool, cipher, {
        provider: "paste",
        installKey: "only-broken",
        workspaceId: WS_A,
        credentialRef: "revoked",
        chatToken: "bp_chat_ws_a",
      });

      const registry = createConnectorRegistry();
      registry.register({
        ...pasteConnector(),
        adapterFactory(): Adapter {
          throw new Error("AuthenticationError: 401 Unauthorized");
        },
      });

      const h = await boot(registry);

      expect(bridge?.mounts.size()).toBe(0);
      expect((await fetch(`${h.base}/connectors/health`)).status).toBe(200);

      // …and the connect loop still works, so the operator can fix it by re-pasting.
      const fixed = await h.post("/connectors/connect/validate", {
        ticket: ticketFor(WS_A),
        credential: GOOD_TOKEN,
      });
      expect(fixed.status).toBe(200);
    });

    // ── TOOL DIRECTION: CONNECT SEALS THE PAT, MOUNTS NOTHING (D69) ──────────
    //
    // The OTHER direction of the epic. A tool connect writes ONLY the provider
    // credential (a PAT), carries NO chat token, and NEVER mounts a Chat — the
    // agent reaches the tool through the MCP `tool-descriptors` seam, not through
    // this bridge. Two forms of "no chat token" reach the route: the field ABSENT,
    // and the field explicitly NULL. Both must land identically, and neither may
    // ever touch `adapterFactory` — the `onAdapter` spy is what makes that a fact
    // rather than an assertion on a field.

    it("TOOL connect with chat_token ABSENT: 200 mounted:false, PAT sealed, NO chat token, adapterFactory never called", async () => {
      const adapterCalls: ConnectorInstall[] = [];
      const h = await boot(
        registryWith(toolConnector({ onAdapter: (i) => adapterCalls.push(i) })),
      );

      const response = await h.post("/connectors/connect", {
        ticket: ticketFor(WS_A, TOOL_PROVIDER),
        credential: GOOD_TOKEN,
        // no chat_token key at all
      });

      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({
        ok: true,
        provider: TOOL_PROVIDER,
        install_key: GOOD_KEY,
        workspace_id: WS_A,
        mounted: false,
      });

      // The row: the PAT is sealed (present, not plaintext); the chat token stays
      // NULL — a tool install has nowhere to put one.
      const row = await toolRow(GOOD_KEY);
      expect(row?.workspace_id).toBe(WS_A);
      expect(row?.credential_ref).not.toBeNull();
      expect(row?.credential_ref).not.toContain(GOOD_TOKEN);
      expect(row?.chat_token_ref).toBeNull();

      // …and it OPENS to the pasted PAT, with NO chat token on the opened install.
      const install = await createInstallsLookup(pool, cipher).lookupInstall(
        TOOL_PROVIDER,
        GOOD_KEY,
      );
      expect(install?.credentialRef).toBe(GOOD_TOKEN);
      expect(install?.chatToken ?? null).toBeNull();

      // NOTHING was mounted, and adapterFactory was never invoked. This is the
      // whole point: a tool connect is a WRITE, not a bring-up.
      expect(adapterCalls).toHaveLength(0);
      expect(bridge?.mounts.size()).toBe(0);
    });

    it("TOOL connect with chat_token:null is byte-identical to absent — still 200 mounted:false, still no adapterFactory", async () => {
      const adapterCalls: ConnectorInstall[] = [];
      const h = await boot(
        registryWith(toolConnector({ onAdapter: (i) => adapterCalls.push(i) })),
      );

      const response = await h.post("/connectors/connect", {
        ticket: ticketFor(WS_A, TOOL_PROVIDER),
        credential: GOOD_TOKEN,
        chat_token: null,
      });

      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({
        ok: true,
        provider: TOOL_PROVIDER,
        install_key: GOOD_KEY,
        workspace_id: WS_A,
        mounted: false,
      });

      const row = await toolRow(GOOD_KEY);
      expect(row?.workspace_id).toBe(WS_A);
      expect(row?.credential_ref).not.toBeNull();
      expect(row?.chat_token_ref).toBeNull();

      expect(adapterCalls).toHaveLength(0);
      expect(bridge?.mounts.size()).toBe(0);
    });

    it("TOOL disconnect deletes the row cleanly — no adapterFactory, no mount teardown, unmount no-ops", async () => {
      const adapterCalls: ConnectorInstall[] = [];
      const h = await boot(
        registryWith(toolConnector({ onAdapter: (i) => adapterCalls.push(i) })),
      );

      // Connect first — a tool install exists, unmounted.
      const connected = await h.post("/connectors/connect", {
        ticket: ticketFor(WS_A, TOOL_PROVIDER),
        credential: GOOD_TOKEN,
      });
      expect(connected.status).toBe(200);
      expect(await toolRow(GOOD_KEY)).not.toBeNull();
      // Never mounted, so nothing to tear down.
      expect(bridge?.mounts.size()).toBe(0);

      const response = await h.post("/connectors/disconnect", {
        ticket: ticketFor(WS_A, TOOL_PROVIDER),
        install_key: GOOD_KEY,
      });

      expect(response.status).toBe(200);
      // `removed:true` — a real row was deleted — even though nothing was unmounted:
      // `unmountInstall` returns false for a never-mounted install, and the delete is
      // what makes the disconnect durable. The two are independent by design.
      expect(await response.json()).toMatchObject({ ok: true, removed: true });

      // The row is GONE — survives a restart, nothing for the next boot to re-read.
      expect(await toolRow(GOOD_KEY)).toBeNull();

      // Across the WHOLE lifecycle — connect and disconnect — the adapter was never
      // built and no Chat was ever mounted. A tool never rides the mount path.
      expect(adapterCalls).toHaveLength(0);
      expect(bridge?.mounts.size()).toBe(0);
    });
  },
);
