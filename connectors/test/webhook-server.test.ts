/**
 * Proofs for the inbound webhook seam (charter D39).
 *
 * Every assertion below is really asking ONE question: can workspace A's webhook
 * URL ever reach workspace B's Chat? The seam's answer is structural —
 * `mounts.handlerFor()` takes a `ConnectorInstall` ROW that only the fail-closed
 * `InstallsLookup` can produce — and these tests are the tripwire that keeps it
 * that way.
 *
 * PROTECTIVE PROOF (run it, do not trust it): re-key `createWebhookMountIndex`'s
 * map by `provider` instead of by `(provider, installKey)` — the naive design —
 * and these go RED, headlined by install A's URL reaching install B's Chat:
 *
 *   - "routes install A's URL to A's OWN Chat and never B's"
 *   - "routes install B's URL to B's OWN Chat and never A's"
 *   - "routes a payload-keyed (Slack) event by its team_id, to that team's Chat"
 *   - "an install mounted AFTER boot is routable without a restart"
 *   - "an unmounted install answers the same opaque 404 as an unknown one"
 *
 * The installs lookup here is the REAL `createInstallsLookup` over a stub
 * `Queryable`, not the in-memory double, and every stub row's `credential_ref` is
 * SEALED by the real cipher (D35/D37) — a fake that skipped that coercion would
 * prove nothing about production.
 *
 * NOTE on the half-row (a row with a workspace but NO credential): since D42 that
 * is a LEGITIMATE state, not a corrupt one — Teams serves every org from ONE
 * operator app and stores no per-workspace secret — so the lookup RETURNS it and
 * the fail-closed stop moves one step later: nothing ever mounted it, so
 * `handlerFor` yields undefined and the request gets the SAME opaque 404. The
 * observable behaviour is unchanged; the reason is not, and this comment is the
 * reason.
 *
 * The traversal test uses a RAW SOCKET on purpose. `fetch`/undici normalises dot
 * segments CLIENT-side, so a fetch-based traversal test passes against a server
 * that never even sees a `..` — a vacuous green.
 */
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { connect } from "node:net";
import type { Adapter } from "chat";
import pg from "pg";

import type { BridgeConfig } from "../src/config.js";
import {
  createConnectorRegistry,
  type ConnectorRegistry,
} from "../src/connector/registry.js";
import type {
  Connector,
  ConnectorInstall,
  ConnectorWebhook,
} from "../src/connector/types.js";
import { createCredentialCipher } from "../src/crypto/credential-cipher.js";
import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import {
  createWebhookMountIndex,
  type WebhookCapableChat,
  type WebhookHandler,
  type WebhookMountIndex,
} from "../src/http/mounts.js";
import {
  startWebhookServer,
  type WebhookServer,
} from "../src/http/webhook-server.js";
import { startBridge, type Bridge } from "../src/index.js";
import {
  createInstallsLookup,
  upsertInstall,
  type Queryable,
} from "../src/tenant/installs.js";

/** The real cipher — every sealed column in this suite goes through it (D35/D37). */
const CREDENTIAL_KEY = Buffer.alloc(32, 3).toString("base64");
const cipher = createCredentialCipher({ key: CREDENTIAL_KEY });

const WS_A = "11111111-1111-4111-8111-111111111111";
const WS_B = "22222222-2222-4222-8222-222222222222";

// ---------------------------------------------------------------------------
// The installs table, read through the REAL fail-closed lookup.
// ---------------------------------------------------------------------------

interface InstallRow {
  provider: string;
  install_key: string;
  workspace_id: string | null;
  credential_ref: string | null;
}

const PLAIN_ROWS: InstallRow[] = [
  // WhatsApp: keySource "path" — each workspace's Meta app points at its own URL.
  {
    provider: "whatsapp",
    install_key: "phone-a",
    workspace_id: WS_A,
    credential_ref: "secret-A",
  },
  {
    provider: "whatsapp",
    install_key: "phone-b",
    workspace_id: WS_B,
    credential_ref: "secret-B",
  },
  // Slack: keySource "payload" — ONE app-wide request_url, team_id in the body.
  {
    provider: "slack",
    install_key: "T_AAA",
    workspace_id: WS_A,
    credential_ref: "secret-A",
  },
  {
    provider: "slack",
    install_key: "T_BBB",
    workspace_id: WS_B,
    credential_ref: "secret-B",
  },
  // A real row that is deliberately NEVER mounted.
  {
    provider: "whatsapp",
    install_key: "phone-unmounted",
    workspace_id: WS_A,
    credential_ref: "secret-A",
  },
  // A HALF-ROW: a workspace, but no credential. Not a tenant we can serve — there
  // is no secret to verify the signature against, so it must fail closed.
  {
    provider: "whatsapp",
    install_key: "phone-halfrow",
    workspace_id: WS_B,
    credential_ref: null,
  },
];

/**
 * The same rows as they actually sit in Postgres: `credential_ref` SEALED against
 * that row's own identity (provider, install_key, workspace_id). Sealing them here
 * rather than storing plaintext is what makes this stub a faithful stand-in — the
 * production lookup OPENS the blob, and a plaintext stub would have exercised a
 * code path that does not exist.
 */
const ROWS: InstallRow[] = PLAIN_ROWS.map((row) => ({
  ...row,
  credential_ref:
    row.credential_ref === null
      ? null
      : cipher.seal(row.credential_ref, {
          provider: row.provider,
          installKey: row.install_key,
          workspaceId: row.workspace_id as string,
        }),
}));

/** A stub `Queryable` so the production SQL lookup runs without Postgres. */
const stubDb: Queryable = {
  async query<R extends object>(_text: string, values: unknown[] = []) {
    const [provider, installKey] = values as (string | undefined)[];
    const rows = ROWS.filter(
      (row) =>
        row.provider === provider &&
        (installKey === undefined || row.install_key === installKey),
    );
    return { rows: rows as unknown as R[] };
  },
};

const installs = createInstallsLookup(stubDb, cipher);

// ---------------------------------------------------------------------------
// Fake Chats. A `Chat` is a big object; the seam only ever touches `.webhooks`.
// ---------------------------------------------------------------------------

interface RecordedCall {
  /** WHICH Chat was invoked — the whole cross-tenant question in one field. */
  chat: string;
  method: string;
  url: string;
  bytes: Buffer;
  headers: Record<string, string>;
  waitUntilType: string;
}

let calls: RecordedCall[] = [];

type ChatBehaviour = (ctx: {
  request: Request;
  bytes: Buffer;
  options?: { waitUntil?: (task: Promise<unknown>) => void };
}) => Promise<Response>;

const okResponse: ChatBehaviour = async ({ request }) =>
  new Response(JSON.stringify({ ok: true, url: request.url }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });

function fakeChat(
  label: string,
  provider: string,
  behaviour: ChatBehaviour = okResponse,
): WebhookCapableChat {
  const handler: WebhookHandler = async (request, options) => {
    // ONE read of the body — exactly what the real adapter does. If the router
    // had already consumed the Request, this would throw "Body is unusable"
    // (which the Slack adapter reports as a misleading 401 "Invalid signature").
    const bytes = Buffer.from(await request.arrayBuffer());
    const headers: Record<string, string> = {};
    request.headers.forEach((value, name) => {
      headers[name] = value;
    });
    calls.push({
      chat: label,
      method: request.method,
      url: request.url,
      bytes,
      headers,
      waitUntilType: typeof options?.waitUntil,
    });
    return behaviour({ request, bytes, options });
  };
  return { webhooks: { [provider]: handler } };
}

// ---------------------------------------------------------------------------
// Connectors. A webhook channel is ONE registry entry + a `webhook` block.
// ---------------------------------------------------------------------------

function fakeConnector(id: string, webhook?: ConnectorWebhook): Connector {
  return {
    id,
    direction: "channel",
    auth: "signing-secret",
    tenantResolution:
      webhook?.keySource === "payload" ? "payload-team-id" : "credential-bound",
    adapterFactory: () => ({}) as Adapter,
    async resolveTenant() {
      return null;
    },
    webhook,
  };
}

const whatsappConnector = fakeConnector("whatsapp", { keySource: "path" });

const slackConnector = fakeConnector("slack", {
  keySource: "payload",
  // Handed the RAW bytes, exactly as they will be HMAC'd. Never a re-serialised parse.
  extractInstallKey(rawBody) {
    try {
      const parsed: unknown = JSON.parse(rawBody);
      const teamId = (parsed as { team_id?: unknown }).team_id;
      return typeof teamId === "string" ? teamId : null;
    } catch {
      return null;
    }
  },
  // The tenant-less handshake. Slack pings the request_url with
  // `{"type":"url_verification","challenge":…}` BEFORE any workspace has installed
  // the app, so it carries no team_id: `extractInstallKey` correctly returns null,
  // and without this hook the seam would 404 and the app could NEVER be configured.
  handleUnkeyed(rawBody) {
    try {
      const parsed = JSON.parse(rawBody) as {
        type?: unknown;
        challenge?: unknown;
      };
      if (parsed.type !== "url_verification") return null;
      if (typeof parsed.challenge !== "string") return null;
      return Response.json({ challenge: parsed.challenge });
    } catch {
      return null;
    }
  },
});

/** A poll-only channel (Telegram in polling mode): NO webhook block, so no HTTP
 * route. (Discord is NOT one of these since D228 — it carries a path-keyed webhook
 * for slash-command interactions alongside its Gateway socket.) */
const pollingConnector = fakeConnector("telegram");

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

interface Harness {
  base: string;
  port: number;
  mounts: WebhookMountIndex;
  registry: ConnectorRegistry;
  mountRow(
    provider: string,
    installKey: string,
    workspaceId: string,
    label: string,
    behaviour?: ChatBehaviour,
  ): void;
  close(): Promise<void>;
}

interface BootOptions {
  behaviour?: ChatBehaviour;
  pathPrefix?: string;
  publicBaseUrl?: string;
  maxBodyBytes?: number;
  /** Skip the default four mounts (dynamic-mount proofs start from empty). */
  mountNothing?: boolean;
}

let server: WebhookServer | undefined;

async function boot(options: BootOptions = {}): Promise<Harness> {
  const registry = createConnectorRegistry();
  registry.register(whatsappConnector);
  registry.register(slackConnector);
  registry.register(pollingConnector);

  const mounts = createWebhookMountIndex();
  const behaviour = options.behaviour ?? okResponse;

  const mountRow: Harness["mountRow"] = (
    provider,
    installKey,
    workspaceId,
    label,
    rowBehaviour = behaviour,
  ) => {
    const connector = registry.get(provider);
    if (!connector) throw new Error(`test bug: no connector "${provider}"`);
    mounts.mount({
      connector,
      install: {
        provider,
        installKey,
        workspaceId,
        credentialRef: `secret-${label}`,
      },
      chat: fakeChat(label, provider, rowBehaviour),
    });
  };

  if (!options.mountNothing) {
    mountRow("whatsapp", "phone-a", WS_A, "A");
    mountRow("whatsapp", "phone-b", WS_B, "B");
    mountRow("slack", "T_AAA", WS_A, "slack-A");
    mountRow("slack", "T_BBB", WS_B, "slack-B");
  }

  const started = await startWebhookServer({
    registry,
    installs,
    mounts,
    port: 0,
    host: "127.0.0.1",
    pathPrefix: options.pathPrefix,
    publicBaseUrl: options.publicBaseUrl,
    maxBodyBytes: options.maxBodyBytes,
  });
  server = started;

  return {
    base: `http://127.0.0.1:${started.port}`,
    port: started.port,
    mounts,
    registry,
    mountRow,
    close: () => started.close(),
  };
}

afterEach(async () => {
  await server?.close();
  server = undefined;
  calls = [];
});

/** Speak HTTP over a raw socket — the ONLY honest way to send bytes fetch would rewrite. */
function rawRequest(port: number, raw: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    const socket = connect({ host: "127.0.0.1", port }, () => {
      socket.write(raw);
    });
    socket.on("data", (chunk: Buffer) => chunks.push(chunk));
    socket.on("close", () => resolve(Buffer.concat(chunks).toString("utf8")));
    socket.on("error", reject);
    socket.setTimeout(5_000, () => {
      socket.destroy();
      reject(new Error("raw request timed out"));
    });
  });
}

interface Failure {
  status: number;
  body: string;
  contentType: string | null;
}

async function failureOf(response: Response): Promise<Failure> {
  return {
    status: response.status,
    body: await response.text(),
    contentType: response.headers.get("content-type"),
  };
}

// ---------------------------------------------------------------------------

describe("webhook seam — per-install routing", () => {
  it("routes install A's URL to A's OWN Chat and never B's", async () => {
    const h = await boot();

    const response = await fetch(`${h.base}/connectors/webhooks/whatsapp/phone-a`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: '{"entry":[]}',
    });

    expect(response.status).toBe(200);
    expect(calls.map((c) => c.chat)).toEqual(["A"]);
  });

  it("routes install B's URL to B's OWN Chat and never A's", async () => {
    const h = await boot();

    const response = await fetch(`${h.base}/connectors/webhooks/whatsapp/phone-b`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: '{"entry":[]}',
    });

    expect(response.status).toBe(200);
    expect(calls.map((c) => c.chat)).toEqual(["B"]);
  });

  it("routes a payload-keyed (Slack) event by its team_id, to that team's Chat", async () => {
    const h = await boot();
    const url = `${h.base}/connectors/webhooks/slack`; // app-wide URL: NO install key in the path

    const a = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: '{"team_id":"T_AAA","event":{"text":"hi"}}',
    });
    const b = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: '{"team_id":"T_BBB","event":{"text":"hi"}}',
    });

    expect([a.status, b.status]).toEqual([200, 200]);
    // The SAME URL served two tenants — and each event reached only its own Chat.
    expect(calls.map((c) => c.chat)).toEqual(["slack-A", "slack-B"]);
  });

  it("hands the handler off the INSTALL ROW: a workspace mismatch yields no handler", () => {
    const mounts = createWebhookMountIndex();
    const install: ConnectorInstall = {
      provider: "whatsapp",
      installKey: "phone-a",
      workspaceId: WS_A,
      credentialRef: "secret-A",
    };
    mounts.mount({
      connector: whatsappConnector,
      install,
      chat: fakeChat("A", "whatsapp"),
    });

    expect(mounts.handlerFor(install)).toBeTypeOf("function");
    // The same (provider, installKey) but claimed by another workspace: refuse.
    expect(mounts.handlerFor({ ...install, workspaceId: WS_B })).toBeUndefined();
  });

  it("refuses to mount a Chat built from the wrong connector", () => {
    const mounts = createWebhookMountIndex();
    expect(() =>
      mounts.mount({
        connector: slackConnector,
        install: {
          provider: "whatsapp",
          installKey: "phone-a",
          workspaceId: WS_A,
          credentialRef: "secret-A",
        },
        chat: fakeChat("A", "whatsapp"),
      }),
    ).toThrow(/cannot serve install of provider/);
  });
});

describe("webhook seam — fail-closed demux (one opaque 404)", () => {
  it("answers the SAME opaque 404 for unknown key / unmounted install / half-row / unknown provider / poll-only channel, and never invokes an adapter", async () => {
    const h = await boot();

    const failures = await Promise.all(
      [
        // Unknown install key.
        `${h.base}/connectors/webhooks/whatsapp/phone-nope`,
        // A REAL row, deliberately not mounted (an install-enumeration oracle
        // would answer differently here — that is exactly what we refuse).
        `${h.base}/connectors/webhooks/whatsapp/phone-unmounted`,
        // A half-row: workspace, but no credential.
        `${h.base}/connectors/webhooks/whatsapp/phone-halfrow`,
        // A provider that does not exist.
        `${h.base}/connectors/webhooks/nosuch/phone-a`,
        // A poll/socket channel: registered, but no webhook transport.
        `${h.base}/connectors/webhooks/telegram/bot-a`,
        // A path-keyed connector with no install key at all.
        `${h.base}/connectors/webhooks/whatsapp`,
        // A payload-keyed connector probed with a per-install path.
        `${h.base}/connectors/webhooks/slack/T_AAA`,
      ].map(async (url) =>
        failureOf(
          await fetch(url, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: '{"team_id":"T_AAA"}',
          }),
        ),
      ),
    );

    for (const failure of failures) {
      expect(failure.status).toBe(404);
      expect(failure.body).toBe('{"error":"not_found"}');
    }
    // Byte-identical, not merely "all 404": same body, same content-type.
    expect(new Set(failures.map((f) => JSON.stringify(f))).size).toBe(1);
    // And NOT ONE adapter was invoked.
    expect(calls).toEqual([]);
  });

  it("404s a Slack event whose team_id is absent, unknown, or unparseable", async () => {
    const h = await boot();
    const url = `${h.base}/connectors/webhooks/slack`;

    const bodies = ['{"event":{}}', '{"team_id":"T_ZZZ"}', "not json at all", ""];
    for (const body of bodies) {
      const response = await fetch(url, { method: "POST", body });
      expect(response.status).toBe(404);
      expect(await response.text()).toBe('{"error":"not_found"}');
    }
    expect(calls).toEqual([]);
  });

  it("404s a LITERAL dot-segment target sent over a raw socket (fetch would normalise it away)", async () => {
    const h = await boot();

    // fetch/undici rewrites `..` client-side, so this MUST go over a socket. The
    // literal bytes on the wire are what a hostile provider would send.
    const traversal = await rawRequest(
      h.port,
      "GET /connectors/webhooks/whatsapp/../phone-b HTTP/1.1\r\n" +
        `Host: 127.0.0.1:${h.port}\r\nConnection: close\r\n\r\n`,
    );
    expect(traversal.split("\r\n")[0]).toContain("404");
    expect(traversal).toContain('{"error":"not_found"}');

    // Percent-encoded dot segments are decoded FIRST, then rejected.
    const encoded = await rawRequest(
      h.port,
      "GET /connectors/webhooks/whatsapp/%2e%2e/phone-b HTTP/1.1\r\n" +
        `Host: 127.0.0.1:${h.port}\r\nConnection: close\r\n\r\n`,
    );
    expect(encoded.split("\r\n")[0]).toContain("404");

    expect(calls).toEqual([]);
  });

  it("405s a method outside the GET/POST allowlist, and says which are allowed", async () => {
    const h = await boot();

    const response = await fetch(`${h.base}/connectors/webhooks/whatsapp/phone-a`, {
      method: "PUT",
      body: "{}",
    });

    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("GET, POST");
    expect(calls).toEqual([]);
  });

  /**
   * THE /mcp PHANTOM (charter D34/D272). The bridge owns `/connectors` -> :4020 and
   * serves EXACTLY ONE first segment under its prefix that reaches a tenant:
   * `webhooks`. It NEVER serves `/mcp` — that path is the SEPARATE barkpark-mcp
   * :4010 Caddy route, a different upstream on a different port. `parseRoute` closes
   * this with `if (rest[0] !== "webhooks") return null;`, and every negative case
   * above happens to target a `webhooks/...` first segment, so that guard was
   * uncovered. These two cases exercise it directly: a non-`webhooks` first segment
   * is the same opaque 404 as any unknown route, and no adapter is ever reached.
   *
   * NON-VACUITY (D266): delete that guard from webhook-server.ts and the
   * two-segment case below RED-flips — `/connectors/mcp/slack` then parses as
   * provider=`slack` (rest[1]), routes a `team_id:"T_AAA"` body to the mounted
   * slack-A Chat, and answers 200 with a recorded call. The one-segment case stays
   * 404 either way (rest[1] is undefined), so it documents the boundary; the
   * two-segment case is what makes guard-removal fail.
   */
  it("404s a non-'webhooks' first segment (/connectors/mcp) — the bridge NEVER serves /mcp", async () => {
    const h = await boot();

    const response = await fetch(`${h.base}/connectors/mcp`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: '{"team_id":"T_AAA"}',
    });

    expect(response.status).toBe(404);
    expect(await response.text()).toBe('{"error":"not_found"}');
    expect(response.headers.get("content-type")).toBe(
      "application/json; charset=utf-8",
    );
    expect(calls).toEqual([]);
  });

  it("404s a two-segment /connectors/mcp/<real-provider> without ever routing to that provider (guard-removal tripwire)", async () => {
    const h = await boot();

    // `slack` is a REAL, mounted, payload-keyed provider and `T_AAA` a REAL install
    // (see PLAIN_ROWS + the default mounts). If `parseRoute`'s
    // `rest[0] !== "webhooks"` guard were removed, this target would parse as
    // provider=`slack` and this body would reach the slack-A Chat — so this is the
    // case that turns guard-removal RED, not a vacuous "no such provider" 404.
    const response = await fetch(`${h.base}/connectors/mcp/slack`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: '{"team_id":"T_AAA"}',
    });

    expect(response.status).toBe(404);
    expect(await response.text()).toBe('{"error":"not_found"}');
    // The load-bearing assertion: the mounted slack Chat was NEVER invoked.
    expect(calls).toEqual([]);
  });
});

describe("webhook seam — the provider's contract", () => {
  it("passes waitUntil, and returns the ack WITHOUT waiting for the turn", async () => {
    let turnFinished = false;
    let releaseTurn = (): void => {};
    const turn = new Promise<void>((resolve) => {
      releaseTurn = () => {
        turnFinished = true;
        resolve();
      };
    });

    const h = await boot({
      behaviour: async ({ options }) => {
        // This is what the SDK does: hand the whole turn to waitUntil and answer NOW.
        options?.waitUntil?.(turn);
        return new Response("", { status: 200 });
      },
    });

    const response = await fetch(`${h.base}/connectors/webhooks/whatsapp/phone-a`, {
      method: "POST",
      body: "{}",
    });

    expect(response.status).toBe(200);
    // The ack came back while the turn is STILL running. Without waitUntil the
    // response would block on the whole turn, Slack's 3s budget would expire,
    // Slack would retry, and the turn would run twice (breaking D12 post-once).
    expect(turnFinished).toBe(false);
    expect(calls[0]?.waitUntilType).toBe("function");

    releaseTurn();
    await turn;
    expect(turnFinished).toBe(true);
  });

  it("allows GET so WhatsApp's hub.challenge verification handshake can be answered", async () => {
    const h = await boot({
      behaviour: async ({ request }) => {
        const params = new URL(request.url).searchParams;
        // Exactly what the Meta handshake requires: echo hub.challenge verbatim.
        return params.get("hub.mode") === "subscribe"
          ? new Response(params.get("hub.challenge") ?? "", { status: 200 })
          : new Response("", { status: 403 });
      },
    });

    const response = await fetch(
      `${h.base}/connectors/webhooks/whatsapp/phone-a?hub.mode=subscribe&hub.challenge=CHAL-123&hub.verify_token=tok`,
      { method: "GET" },
    );

    expect(response.status).toBe(200);
    expect(await response.text()).toBe("CHAL-123");
    expect(calls[0]?.method).toBe("GET");
    // A GET carries no body — the adapter must not be handed a phantom one.
    expect(calls[0]?.bytes.byteLength).toBe(0);
  });

  it("hands the adapter the EXACT wire bytes on a single read, even after demuxing on the body", async () => {
    const h = await boot();

    // Unicode, a 4-byte emoji, a ZWJ sequence, and non-canonical JSON whitespace.
    // Slack HMACs THESE BYTES: a re-serialised parse (or a UTF-16 round-trip)
    // changes them and the signature check fails with an undebuggable 401.
    const body = Buffer.from(
      '{"team_id":"T_AAA",\n\t"text" :  "héllo 🐕‍🦺 ünïcode — ok"  }',
      "utf8",
    );

    const response = await fetch(`${h.base}/connectors/webhooks/slack`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
    });

    expect(response.status).toBe(200);
    const seen = calls[0]?.bytes;
    expect(seen).toBeDefined();
    // Byte-for-byte, not string-for-string.
    expect(seen && Buffer.compare(seen, body)).toBe(0);
    // The demux read the body to find `team_id` — and the adapter STILL got a
    // fresh, readable body. That is rule 4 (single-read) holding.
    expect(calls[0]?.chat).toBe("slack-A");
  });

  it("gives the adapter the PUBLIC https URL behind a plain-http proxy socket", async () => {
    const h = await boot({ publicBaseUrl: "https://bridge.barkpark.cloud" });

    await fetch(`${h.base}/connectors/webhooks/whatsapp/phone-a?x=1`, {
      method: "POST",
      body: "{}",
    });

    // Teams' Bot Framework JWT validates the audience against the PUBLIC url;
    // handing it `http://127.0.0.1:PORT/...` fails validation with a 401.
    expect(calls[0]?.url).toBe(
      "https://bridge.barkpark.cloud/connectors/webhooks/whatsapp/phone-a?x=1",
    );
  });

  it("owns the FULL path — Caddy does not strip the prefix", async () => {
    const h = await boot({ pathPrefix: "/bridge" });

    const mounted = await fetch(`${h.base}/bridge/webhooks/whatsapp/phone-a`, {
      method: "POST",
      body: "{}",
    });
    const stale = await fetch(`${h.base}/connectors/webhooks/whatsapp/phone-a`, {
      method: "POST",
      body: "{}",
    });

    expect(mounted.status).toBe(200);
    // The default prefix is NOT also served: a prefix mismatch is a silent 404
    // on every webhook, which is exactly why the value is configurable.
    expect(stale.status).toBe(404);
    expect(calls.map((c) => c.chat)).toEqual(["A"]);
  });
});

describe("webhook seam — liveness and the tenant-less handshake", () => {
  it("answers GET {prefix}/health with 200 and nothing a stranger could use", async () => {
    const h = await boot();

    const response = await fetch(`${h.base}/connectors/health`);
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ status: "ok" });

    // It is the deploy's liveness probe (`deploy/instance-deploy.sh` curls it after
    // `systemctl restart`), so it must NOT enumerate tenants: no install count, no
    // provider list, no version. And no adapter is ever touched.
    expect(calls).toEqual([]);
  });

  it("refuses a POST to /health — a health check is a GET", async () => {
    const h = await boot();
    const response = await fetch(`${h.base}/connectors/health`, {
      method: "POST",
      body: "{}",
    });
    expect(response.status).toBe(405);
    expect(calls).toEqual([]);
  });

  it("answers Slack's url_verification challenge with NO install and NO tenant", async () => {
    const h = await boot();

    // No workspace has installed the app yet — that is the whole point of the
    // handshake. Nothing is mounted, and the payload carries no team_id.
    const response = await fetch(`${h.base}/connectors/webhooks/slack`, {
      method: "POST",
      body: JSON.stringify({ type: "url_verification", challenge: "c-3po" }),
    });

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ challenge: "c-3po" });
    // …and it reached no adapter, no Chat, no credential. It cannot: it never had
    // an install row.
    expect(calls).toEqual([]);
  });

  it("still 404s an unkeyed body that is NOT a handshake (the hook cannot shadow real traffic)", async () => {
    const h = await boot();
    h.mountRow("slack", "T_AAA", WS_A, "A");

    // A body with no team_id and no handshake type: the hook returns null and we
    // fall through to the SAME opaque 404 as everything else.
    const response = await fetch(`${h.base}/connectors/webhooks/slack`, {
      method: "POST",
      body: JSON.stringify({ type: "event_callback", event: { text: "hi" } }),
    });
    expect(response.status).toBe(404);
    await expect(response.text()).resolves.toBe('{"error":"not_found"}');
    expect(calls).toEqual([]);
  });

  it("a connector with NO handleUnkeyed 404s an unkeyed body — absent hook leaks nothing", async () => {
    const h = await boot();
    // whatsapp is keySource "path": it has no handleUnkeyed and no payload key at
    // all, so an app-wide URL is simply not a route it serves.
    const response = await fetch(`${h.base}/connectors/webhooks/whatsapp`, {
      method: "POST",
      body: JSON.stringify({ type: "url_verification", challenge: "nope" }),
    });
    expect(response.status).toBe(404);
    expect(calls).toEqual([]);
  });
});

describe("webhook seam — hostile bodies and broken adapters", () => {
  it("rejects an over-cap DECLARED content-length with a 413 the provider actually receives", async () => {
    const h = await boot({ maxBodyBytes: 64 });

    const response = await fetch(`${h.base}/connectors/webhooks/whatsapp/phone-a`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: Buffer.alloc(4096, "x"),
    });

    // The response ARRIVED — no req.destroy(), so no UND_ERR_SOCKET and no
    // provider-side retry storm. (A fetch against a destroyed socket throws.)
    expect(response.status).toBe(413);
    expect(await response.text()).toBe('{"error":"payload_too_large"}');
    expect(calls).toEqual([]);
  });

  it("rejects an over-cap CHUNKED body (no content-length to check) while still draining it", async () => {
    const h = await boot({ maxBodyBytes: 64 });

    // Raw socket: chunked, so the cap can only be enforced mid-stream.
    const chunk = "x".repeat(256);
    const raw = await rawRequest(
      h.port,
      "POST /connectors/webhooks/whatsapp/phone-a HTTP/1.1\r\n" +
        `Host: 127.0.0.1:${h.port}\r\n` +
        "content-type: application/json\r\n" +
        "transfer-encoding: chunked\r\n" +
        "Connection: close\r\n\r\n" +
        `${chunk.length.toString(16)}\r\n${chunk}\r\n` +
        `${chunk.length.toString(16)}\r\n${chunk}\r\n` +
        "0\r\n\r\n",
    );

    expect(raw.split("\r\n")[0]).toContain("413");
    expect(raw).toContain('{"error":"payload_too_large"}');
    expect(calls).toEqual([]);
  });

  it("answers 500 opaquely when an adapter throws, leaks nothing, and keeps serving", async () => {
    let fail = true;
    const h = await boot({
      behaviour: async () => {
        if (fail) throw new Error("boom: bot-token=SECRET-LEAK");
        return new Response("{}", { status: 200 });
      },
    });

    const broken = await fetch(`${h.base}/connectors/webhooks/whatsapp/phone-a`, {
      method: "POST",
      body: "{}",
    });
    const body = await broken.text();

    expect(broken.status).toBe(500);
    expect(body).toBe('{"error":"internal_error"}');
    expect(body).not.toContain("boom");
    expect(body).not.toContain("SECRET-LEAK");

    // One bad install must not take the process — and every other tenant — down.
    fail = false;
    const recovered = await fetch(
      `${h.base}/connectors/webhooks/whatsapp/phone-b`,
      {
        method: "POST",
        body: "{}",
      },
    );
    expect(recovered.status).toBe(200);
  });
});

describe("webhook seam — dynamic mount/unmount (no restart)", () => {
  it("an install mounted AFTER boot is routable without a restart", async () => {
    const h = await boot({ mountNothing: true });
    const url = `${h.base}/connectors/webhooks/whatsapp/phone-a`;

    // Before the OAuth callback: the row exists, nothing is mounted -> opaque 404.
    const before = await fetch(url, { method: "POST", body: "{}" });
    expect(before.status).toBe(404);
    expect(calls).toEqual([]);

    // The OAuth callback: upsertInstall (the row) -> mount (the Chat).
    h.mountRow("whatsapp", "phone-a", WS_A, "A");

    const after = await fetch(url, { method: "POST", body: "{}" });
    expect(after.status).toBe(200);
    expect(calls.map((c) => c.chat)).toEqual(["A"]);
  });

  it("an unmounted install answers the same opaque 404 as an unknown one", async () => {
    const h = await boot();
    const url = `${h.base}/connectors/webhooks/whatsapp/phone-a`;

    expect((await fetch(url, { method: "POST", body: "{}" })).status).toBe(200);

    // Disconnect.
    expect(h.mounts.unmount("whatsapp", "phone-a")).toBe(true);

    const disconnected = await failureOf(
      await fetch(url, { method: "POST", body: "{}" }),
    );
    const unknown = await failureOf(
      await fetch(`${h.base}/connectors/webhooks/whatsapp/phone-nope`, {
        method: "POST",
        body: "{}",
      }),
    );

    expect(disconnected.status).toBe(404);
    // Byte-identical to an unknown install: a disconnected workspace is not
    // distinguishable from one that never existed.
    expect(disconnected).toEqual(unknown);
    // Only the FIRST (pre-unmount) call ever reached a Chat.
    expect(calls.map((c) => c.chat)).toEqual(["A"]);
  });
});

// ---------------------------------------------------------------------------
// The same promise, proven through the REAL bridge boot path against a REAL,
// ephemeral Postgres: a row written after boot becomes routable with no restart.
// ---------------------------------------------------------------------------

const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";
const TEST_DB = `connectors_webhook_test_${process.pid}_${Date.now()}`;

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
if (!reachable && !REQUIRE_DB) {
  console.warn(
    `\n[connectors] SKIPPING the bridge-boot webhook proof: no Postgres at ${ADMIN_URL}.\n` +
      `[connectors] Set CONNECTORS_REQUIRE_DB=1 to make that a hard failure.\n`,
  );
}

/** The smallest thing the SDK will accept as an adapter: it initializes, and it answers. */
function stubAdapter(label: string): Adapter {
  return {
    name: "stub",
    async initialize() {},
    async handleWebhook(request: Request): Promise<Response> {
      return new Response(JSON.stringify({ ok: true, label, url: request.url }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    },
  } as unknown as Adapter;
}

describe.skipIf(!reachable && !REQUIRE_DB)(
  "webhook seam — through startBridge (real Postgres)",
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
      await bridge?.shutdown();
      await pool?.end();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)`);
        await admin.end();
      }
    }, 30_000);

    it("boots with zero installs, then routes an install added by an OAuth callback — no restart", async () => {
      const registry = createConnectorRegistry();
      const connector: Connector = {
        ...fakeConnector("stub", { keySource: "path" }),
        adapterFactory: (install: ConnectorInstall) =>
          stubAdapter(install.installKey),
      };
      registry.register(connector);

      const config: BridgeConfig = {
        databaseUrl: urlForDatabase(ADMIN_URL, TEST_DB),
        // Never called: the webhook seam ends at the adapter, and this stub adapter
        // does not dispatch a turn. A bogus URL keeps that honest.
        apiUrl: "http://127.0.0.1:1",
        credentialKey: CREDENTIAL_KEY,
        previousCredentialKeys: [],
        userName: "barkpark",
        webhook: {
          enabled: true,
          host: "127.0.0.1",
          port: 0,
          pathPrefix: "/connectors",
          maxBodyBytes: 65_536,
        },
      };

      bridge = await startBridge(config, { registry });
      const port = bridge.webhookServer?.port;
      expect(port).toBeTypeOf("number");
      const base = `http://127.0.0.1:${port}`;
      const url = `${base}/connectors/webhooks/stub/inst-b`;

      // Boot found no installs: the listener is up, and the route 404s.
      expect(bridge.mounts.size()).toBe(0);
      expect((await fetch(url, { method: "POST", body: "{}" })).status).toBe(404);

      // The OAuth callback, in the two calls it will actually make.
      const install: ConnectorInstall = {
        provider: "stub",
        installKey: "inst-b",
        workspaceId: WS_B,
        credentialRef: "secret-B",
      };
      await upsertInstall(pool, cipher, install);
      await bridge.addInstall(install);

      const routed = await fetch(url, { method: "POST", body: "{}" });
      expect(routed.status).toBe(200);
      expect(await routed.json()).toMatchObject({ ok: true, label: "inst-b" });
      expect(bridge.mounts.size()).toBe(1);

      // Disconnect: unrouted immediately, opaquely.
      expect(await bridge.removeInstall("stub", "inst-b")).toBe(true);
      const gone = await fetch(url, { method: "POST", body: "{}" });
      expect(gone.status).toBe(404);
      expect(await gone.text()).toBe('{"error":"not_found"}');
    }, 30_000);
  },
);
