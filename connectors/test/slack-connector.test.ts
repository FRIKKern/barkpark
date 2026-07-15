import { createHmac } from "node:crypto";
import { createServer, type Server } from "node:http";
import { connect as netConnect, type AddressInfo } from "node:net";

import { createSlackAdapter, type SlackAdapter } from "@chat-adapter/slack";
import { Chat } from "chat";
import pg from "pg";
import type { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import type { ChatClient, ChatSession } from "../src/chat-client/types.js";
import { createConnectorRegistry } from "../src/connector/registry.js";
import type {
  AuthorizedInstall,
  ConnectorInstall,
  InstallsLookup,
} from "../src/connector/types.js";
import { dispatchInbound } from "../src/core/dispatch.js";
import {
  createSlackConnector,
  createSlackHandshakeResponder,
  createSlackInstallKeyExtractor,
  SLACK_PROVIDER,
  SLACK_WEBHOOK_PATH,
  slackInstallKey,
  slackInstallKeyFromMessage,
  type SlackConnector,
} from "../src/connectors/slack.js";
import { createCredentialCipher } from "../src/crypto/credential-cipher.js";
import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import {
  registerBuiltinConnectors,
  startBridge,
  type Bridge,
} from "../src/index.js";
import {
  buildSlackInstallUrl,
  handleSlackOAuthCallback,
  installKeyFromOAuth,
  SLACK_OAUTH_CALLBACK_PATH,
} from "../src/oauth/slack-oauth.js";
import { signConnectTicket, verifyConnectTicket } from "../src/connect/ticket.js";
import {
  consumePendingConnect,
  stagePendingConnect,
} from "../src/connect/pending-connect.js";
import { createWebhookMountIndex } from "../src/http/mounts.js";
import { startWebhookServer } from "../src/http/webhook-server.js";
import type { SlackOAuthCallbackDeps } from "../src/oauth/slack-oauth.js";
import { createBridgeState } from "../src/state/state-adapter.js";
import {
  createPgThreadSessionStore,
  createThreadSessionMap,
} from "../src/state/thread-session-map.js";
import {
  createInMemoryInstallsLookup,
  createInstallsLookup,
  upsertInstall,
} from "../src/tenant/installs.js";

/**
 * Slack, the `payload-team-id` channel — and the question every assertion below is
 * really asking: CAN TEAM A'S MESSAGE EVER BE ANSWERED WITH TEAM B'S BOT TOKEN?
 *
 * The headline finding this suite pins is a SILENT one. `@chat-adapter/slack`
 * guards socket mode against `clientId`/`clientSecret` but NOT against
 * `installationProvider` — so `mode:"socket" + installationProvider + botToken`
 * constructs happily and then serves every tenant the one static token, with
 * `getInstallation` never called. The same hole exists in WEBHOOK mode the moment
 * a static `botToken` is present, because `handleWebhook` only resolves a per-team
 * token when there is no default one:
 *
 *     if (!this.defaultBotTokenProvider && payload.type === "event_callback") { … }
 *
 * `slack.ts` is therefore built with NO botToken at all, and the protective test
 * below reintroduces one to prove the suite goes RED when it does.
 */

const WS_A = "11111111-1111-4111-8111-111111111111";
const WS_B = "22222222-2222-4222-8222-222222222222";

const TEAM_A = "T_AAAA";
const TEAM_B = "T_BBBB";
const ENTERPRISE = "E_GRID";

const TOKEN_A = "xoxb-team-a-token";
const TOKEN_B = "xoxb-team-b-token";
const TOKEN_GRID = "xoxb-grid-token";
const OPERATOR_TOKEN = "xoxb-OPERATOR-one-token-to-rule-them-all";

/**
 * The cipher that seals `credential_ref` / `chat_token_ref` (D35/D37). Every row
 * this suite writes goes through it, and every row it reads is opened by it — the
 * same path production takes, so a test that passes here means what it says.
 */
const CREDENTIAL_KEY = Buffer.alloc(32, 7).toString("base64");
const cipher = createCredentialCipher({ key: CREDENTIAL_KEY });

const SIGNING_SECRET = "app-wide-signing-secret";
const CLIENT_ID = "123.456";
const CLIENT_SECRET = "client-secret";
const STATE_SECRET = "bridge-state-hmac-secret";

/**
 * A fully-provisioned install carries BOTH secrets (D35): the SLACK bot token
 * (`credentialRef` — what the adapter replies with) and THIS workspace's Barkpark
 * `chat` ApiToken (`chatToken` — what its /v1/chat traffic authenticates with).
 * An install missing the second one is fail-closed dropped by dispatch with
 * `dropped_no_chat_token` before a single HTTP call, so a fixture without it would
 * prove nothing about Slack — it would only re-prove W4-1's drop.
 */
const installsTable: ConnectorInstall[] = [
  {
    provider: SLACK_PROVIDER,
    installKey: TEAM_A,
    workspaceId: WS_A,
    credentialRef: TOKEN_A,
    chatToken: "bp_chat_ws_a",
  },
  {
    provider: SLACK_PROVIDER,
    installKey: TEAM_B,
    workspaceId: WS_B,
    credentialRef: TOKEN_B,
    chatToken: "bp_chat_ws_b",
  },
  {
    // Enterprise Grid, org-wide: keyed by the ENTERPRISE id, never a team id.
    provider: SLACK_PROVIDER,
    installKey: ENTERPRISE,
    workspaceId: WS_B,
    credentialRef: TOKEN_GRID,
    chatToken: "bp_chat_ws_b",
  },
];

const installs: InstallsLookup = createInMemoryInstallsLookup(installsTable);

// ───────────────────────────────────────────────────────────────────────────────
// A fake Slack API. Every outbound call the adapter makes lands here, and we read
// the Authorization header off it — that bearer token IS the tenant isolation
// claim, so it is asserted at the wire, never inferred from config.
// ───────────────────────────────────────────────────────────────────────────────

interface SlackApiCall {
  method: string;
  token: string;
  body: Record<string, string>;
}

let slackApi: Server;
let slackApiUrl: string;
let calls: SlackApiCall[] = [];

function bearer(header: string | undefined, body: Record<string, string>): string {
  // @slack/web-api sends the token in the Authorization header for JSON bodies and
  // in the form body for form-encoded ones. Read both so the assertion cannot be
  // fooled by a transport detail.
  const fromHeader = header?.replace(/^Bearer\s+/i, "");
  return fromHeader ?? body["token"] ?? "";
}

beforeAll(async () => {
  slackApi = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      let body: Record<string, string> = {};
      try {
        body = raw.startsWith("{")
          ? (JSON.parse(raw) as Record<string, string>)
          : Object.fromEntries(new URLSearchParams(raw));
      } catch {
        body = {};
      }
      // Slack's Web API methods are the LAST path segment, dots and all:
      // `/api/chat.postMessage`. (Stripping the `chat.` prefix here once made the
      // post-filter below match nothing, so every drop-path assertion passed
      // vacuously. Keep the wire name.)
      const method = (req.url ?? "").split("?")[0]?.split("/").pop() ?? "";
      calls.push({
        method,
        token: bearer(req.headers["authorization"] as string | undefined, body),
        body,
      });

      res.writeHead(200, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          ok: true,
          ts: "1700000000.000100",
          channel: body["channel"] ?? "C1",
          user: { id: "U1", name: "human", real_name: "Human", profile: {} },
        }),
      );
    });
  });
  await new Promise<void>((resolve) => slackApi.listen(0, "127.0.0.1", resolve));
  const { port } = slackApi.address() as AddressInfo;
  slackApiUrl = `http://127.0.0.1:${port}/api/`;
});

afterAll(async () => {
  await new Promise<void>((resolve) => slackApi.close(() => resolve()));
});

// ───────────────────────────────────────────────────────────────────────────────
// Signed Slack webhook requests — the real thing, HMAC and all.
// ───────────────────────────────────────────────────────────────────────────────

function signedSlackRequest(
  envelope: Record<string, unknown>,
  options: { signingSecret?: string; timestamp?: number } = {},
): Request {
  const body = JSON.stringify(envelope);
  const ts = String(options.timestamp ?? Math.floor(Date.now() / 1000));
  const signature =
    "v0=" +
    createHmac("sha256", options.signingSecret ?? SIGNING_SECRET)
      .update(`v0:${ts}:${body}`)
      .digest("hex");

  return new Request("http://bridge.test/connectors/webhook/slack", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-slack-request-timestamp": ts,
      "x-slack-signature": signature,
    },
    body,
  });
}

let tsCounter = 0;

/**
 * An `app_mention` envelope, as Slack really sends it.
 *
 * Channel id and message `ts` default to per-team-unique values, which is what
 * Slack actually does — two workspaces never share a channel id. It also matters
 * mechanically: the Chat SDK's thread state is keyed by `channel:ts` with no
 * workspace in the key, and these tests share one `chat_bridge` database, so a
 * reused (channel, ts) makes the SECOND tenant's message look like a duplicate of
 * the first and it is silently dropped.
 */
function mentionEnvelope(options: {
  teamId?: string;
  enterpriseId?: string;
  isEnterpriseInstall?: boolean;
  text?: string;
  channel?: string;
  ts?: string;
  /** The inner event's `team` — the AUTHOR's team. Differs in a shared channel. */
  eventTeam?: string;
}): Record<string, unknown> {
  const event: Record<string, unknown> = {
    type: "app_mention",
    user: "U_HUMAN",
    text: options.text ?? "<@U_BOT> hello",
    channel: options.channel ?? `C_${options.teamId ?? "UNKNOWN"}`,
    ts: options.ts ?? `170000000${++tsCounter}.00000${tsCounter}`,
    channel_type: "channel",
  };
  if (options.eventTeam) event["team"] = options.eventTeam;

  return {
    type: "event_callback",
    team_id: options.teamId,
    ...(options.enterpriseId ? { enterprise_id: options.enterpriseId } : {}),
    ...(options.isEnterpriseInstall ? { is_enterprise_install: true } : {}),
    event_id: `Ev${Math.random().toString(36).slice(2)}`,
    event,
  };
}

/**
 * A per-workspace ChatClient double. The SESSION side of isolation: which
 * workspace's client was asked to mint the Session for this event.
 *
 * The SSE turn loop itself is proven in `turn-loop.test.ts`; the subject HERE is
 * which tenant the turn was attributed to and which bot token answered it, so the
 * turn is stubbed via `runTurnImpl`.
 */
function recordingChatClientFor(
  seen: string[],
): (install: AuthorizedInstall) => ChatClient {
  return (install: AuthorizedInstall) => {
    const workspaceId = install.workspaceId;
    seen.push(workspaceId);
    const session: ChatSession = {
      id: `sess-${workspaceId}`,
      title: null,
      status: "idle",
      mode: "chat",
      model: null,
      cwd: "/",
      message_count: 0,
    };
    return {
      async createSession() {
        return session;
      },
      async getSession() {
        return session;
      },
      async postMessage() {
        return { accepted: true };
      },
      async openEventStream() {
        return (async function* () {})();
      },
    } as unknown as ChatClient;
  };
}

/**
 * An in-memory stand-in for `pending_connect` (D63) for the callback unit tests
 * that run without Postgres. `stage`/`consume` mirror the real single-use join:
 * consuming a nonce removes it, so a replay yields null.
 */
function inMemoryPending() {
  const rows = new Map<string, { workspaceId: string; chatToken: string }>();
  return {
    stage(nonce: string, workspaceId: string, chatToken: string): void {
      rows.set(nonce, { workspaceId, chatToken });
    },
    consume: async (nonce: string) => {
      const row = rows.get(nonce);
      if (!row) return null;
      rows.delete(nonce);
      return row;
    },
    has: (nonce: string) => rows.has(nonce),
  };
}

/** No workspace owns any install key — the callback's incumbent check passes. */
const noIncumbent = async (): Promise<null> => null;

// ───────────────────────────────────────────────────────────────────────────────
// PART 1 — registration shape. Slack is ONE registry entry.
// ───────────────────────────────────────────────────────────────────────────────

function connector(
  overrides: Partial<Parameters<typeof createSlackConnector>[0]> = {},
): SlackConnector {
  return createSlackConnector({
    signingSecret: SIGNING_SECRET,
    clientId: CLIENT_ID,
    clientSecret: CLIENT_SECRET,
    installs,
    apiUrl: slackApiUrl,
    ...overrides,
  });
}

describe("slack connector — registration shape (zero core change)", () => {
  it("declares direction=channel, auth=oauth, tenantResolution=payload-team-id", () => {
    const slack = connector();
    expect(slack.id).toBe("slack");
    expect(slack.direction).toBe("channel");
    expect(slack.auth).toBe("oauth");
    // The OTHER strategy the core declared in P2. Telegram is credential-bound;
    // Slack proves both live on one loop.
    expect(slack.tenantResolution).toBe("payload-team-id");
  });

  it("registers as an ordinary channel connector alongside telegram", () => {
    const registry = createConnectorRegistry();
    registerBuiltinConnectors(registry, {
      installs,
      slack: {
        signingSecret: SIGNING_SECRET,
        clientId: CLIENT_ID,
        clientSecret: CLIENT_SECRET,
      },
    });

    // Every P3 channel is a peer here — Slack has no privileged position in the
    // registry, which is the whole claim. (iMessage is absent: it registers only
    // under CONNECTORS_PROFILE=self-hosted, D44.) `github` (D69) and `linear` (D77)
    // are present as the FIRST and SECOND tool connectors — the OTHER direction —
    // but neither is a channel, so both are excluded from `registry.channels()`.
    expect(registry.list().map((c) => c.id)).toEqual([
      "telegram",
      "slack",
      "discord",
      "teams",
      "whatsapp",
      "github",
      "linear",
    ]);
    expect(registry.channels().map((c) => c.id)).toContain("slack");
    expect(registry.channels().map((c) => c.id)).not.toContain("github");
    expect(registry.channels().map((c) => c.id)).not.toContain("linear");
  });

  it("is NOT registered when the app credentials are absent — no half-wired adapter", () => {
    const registry = createConnectorRegistry();
    registerBuiltinConnectors(registry, { installs });
    expect(registry.has("slack")).toBe(false);
  });

  it("leaves listen/stopListening undefined — a webhook's transport IS the request", () => {
    const slack = connector();
    expect(slack.listen).toBeUndefined();
    expect(slack.stopListening).toBeUndefined();
    // …and declares where its events arrive, for the webhook seam to mount.
    expect(slack.webhook.keySource).toBe("payload");
    // The seam owns the route; the connector only declares WHERE its key lives —
    // plus the one tenant-less hook that answers Slack's endpoint handshake.
    expect(typeof slack.webhook.extractInstallKey).toBe("function");
    expect(typeof slack.webhook.handleUnkeyed).toBe("function");
    expect(SLACK_WEBHOOK_PATH).toBe("/connectors/webhooks/slack");
  });

  it("refuses to construct without a signing secret", () => {
    expect(() =>
      createSlackConnector({
        signingSecret: "",
        clientId: CLIENT_ID,
        clientSecret: CLIENT_SECRET,
        installs,
      }),
    ).toThrow(/signingSecret is required/);
  });

  it("builds a real @chat-adapter/slack adapter in WEBHOOK mode, with no static bot token", () => {
    const adapter = connector().adapterFactory(
      installsTable[0] as ConnectorInstall,
    ) as SlackAdapter & { mode?: string };

    expect(typeof adapter.postMessage).toBe("function");
    expect(typeof adapter.handleWebhook).toBe("function");
    expect(adapter.mode).toBe("webhook");
  });
});

// ───────────────────────────────────────────────────────────────────────────────
// PART 2 — the SILENT socket-mode hole, pinned as a regression tripwire.
// ───────────────────────────────────────────────────────────────────────────────

describe("slack — socket mode is DISQUALIFIED, and its guard is incomplete", () => {
  it("guards socket mode against clientId/clientSecret", () => {
    expect(() =>
      createSlackAdapter({
        mode: "socket",
        appToken: "xapp-1-fake",
        clientId: CLIENT_ID,
        clientSecret: CLIENT_SECRET,
      }),
    ).toThrow(/not supported in socket mode/);
  });

  it("does NOT guard socket mode against installationProvider — it constructs, and would leak", () => {
    // THE FINDING. No throw. `getInstallation` would never be called
    // (routeSocketEvent calls processEventPayload directly, skipping the
    // resolveTokenForTeam wrap), and every tenant would reply with `botToken`.
    // Nothing in the SDK stops you. `slack.ts` is the thing that stops you: it
    // hard-codes mode:"webhook" and passes no botToken at all.
    expect(() =>
      createSlackAdapter({
        mode: "socket",
        appToken: "xapp-1-fake",
        botToken: OPERATOR_TOKEN,
        installationProvider: {
          getInstallation: async () => ({ botToken: TOKEN_A }),
        },
      }),
    ).not.toThrow();
  });
});

// ───────────────────────────────────────────────────────────────────────────────
// PART 3 — install-key derivation. ONE composer, and Enterprise Grid.
// ───────────────────────────────────────────────────────────────────────────────

describe("slack — install key = enterprise_id ?? team_id", () => {
  it("prefers the enterprise id (org-wide Grid install)", () => {
    expect(slackInstallKey({ enterpriseId: ENTERPRISE, teamId: TEAM_A })).toBe(
      ENTERPRISE,
    );
  });

  it("falls back to the team id for an ordinary install", () => {
    expect(slackInstallKey({ teamId: TEAM_A })).toBe(TEAM_A);
    expect(slackInstallKey({ enterpriseId: "  ", teamId: TEAM_A })).toBe(TEAM_A);
  });

  it("is null when neither is present — fail closed, never a default", () => {
    expect(slackInstallKey({})).toBeNull();
    expect(slackInstallKey({ teamId: "" })).toBeNull();
  });

  it("keys an OAuth install by enterprise ONLY when is_enterprise_install is true", () => {
    // A workspace-level install inside a Grid still sends `enterprise` — keying on
    // it would collapse every workspace of one Grid onto a single install row.
    expect(
      installKeyFromOAuth({
        ok: true,
        team: { id: TEAM_A },
        enterprise: { id: ENTERPRISE },
      }),
    ).toBe(TEAM_A);

    expect(
      installKeyFromOAuth({
        ok: true,
        is_enterprise_install: true,
        team: { id: TEAM_A },
        enterprise: { id: ENTERPRISE },
      }),
    ).toBe(ENTERPRISE);
  });
});

describe("slack — the webhook extractor (verify + parse, never hand-rolled)", () => {
  const extractRaw = createSlackInstallKeyExtractor(SIGNING_SECRET);
  // The seam hands the extractor the RAW BODY BYTES + headers (D39), not a
  // Request: the body is read exactly ONCE and the same bytes go to the adapter,
  // because Slack HMACs the raw bytes. These tests still build a signed Request
  // (it is the honest wire shape), so this unwraps it the way the seam does.
  const extract = async (request: Request): Promise<string | null> =>
    extractRaw(await request.text(), request.headers);

  it("extracts the team id from a correctly signed envelope", async () => {
    await expect(
      extract(signedSlackRequest(mentionEnvelope({ teamId: TEAM_A }))),
    ).resolves.toBe(TEAM_A);
  });

  it("extracts the ENTERPRISE id from an org-wide envelope", async () => {
    await expect(
      extract(
        signedSlackRequest(
          mentionEnvelope({
            teamId: TEAM_A,
            enterpriseId: ENTERPRISE,
            isEnterpriseInstall: true,
          }),
        ),
      ),
    ).resolves.toBe(ENTERPRISE);
  });

  it("returns null for a BAD SIGNATURE — a forged team_id buys nothing", async () => {
    await expect(
      extract(
        signedSlackRequest(mentionEnvelope({ teamId: TEAM_A }), {
          signingSecret: "wrong-secret",
        }),
      ),
    ).resolves.toBeNull();
  });

  it("returns null for a replayed (stale-timestamp) request", async () => {
    await expect(
      extract(
        signedSlackRequest(mentionEnvelope({ teamId: TEAM_A }), {
          timestamp: Math.floor(Date.now() / 1000) - 60 * 60,
        }),
      ),
    ).resolves.toBeNull();
  });

  it("returns null (never throws) on a garbage body", async () => {
    const body = "not json at all";
    const ts = String(Math.floor(Date.now() / 1000));
    const signature =
      "v0=" +
      createHmac("sha256", SIGNING_SECRET).update(`v0:${ts}:${body}`).digest("hex");
    const request = new Request("http://bridge.test/connectors/webhook/slack", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-slack-request-timestamp": ts,
        "x-slack-signature": signature,
      },
      body,
    });

    await expect(extract(request)).resolves.toBeNull();
  });

  it("answers Slack's url_verification handshake — the ONE request with no tenant", async () => {
    // Slack POSTs this the moment you set the Events request_url, BEFORE any
    // workspace has installed the app: it carries no team_id at all. The extractor
    // correctly finds no install key, and `handleUnkeyed` is what keeps the app
    // configurable. Without it the endpoint could never be verified and Slack
    // could never be installed by anyone.
    const respond = createSlackHandshakeResponder(SIGNING_SECRET);
    const envelope = { type: "url_verification", challenge: "3eZbrw1aB" };
    const request = signedSlackRequest(envelope);
    const raw = await request.text();

    await expect(extractRaw(raw, request.headers)).resolves.toBeNull();

    const response = await respond(raw, request.headers);
    expect(response?.status).toBe(200);
    await expect(response?.json()).resolves.toEqual({ challenge: "3eZbrw1aB" });
  });

  it("refuses an UNSIGNED handshake — the app-wide secret still gates it", async () => {
    const respond = createSlackHandshakeResponder(SIGNING_SECRET);
    const envelope = { type: "url_verification", challenge: "forged" };
    const request = signedSlackRequest(envelope, { signingSecret: "wrong-secret" });
    const raw = await request.text();

    // Null => the seam falls through to its opaque 404. A stranger cannot even
    // confirm that a Slack connector is mounted here.
    await expect(respond(raw, request.headers)).resolves.toBeNull();
  });

  it("returns null for a NON-handshake body, so the hook can never shadow real traffic", async () => {
    const respond = createSlackHandshakeResponder(SIGNING_SECRET);
    const request = signedSlackRequest(mentionEnvelope({ teamId: TEAM_A }));
    const raw = await request.text();

    await expect(respond(raw, request.headers)).resolves.toBeNull();
  });

  it("reads the RAW BYTES, so the adapter still gets the exact wire body", async () => {
    // The seam reads the body ONCE and hands the same bytes to both the extractor
    // and the adapter (D39 rule 4) — the extractor never sees a Request, so it can
    // never consume one out from under `handleWebhook`. Slack HMACs the raw bytes,
    // so "the exact bytes" is not a nicety: a re-serialised body 401s.
    const envelope = mentionEnvelope({ teamId: TEAM_A });
    const request = signedSlackRequest(envelope);
    const raw = await request.text();

    await expect(extractRaw(raw, request.headers)).resolves.toBe(TEAM_A);
    // Same bytes still in hand, byte for byte, for the adapter's own verification.
    expect(raw).toBe(JSON.stringify(envelope));
  });
});

describe("slack — the payload fallback reads team_id, NEVER the author's team", () => {
  it("reads the envelope-stamped team_id off a Chat SDK Message", () => {
    expect(slackInstallKeyFromMessage({ raw: { team_id: TEAM_A } })).toBe(TEAM_A);
  });

  it("IGNORES `team` — in a Slack Connect shared channel that is the AUTHOR's org", () => {
    // If this ever returns TEAM_B, an external collaborator posting into TEAM_A's
    // channel would open a Session in TEAM_B's workspace. That is the leak.
    expect(slackInstallKeyFromMessage({ raw: { team: TEAM_B } })).toBeNull();
  });

  it("is null for a payload with no team at all", () => {
    expect(slackInstallKeyFromMessage(undefined)).toBeNull();
    expect(slackInstallKeyFromMessage({ raw: {} })).toBeNull();
  });
});

describe("slack — tenant resolution is fail-closed", () => {
  const slack = connector();
  const ctx = { installs };

  it("resolves the workspace from the transport (envelope-derived) key", async () => {
    await expect(
      slack.resolveTenant(
        { provider: SLACK_PROVIDER, threadId: "t", text: "hi", installKey: TEAM_A },
        ctx,
      ),
    ).resolves.toBe(WS_A);
  });

  it("resolves an ORG-WIDE install by its enterprise key", async () => {
    await expect(
      slack.resolveTenant(
        {
          provider: SLACK_PROVIDER,
          threadId: "t",
          text: "hi",
          installKey: ENTERPRISE,
        },
        ctx,
      ),
    ).resolves.toBe(WS_B);
  });

  it("falls back to the payload team id when the transport set no key", async () => {
    await expect(
      slack.resolveTenant(
        {
          provider: SLACK_PROVIDER,
          threadId: "t",
          text: "hi",
          payload: { raw: { team_id: TEAM_B } },
        },
        ctx,
      ),
    ).resolves.toBe(WS_B);
  });

  it("returns null for a team nobody installed — never a default workspace", async () => {
    await expect(
      slack.resolveTenant(
        {
          provider: SLACK_PROVIDER,
          threadId: "t",
          text: "hi",
          installKey: "T_STRANGER",
          payload: { raw: { team_id: "T_STRANGER" } },
        },
        ctx,
      ),
    ).resolves.toBeNull();
  });

  it("returns null when neither the transport nor the payload names a team", async () => {
    await expect(
      slack.resolveTenant(
        { provider: SLACK_PROVIDER, threadId: "t", text: "hi", payload: {} },
        ctx,
      ),
    ).resolves.toBeNull();
  });
});

// ───────────────────────────────────────────────────────────────────────────────
// PART 4 — THE ACCEPTANCE PROOF. Two tenants, one bridge, real adapters, real
// signed webhooks, and the bearer token read off the wire.
// ───────────────────────────────────────────────────────────────────────────────

const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";
const SLACK_TEST_DB = `connectors_slack_test_${process.pid}_${Date.now()}`;

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

const pgReachable = await postgresReachable();

describe.skipIf(!pgReachable && !REQUIRE_DB)(
  "slack — per-tenant token selection, end to end through a REAL adapter",
  () => {
    let admin: pg.Client;
    let pool: Pool;
    let dbUrl: string;

    beforeAll(async () => {
      if (!pgReachable && REQUIRE_DB) {
        throw new Error(
          `CONNECTORS_REQUIRE_DB=1 but no Postgres reachable at ${ADMIN_URL}`,
        );
      }
      admin = new pg.Client({ connectionString: ADMIN_URL });
      await admin.connect();
      await admin.query(`CREATE DATABASE ${SLACK_TEST_DB}`);

      const url = new URL(ADMIN_URL);
      url.pathname = `/${SLACK_TEST_DB}`;
      dbUrl = url.toString();

      pool = createBridgePool({ connectionString: dbUrl });
      await ensureBridgeSchema(pool);
      for (const install of installsTable) {
        await upsertInstall(pool, cipher, install);
      }
    }, 30_000);

    afterAll(async () => {
      await pool?.end();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${SLACK_TEST_DB} WITH (FORCE)`);
        await admin.end();
      }
    });

    /**
     * Mount ONE install exactly as `startBridge` does — real SlackAdapter, real
     * Chat, real state-pg — and drive a signed webhook through it.
     *
     * `staticBotToken` exists solely for the PROTECTIVE test: it is the one
     * mistake that makes the SDK skip per-team resolution, and the suite must go
     * red when it is made.
     */
    async function driveWebhook(
      install: ConnectorInstall,
      request: Request,
      options: { staticBotToken?: string } = {},
    ): Promise<{ workspaces: string[]; posts: SlackApiCall[] }> {
      const lookup = createInstallsLookup(pool, cipher);
      const slack = createSlackConnector({
        signingSecret: SIGNING_SECRET,
        clientId: CLIENT_ID,
        clientSecret: CLIENT_SECRET,
        installs: lookup,
        apiUrl: slackApiUrl,
      });

      // THE PRODUCTION ADAPTER — built by the connector's own factory, from the
      // install row, exactly as `mountInstall` builds it.
      let adapter = slack.adapterFactory(install) as SlackAdapter;
      if (options.staticBotToken) {
        // THE MISTAKE, made deliberately: a static botToken sets
        // `defaultBotTokenProvider`, and `handleWebhook` then never calls
        // `resolveTokenForTeam` — the installationProvider below is dead code.
        adapter = createSlackAdapter({
          mode: "webhook",
          signingSecret: SIGNING_SECRET,
          clientId: CLIENT_ID,
          clientSecret: CLIENT_SECRET,
          apiUrl: slackApiUrl,
          botToken: options.staticBotToken,
          installationProvider: {
            getInstallation: async () => ({ botToken: TOKEN_A }),
          },
        }) as SlackAdapter;
      }

      const workspaces: string[] = [];
      const state = createBridgeState(pool);
      const map = createThreadSessionMap(createPgThreadSessionStore(pool));
      const registry = createConnectorRegistry();
      registry.register(slack);

      const chat = new Chat({
        userName: "barkpark",
        adapters: { [SLACK_PROVIDER]: adapter },
        state,
      });

      // The SAME three handlers `mountInstall` wires, over the SAME dispatchInbound.
      // Inlined only so the sabotaged adapter can be substituted for the protective
      // test; the wiring is otherwise identical to production.
      const handle = async (
        threadId: string,
        text: string,
        reply: (out: string) => Promise<unknown>,
        payload?: unknown,
      ) => {
        await dispatchInbound(
          {
            provider: SLACK_PROVIDER,
            threadId,
            text,
            installKey: install.installKey,
            payload,
          },
          {
            registry,
            installs: { installs: lookup },
            map,
            chatClientForInstall: recordingChatClientFor(workspaces),
            reply: async (out) => {
              await reply(out);
            },
            runTurnImpl: async () => ({
              text: "pong",
              chatFrames: 1,
              completed: true,
            }),
          },
        );
      };

      chat.onDirectMessage(async (thread, message) => {
        await thread.subscribe();
        await handle(thread.id, message.text, (out) => thread.post(out), message);
      });
      chat.onNewMention(async (thread, message) => {
        await thread.subscribe();
        await handle(thread.id, message.text, (out) => thread.post(out), message);
      });
      chat.onSubscribedMessage(async (thread, message) => {
        await handle(thread.id, message.text, (out) => thread.post(out), message);
      });

      await chat.initialize();

      calls = [];
      const background: Promise<unknown>[] = [];
      const response = await adapter.handleWebhook(request, {
        waitUntil: (p: Promise<unknown>) => background.push(p),
      });
      // Slack ALWAYS gets its ack — even for a team we refuse to serve. A non-200
      // makes Slack retry the same undeliverable event for hours.
      expect(response.status).toBe(200);
      await Promise.all(background);
      // The post itself lands after the ack; give the background turn a beat.
      await new Promise((resolve) => setTimeout(resolve, 250));

      await chat.shutdown();

      return {
        workspaces,
        posts: calls.filter((c) => c.method === "chat.postMessage"),
      };
    }

    it("team A's event is answered with A's token; team B's with B's", async () => {
      const a = await driveWebhook(
        installsTable[0] as ConnectorInstall,
        signedSlackRequest(
          mentionEnvelope({ teamId: TEAM_A, text: "<@U_BOT> hi" }),
        ),
      );
      const b = await driveWebhook(
        installsTable[1] as ConnectorInstall,
        signedSlackRequest(
          mentionEnvelope({ teamId: TEAM_B, text: "<@U_BOT> hi" }),
        ),
      );

      // THE CLAIM, at the wire: the bearer token on chat.postMessage.
      expect(a.posts.map((p) => p.token)).toEqual([TOKEN_A]);
      expect(b.posts.map((p) => p.token)).toEqual([TOKEN_B]);

      // Neither tenant's token ever appears on the other's call.
      expect(a.posts.some((p) => p.token === TOKEN_B)).toBe(false);
      expect(b.posts.some((p) => p.token === TOKEN_A)).toBe(false);

      // …and the SESSION side: each turn was attributed to its own workspace, so
      // the Session it resumes is that tenant's and nobody else's.
      expect(a.workspaces).toEqual([WS_A]);
      expect(b.workspaces).toEqual([WS_B]);
    }, 30_000);

    it("PROTECTIVE: swapping installationProvider for a static botToken makes BOTH tenants reply with the operator token", async () => {
      const a = await driveWebhook(
        installsTable[0] as ConnectorInstall,
        signedSlackRequest(
          mentionEnvelope({ teamId: TEAM_A, text: "<@U_BOT> hi" }),
        ),
        { staticBotToken: OPERATOR_TOKEN },
      );
      const b = await driveWebhook(
        installsTable[1] as ConnectorInstall,
        signedSlackRequest(
          mentionEnvelope({ teamId: TEAM_B, text: "<@U_BOT> hi" }),
        ),
        { staticBotToken: OPERATOR_TOKEN },
      );

      // This is what the bug LOOKS like: green everywhere, one token everywhere.
      // Asserted explicitly so the per-tenant test above cannot pass vacuously —
      // if the production connector ever grows a static botToken, that test goes
      // red on exactly these values.
      expect(a.posts.map((p) => p.token)).toEqual([OPERATOR_TOKEN]);
      expect(b.posts.map((p) => p.token)).toEqual([OPERATOR_TOKEN]);
      expect(a.posts[0]?.token).toBe(b.posts[0]?.token);
      // …and getInstallation was never consulted: it would have returned TOKEN_A.
      expect(b.posts.some((p) => p.token === TOKEN_B)).toBe(false);
    }, 30_000);

    it("an ORG-WIDE Grid event resolves by enterprise_id and uses the grid token", async () => {
      const grid = await driveWebhook(
        installsTable[2] as ConnectorInstall,
        signedSlackRequest(
          mentionEnvelope({
            teamId: TEAM_A,
            enterpriseId: ENTERPRISE,
            isEnterpriseInstall: true,
            text: "<@U_BOT> hi",
          }),
        ),
      );

      // Keyed by ENTERPRISE, not TEAM_A — the team id would have missed entirely.
      expect(grid.posts.map((p) => p.token)).toEqual([TOKEN_GRID]);
    }, 30_000);

    it("an UNKNOWN team is dropped: no token, no post, and still a 200 ack", async () => {
      const stranger = await driveWebhook(
        installsTable[0] as ConnectorInstall,
        signedSlackRequest(
          mentionEnvelope({ teamId: "T_STRANGER", text: "<@U_BOT> hi" }),
        ),
      );

      // getInstallation returned null -> processEventPayload NEVER ran. Slack still
      // gets its 200 (asserted inside driveWebhook) so it does not retry forever.
      // No post, no token issued, and the core loop was never even entered — so no
      // Session was minted for a tenant we cannot identify.
      expect(stranger.posts).toEqual([]);
      expect(stranger.workspaces).toEqual([]);
    }, 30_000);

    it("a MIS-ROUTED event (B's envelope into A's mounted adapter) is dropped, not answered", async () => {
      // The installationProvider is scoped to ONE install, so even a router bug
      // cannot make A's adapter serve B. Isolation is a property of the adapter,
      // not of the router's correctness.
      const misrouted = await driveWebhook(
        installsTable[0] as ConnectorInstall,
        signedSlackRequest(
          mentionEnvelope({ teamId: TEAM_B, text: "<@U_BOT> hi" }),
        ),
      );

      expect(misrouted.posts).toEqual([]);
      expect(misrouted.workspaces).toEqual([]);
    }, 30_000);
  },
);

// ───────────────────────────────────────────────────────────────────────────────
// PART 5 — Add-to-Slack OAuth: signed state, sealed install, dynamic mount.
// ───────────────────────────────────────────────────────────────────────────────

describe("slack oauth — the workspace binding is a signed connect ticket (D65)", () => {
  const verifySlack = (state: string | null) =>
    verifyConnectTicket(state, STATE_SECRET, { provider: SLACK_PROVIDER });

  it("round-trips the workspace through a signed connect ticket carrying p:'slack'", () => {
    const state = signConnectTicket(WS_A, SLACK_PROVIDER, STATE_SECRET);
    expect(verifySlack(state).workspaceId).toBe(WS_A);
    expect(verifySlack(state).provider).toBe(SLACK_PROVIDER);
  });

  it("rejects a state this bridge's peer did not mint — the tenant-assignment hole, closed", () => {
    // The attack an unsigned state allows: hand the callback a state naming the
    // VICTIM's workspace, and your Slack team mounts inside it.
    const forged = Buffer.from(
      JSON.stringify({ w: WS_B, p: SLACK_PROVIDER, n: "x", t: Date.now() }),
    )
      .toString("base64url")
      .concat(".", Buffer.from("not-a-signature").toString("base64url"));

    expect(() => verifySlack(forged)).toThrow(/bad signature/);
  });

  it("rejects a state signed with a different secret", () => {
    const state = signConnectTicket(WS_A, SLACK_PROVIDER, "some-other-secret");
    expect(() => verifySlack(state)).toThrow(/bad signature/);
  });

  it("rejects a ticket minted for another provider used on the slack callback", () => {
    // A valid ticket for telegram must not authorise a Slack install — the
    // provider is on the wire precisely so a body/route cannot re-aim it.
    const state = signConnectTicket(WS_A, "telegram", STATE_SECRET);
    expect(() => verifySlack(state)).toThrow(/provider mismatch/);
  });

  it("expires a stale state", () => {
    const state = signConnectTicket(WS_A, SLACK_PROVIDER, STATE_SECRET, {
      now: () => Date.now() - 60 * 60 * 1000,
    });
    expect(() => verifySlack(state)).toThrow(/expired/);
  });

  it("refuses to mint an unsigned ticket at all", () => {
    expect(() => signConnectTicket(WS_A, SLACK_PROVIDER, "")).toThrow(
      /secret is required/,
    );
  });

  it("puts the signed ticket, the scopes and the redirect into the Add-to-Slack URL", () => {
    const url = new URL(
      buildSlackInstallUrl({
        clientId: CLIENT_ID,
        redirectUri: `https://bridge.test${SLACK_OAUTH_CALLBACK_PATH}`,
        workspaceId: WS_A,
        stateSecret: STATE_SECRET,
      }),
    );

    expect(url.origin + url.pathname).toBe("https://slack.com/oauth/v2/authorize");
    expect(url.searchParams.get("client_id")).toBe(CLIENT_ID);
    expect(url.searchParams.get("scope")).toContain("chat:write");
    const ticket = verifySlack(url.searchParams.get("state"));
    expect(ticket.workspaceId).toBe(WS_A);
    expect(ticket.provider).toBe(SLACK_PROVIDER);
    // The nonce is present — that is what the pending-connect join keys on (D63).
    expect(ticket.nonce).not.toBe("");
  });
});

describe("slack oauth — the callback installs, seals and mounts", () => {
  const redirectUri = `https://bridge.test${SLACK_OAUTH_CALLBACK_PATH}`;

  function callbackRequest(params: Record<string, string>): Request {
    const url = new URL(`https://bridge.test${SLACK_OAUTH_CALLBACK_PATH}`);
    for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
    return new Request(url, { method: "GET" });
  }

  function oauthFetch(
    response: Record<string, unknown>,
    seen: { body?: URLSearchParams } = {},
  ): typeof fetch {
    return (async (_input: unknown, init?: RequestInit) => {
      seen.body = new URLSearchParams(String(init?.body ?? ""));
      return new Response(JSON.stringify(response), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as unknown as typeof fetch;
  }

  const NONCE_A = "nonce-callback-a";
  const NONCE_B = "nonce-callback-b";

  it("joins the pending row and upserts a SEALED install with BOTH secrets, then mounts it live (D63)", async () => {
    const upserted: ConnectorInstall[] = [];
    const mountedNow: ConnectorInstall[] = [];
    const seen: { body?: URLSearchParams } = {};

    const pending = inMemoryPending();
    pending.stage(NONCE_A, WS_A, "bp_chat_ws_a");

    const result = await handleSlackOAuthCallback(
      callbackRequest({
        code: "one-time-code",
        state: signConnectTicket(WS_A, SLACK_PROVIDER, STATE_SECRET, {
          nonce: NONCE_A,
        }),
      }),
      {
        clientId: CLIENT_ID,
        clientSecret: CLIENT_SECRET,
        redirectUri,
        stateSecret: STATE_SECRET,
        consumePendingConnect: pending.consume,
        resolveWorkspace: noIncumbent,
        upsertInstall: async (i) => void upserted.push(i),
        mountInstall: async (i) => void mountedNow.push(i),
        sealCredential: (token) => `sealed:${token}`,
        fetch: oauthFetch(
          {
            ok: true,
            access_token: TOKEN_A,
            bot_user_id: "U_BOT",
            team: { id: TEAM_A, name: "Acme" },
          },
          seen,
        ),
        oauthAccessUrl: "https://slack.com/api/oauth.v2.access",
      },
    );

    expect(result).toMatchObject({
      status: 200,
      installed: true,
      installKey: TEAM_A,
      workspaceId: WS_A,
      teamName: "Acme",
    });

    // The row: keyed by team, owned by the state's workspace, BOTH secrets present
    // — credential SEALED, chat token the plaintext joined from the pending row.
    expect(upserted).toEqual([
      {
        provider: SLACK_PROVIDER,
        installKey: TEAM_A,
        workspaceId: WS_A,
        credentialRef: `sealed:${TOKEN_A}`,
        chatToken: "bp_chat_ws_a",
      },
    ]);
    // Live without a restart — the same row, straight into the running bridge.
    expect(mountedNow).toEqual(upserted);
    // Single-use: the pending row is gone.
    expect(pending.has(NONCE_A)).toBe(false);

    // The client secret went in the BODY, never the query string.
    expect(seen.body?.get("client_secret")).toBe(CLIENT_SECRET);
    expect(seen.body?.get("code")).toBe("one-time-code");
  });

  it("keys an ORG-WIDE install by enterprise_id", async () => {
    const upserted: ConnectorInstall[] = [];
    const pending = inMemoryPending();
    pending.stage(NONCE_B, WS_B, "bp_chat_ws_b");

    await handleSlackOAuthCallback(
      callbackRequest({
        code: "c",
        state: signConnectTicket(WS_B, SLACK_PROVIDER, STATE_SECRET, {
          nonce: NONCE_B,
        }),
      }),
      {
        clientId: CLIENT_ID,
        clientSecret: CLIENT_SECRET,
        redirectUri,
        stateSecret: STATE_SECRET,
        consumePendingConnect: pending.consume,
        resolveWorkspace: noIncumbent,
        upsertInstall: async (i) => void upserted.push(i),
        mountInstall: async () => undefined,
        fetch: oauthFetch({
          ok: true,
          access_token: TOKEN_GRID,
          is_enterprise_install: true,
          team: { id: TEAM_A },
          enterprise: { id: ENTERPRISE, name: "Grid" },
        }),
      },
    );

    expect(upserted[0]?.installKey).toBe(ENTERPRISE);
  });

  it("installs NOTHING when the state is forged — and never spends the code", async () => {
    const upserted: ConnectorInstall[] = [];
    const pending = inMemoryPending();
    let exchanged = false;

    const result = await handleSlackOAuthCallback(
      callbackRequest({ code: "c", state: "forged.state" }),
      {
        clientId: CLIENT_ID,
        clientSecret: CLIENT_SECRET,
        redirectUri,
        stateSecret: STATE_SECRET,
        consumePendingConnect: pending.consume,
        resolveWorkspace: noIncumbent,
        upsertInstall: async (i) => void upserted.push(i),
        mountInstall: async () => undefined,
        fetch: (async () => {
          exchanged = true;
          return new Response("{}", { status: 200 });
        }) as unknown as typeof fetch,
      },
    );

    expect(result.status).toBe(400);
    expect(result.installed).toBe(false);
    expect(upserted).toEqual([]);
    // The code is never even spent — the state is checked FIRST.
    expect(exchanged).toBe(false);
  });

  it("installs NOTHING when Slack refuses the exchange", async () => {
    const upserted: ConnectorInstall[] = [];
    const pending = inMemoryPending();
    pending.stage("nonce-refused", WS_A, "bp_chat_ws_a");

    const result = await handleSlackOAuthCallback(
      callbackRequest({
        code: "bad",
        state: signConnectTicket(WS_A, SLACK_PROVIDER, STATE_SECRET, {
          nonce: "nonce-refused",
        }),
      }),
      {
        clientId: CLIENT_ID,
        clientSecret: CLIENT_SECRET,
        redirectUri,
        stateSecret: STATE_SECRET,
        consumePendingConnect: pending.consume,
        resolveWorkspace: noIncumbent,
        upsertInstall: async (i) => void upserted.push(i),
        mountInstall: async () => undefined,
        fetch: oauthFetch({ ok: false, error: "invalid_code" }),
      },
    );

    expect(result.status).toBe(400);
    expect(result.error).toContain("invalid_code");
    expect(upserted).toEqual([]);
    // The exchange failed BEFORE the pending row was consumed — the operator can
    // retry from Studio without the staged token being burned.
    expect(pending.has("nonce-refused")).toBe(true);
  });

  it("installs NOTHING when the user cancels", async () => {
    const upserted: ConnectorInstall[] = [];
    const pending = inMemoryPending();

    const result = await handleSlackOAuthCallback(
      callbackRequest({ error: "access_denied" }),
      {
        clientId: CLIENT_ID,
        clientSecret: CLIENT_SECRET,
        redirectUri,
        stateSecret: STATE_SECRET,
        consumePendingConnect: pending.consume,
        resolveWorkspace: noIncumbent,
        upsertInstall: async (i) => void upserted.push(i),
        mountInstall: async () => undefined,
      },
    );

    expect(result.status).toBe(400);
    expect(result.installed).toBe(false);
    expect(upserted).toEqual([]);
  });

  it("fails closed when there is NO pending row — the bridge cannot mint a chat token (D48/D63)", async () => {
    const upserted: ConnectorInstall[] = [];
    const pending = inMemoryPending(); // nothing staged

    const result = await handleSlackOAuthCallback(
      callbackRequest({
        code: "c",
        state: signConnectTicket(WS_A, SLACK_PROVIDER, STATE_SECRET, {
          nonce: "nonce-missing",
        }),
      }),
      {
        clientId: CLIENT_ID,
        clientSecret: CLIENT_SECRET,
        redirectUri,
        stateSecret: STATE_SECRET,
        consumePendingConnect: pending.consume,
        resolveWorkspace: noIncumbent,
        upsertInstall: async (i) => void upserted.push(i),
        mountInstall: async () => undefined,
        fetch: oauthFetch({
          ok: true,
          access_token: TOKEN_A,
          team: { id: TEAM_A, name: "Acme" },
        }),
      },
    );

    expect(result.status).toBe(400);
    expect(result.installed).toBe(false);
    expect(upserted).toEqual([]);
  });

  it("refuses a Slack team another workspace owns — 409, install nothing (D64)", async () => {
    const upserted: ConnectorInstall[] = [];
    const pending = inMemoryPending();
    pending.stage("nonce-owned", WS_B, "bp_chat_ws_b");

    const result = await handleSlackOAuthCallback(
      callbackRequest({
        code: "c",
        state: signConnectTicket(WS_B, SLACK_PROVIDER, STATE_SECRET, {
          nonce: "nonce-owned",
        }),
      }),
      {
        clientId: CLIENT_ID,
        clientSecret: CLIENT_SECRET,
        redirectUri,
        stateSecret: STATE_SECRET,
        consumePendingConnect: pending.consume,
        // WS_A already owns TEAM_A — a re-auth from WS_B must be refused.
        resolveWorkspace: async () => WS_A,
        upsertInstall: async (i) => void upserted.push(i),
        mountInstall: async () => undefined,
        fetch: oauthFetch({
          ok: true,
          access_token: TOKEN_A,
          team: { id: TEAM_A, name: "Acme" },
        }),
      },
    );

    expect(result.status).toBe(409);
    expect(result.installed).toBe(false);
    expect(result.error).toContain("install_owned_elsewhere");
    expect(upserted).toEqual([]);
    // The check runs BEFORE the join, so the attacker's staged token is not spent.
    expect(pending.has("nonce-owned")).toBe(true);
  });
});

// ───────────────────────────────────────────────────────────────────────────────
// PART 6 — the dynamic mount, against the REAL bridge.
// ───────────────────────────────────────────────────────────────────────────────

describe.skipIf(!pgReachable && !REQUIRE_DB)(
  "slack oauth — a new install goes live in a RUNNING bridge, no restart",
  () => {
    let admin: pg.Client;
    let bridge: Bridge;
    let dbUrl: string;
    const MOUNT_DB = `connectors_slack_mount_${process.pid}_${Date.now()}`;

    beforeAll(async () => {
      if (!pgReachable && REQUIRE_DB) {
        throw new Error(
          `CONNECTORS_REQUIRE_DB=1 but no Postgres reachable at ${ADMIN_URL}`,
        );
      }
      admin = new pg.Client({ connectionString: ADMIN_URL });
      await admin.connect();
      await admin.query(`CREATE DATABASE ${MOUNT_DB}`);
      const url = new URL(ADMIN_URL);
      url.pathname = `/${MOUNT_DB}`;
      dbUrl = url.toString();

      process.env["SLACK_SIGNING_SECRET"] = SIGNING_SECRET;
      process.env["SLACK_CLIENT_ID"] = CLIENT_ID;
      process.env["SLACK_CLIENT_SECRET"] = CLIENT_SECRET;

      bridge = await startBridge({
        databaseUrl: dbUrl,
        apiUrl: "http://127.0.0.1:1/unused",
        credentialKey: CREDENTIAL_KEY,
        previousCredentialKeys: [],
        userName: "barkpark",
        // This suite drives the connector directly; no inbound listener wanted.
        webhook: {
          enabled: false,
          host: "127.0.0.1",
          port: 0,
          pathPrefix: "/connectors",
          maxBodyBytes: 1_048_576,
        },
      });
    }, 30_000);

    afterAll(async () => {
      await bridge?.shutdown();
      delete process.env["SLACK_SIGNING_SECRET"];
      delete process.env["SLACK_CLIENT_ID"];
      delete process.env["SLACK_CLIENT_SECRET"];
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${MOUNT_DB} WITH (FORCE)`);
        await admin.end();
      }
    });

    it("boots with slack registered and ZERO installs mounted", () => {
      expect(bridge.registry.has(SLACK_PROVIDER)).toBe(true);
      expect(bridge.mounted).toEqual([]);
    });

    it("the OAuth callback writes the row AND mounts it into the live bridge", async () => {
      const pool = bridge.pool;
      const NONCE = "nonce-live-mount";

      // Studio stages the workspace-bound chat token over loopback first (D63).
      await stagePendingConnect(pool, cipher, {
        nonce: NONCE,
        workspaceId: WS_A,
        provider: SLACK_PROVIDER,
        chatToken: "bp_chat_ws_a_live",
      });

      const lookup = createInstallsLookup(pool, cipher);
      const result = await handleSlackOAuthCallback(
        new Request(
          `https://bridge.test${SLACK_OAUTH_CALLBACK_PATH}?code=c&state=${encodeURIComponent(
            signConnectTicket(WS_A, SLACK_PROVIDER, STATE_SECRET, { nonce: NONCE }),
          )}`,
        ),
        {
          clientId: CLIENT_ID,
          clientSecret: CLIENT_SECRET,
          redirectUri: `https://bridge.test${SLACK_OAUTH_CALLBACK_PATH}`,
          stateSecret: STATE_SECRET,
          consumePendingConnect: (nonce) =>
            consumePendingConnect(pool, cipher, nonce),
          resolveWorkspace: (provider, installKey) =>
            lookup.resolveWorkspace(provider, installKey),
          upsertInstall: (install) => upsertInstall(pool, cipher, install),
          mountInstall: (install) => bridge.mount(install),
          fetch: (async () =>
            new Response(
              JSON.stringify({
                ok: true,
                access_token: TOKEN_A,
                team: { id: TEAM_A, name: "Acme" },
              }),
              { status: 200, headers: { "content-type": "application/json" } },
            )) as unknown as typeof fetch,
        },
      );

      expect(result.installed).toBe(true);

      // LIVE: the running bridge is now serving a team it had never heard of at boot.
      expect(bridge.mounted.map((m) => m.install.installKey)).toEqual([TEAM_A]);
      expect(bridge.mounted[0]?.install.workspaceId).toBe(WS_A);
      expect(bridge.mounted[0]?.connector.id).toBe(SLACK_PROVIDER);

      // …and it is durable: the row is really in connector_installs — and SEALED.
      const { rows } = await pool.query<{
        workspace_id: string;
        credential_ref: string;
      }>(
        `SELECT workspace_id, credential_ref FROM chat_bridge.connector_installs
          WHERE provider = $1 AND install_key = $2`,
        [SLACK_PROVIDER, TEAM_A],
      );
      expect(rows[0]?.workspace_id).toBe(WS_A);
      // The column must NOT hold the bot token in the clear (D35/D37) — asserting
      // `credential_ref === TOKEN_A` would have passed on a bridge that stored
      // every tenant's Slack token in plaintext, which is what we just stopped
      // doing. The real claim is: it is a sealed blob, and it opens to TOKEN_A for
      // THIS row's identity and no other.
      const sealed = rows[0]?.credential_ref as string;
      expect(sealed).not.toContain(TOKEN_A);
      expect(
        cipher.open(sealed, {
          provider: SLACK_PROVIDER,
          installKey: TEAM_A,
          workspaceId: WS_A,
        }),
      ).toBe(TOKEN_A);
      // …and refuses to open for another tenant's identity.
      expect(
        cipher.opens(sealed, {
          provider: SLACK_PROVIDER,
          installKey: TEAM_A,
          workspaceId: WS_B,
        }),
      ).toBe(false);
    }, 30_000);

    it("a re-install REPLACES the mount instead of stacking a second listener", async () => {
      await bridge.mount({
        provider: SLACK_PROVIDER,
        installKey: TEAM_A,
        workspaceId: WS_A,
        credentialRef: "xoxb-rotated",
      });

      // One install, one adapter. Two adapters on the same install with different
      // credentials is how a rotated token keeps answering with the old one.
      expect(
        bridge.mounted.filter((m) => m.install.installKey === TEAM_A),
      ).toHaveLength(1);
      expect(bridge.mounted[0]?.install.credentialRef).toBe("xoxb-rotated");
    }, 30_000);

    it("refuses to mount an install whose provider nobody registered", async () => {
      await expect(
        bridge.mount({
          provider: "nobody",
          installKey: "x",
          workspaceId: WS_A,
          credentialRef: "y",
        }),
      ).rejects.toThrow(/no connector registered/);
    });
  },
);

// ───────────────────────────────────────────────────────────────────────────────
// PART 7 — THE MOUNT. The OAuth callback is a real, reachable route (D62): GET,
// state-authenticated, and NEVER loopback-gated — proven over a raw socket, the
// only honest way to send the bytes fetch would rewrite.
// ───────────────────────────────────────────────────────────────────────────────

describe("slack oauth — the callback route is MOUNTED, public, and traversal-safe (D62)", () => {
  const REDIRECT =
    "https://guerrilla.barkpark.cloud/connectors/oauth/slack/callback";

  function oauthDeps(
    overrides: Partial<SlackOAuthCallbackDeps> = {},
  ): SlackOAuthCallbackDeps {
    const pending = inMemoryPending();
    return {
      clientId: CLIENT_ID,
      clientSecret: CLIENT_SECRET,
      redirectUri: REDIRECT,
      stateSecret: STATE_SECRET,
      consumePendingConnect: pending.consume,
      resolveWorkspace: noIncumbent,
      upsertInstall: async () => undefined,
      mountInstall: async () => undefined,
      ...overrides,
    };
  }

  async function bootServer(slackOAuth?: SlackOAuthCallbackDeps) {
    const registry = createConnectorRegistry();
    const server = await startWebhookServer({
      registry,
      installs: createInMemoryInstallsLookup([]),
      mounts: createWebhookMountIndex(),
      port: 0,
      host: "127.0.0.1",
      pathPrefix: "/connectors",
      publicBaseUrl: "https://guerrilla.barkpark.cloud",
      ...(slackOAuth ? { slackOAuth } : {}),
    });
    return server;
  }

  /** Speak HTTP over a raw socket — the ONLY way to send bytes fetch would rewrite. */
  function rawRequest(port: number, raw: string): Promise<string> {
    return new Promise((resolve, reject) => {
      const chunks: Buffer[] = [];
      const socket = netConnect({ host: "127.0.0.1", port }, () =>
        socket.write(raw),
      );
      socket.on("data", (c: Buffer) => chunks.push(c));
      socket.on("close", () => resolve(Buffer.concat(chunks).toString("utf8")));
      socket.on("error", reject);
      socket.setTimeout(5_000, () => {
        socket.destroy();
        reject(new Error("raw request timed out"));
      });
    });
  }

  it("is REACHED (not the opaque 404) with x-forwarded-* present — it is NOT loopback-gated", async () => {
    const server = await bootServer(oauthDeps());
    try {
      // A browser redirect through Caddy ALWAYS carries x-forwarded-*. The connect
      // routes 404 on those; this route must NOT — it authenticates by state.
      // `error=access_denied` makes the handler answer without any exchange, so a
      // 400 HTML page (not the JSON 404) PROVES the handler ran.
      const raw = await rawRequest(
        server.port,
        "GET /connectors/oauth/slack/callback?error=access_denied HTTP/1.1\r\n" +
          `Host: 127.0.0.1:${server.port}\r\n` +
          "X-Forwarded-For: 203.0.113.7\r\n" +
          "X-Forwarded-Host: guerrilla.barkpark.cloud\r\n" +
          "X-Forwarded-Proto: https\r\n" +
          "Connection: close\r\n\r\n",
      );
      expect(raw.split("\r\n")[0]).toContain("400");
      expect(raw).toContain("text/html");
      // The handler ran — this is its page, not the seam's opaque JSON 404.
      expect(raw).toContain("Could not connect Slack");
      expect(raw).not.toContain('{"error":"not_found"}');
    } finally {
      await server.close();
    }
  });

  it("answers the opaque 404 when the OAuth deps are absent (unconfigured box)", async () => {
    const server = await bootServer(undefined);
    try {
      const raw = await rawRequest(
        server.port,
        "GET /connectors/oauth/slack/callback?error=access_denied HTTP/1.1\r\n" +
          `Host: 127.0.0.1:${server.port}\r\nConnection: close\r\n\r\n`,
      );
      expect(raw.split("\r\n")[0]).toContain("404");
      expect(raw).toContain('{"error":"not_found"}');
    } finally {
      await server.close();
    }
  });

  it("404s a POST to the callback — a browser redirect is a GET", async () => {
    const server = await bootServer(oauthDeps());
    try {
      const raw = await rawRequest(
        server.port,
        "POST /connectors/oauth/slack/callback HTTP/1.1\r\n" +
          `Host: 127.0.0.1:${server.port}\r\n` +
          "content-length: 0\r\nConnection: close\r\n\r\n",
      );
      expect(raw.split("\r\n")[0]).toContain("404");
      expect(raw).toContain('{"error":"not_found"}');
    } finally {
      await server.close();
    }
  });

  it("404s a LITERAL dot-segment traversal at the callback path (raw socket)", async () => {
    const server = await bootServer(oauthDeps());
    try {
      const raw = await rawRequest(
        server.port,
        "GET /connectors/oauth/slack/../slack/callback?error=x HTTP/1.1\r\n" +
          `Host: 127.0.0.1:${server.port}\r\nConnection: close\r\n\r\n`,
      );
      expect(raw.split("\r\n")[0]).toContain("404");
      expect(raw).toContain('{"error":"not_found"}');
    } finally {
      await server.close();
    }
  });

  it("drives a REAL install end to end through the mounted route (GET, state-authenticated)", async () => {
    const pending = inMemoryPending();
    const NONCE = "nonce-route-e2e";
    pending.stage(NONCE, WS_A, "bp_chat_route_e2e");
    const upserted: ConnectorInstall[] = [];

    const server = await bootServer(
      oauthDeps({
        consumePendingConnect: pending.consume,
        upsertInstall: async (i) => void upserted.push(i),
        fetch: (async () =>
          new Response(
            JSON.stringify({
              ok: true,
              access_token: TOKEN_A,
              team: { id: TEAM_A, name: "Acme" },
            }),
            { status: 200, headers: { "content-type": "application/json" } },
          )) as unknown as typeof fetch,
      }),
    );
    try {
      const state = signConnectTicket(WS_A, SLACK_PROVIDER, STATE_SECRET, {
        nonce: NONCE,
      });
      const raw = await rawRequest(
        server.port,
        `GET /connectors/oauth/slack/callback?code=c&state=${encodeURIComponent(state)} HTTP/1.1\r\n` +
          `Host: 127.0.0.1:${server.port}\r\n` +
          "X-Forwarded-Host: guerrilla.barkpark.cloud\r\n" +
          "X-Forwarded-Proto: https\r\n" +
          "Connection: close\r\n\r\n",
      );
      expect(raw.split("\r\n")[0]).toContain("200");
      expect(raw).toContain("Connected to Slack");
      expect(upserted).toHaveLength(1);
      expect(upserted[0]?.installKey).toBe(TEAM_A);
      expect(upserted[0]?.workspaceId).toBe(WS_A);
      expect(upserted[0]?.chatToken).toBe("bp_chat_route_e2e");
    } finally {
      await server.close();
    }
  });
});
