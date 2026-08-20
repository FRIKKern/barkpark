/**
 * D252 — the mountInstall slash-command funnel, RED-ON-REVERT tripwire.
 *
 * THE GAP THIS CLOSES (W28 survey, design-sanctioned — not a defect at the time):
 * mountInstall funnels a Discord slash interaction into the core loop as
 * `${event.command} ${event.text}`.trim()` (connectors/src/index.ts, the
 * onSlashCommand wrapper, D232). The vendor delivers `event.text === ""` for a
 * bare NO-OPTION command (/status), so event.text-only wiring would push "" and
 * core/dispatch.ts would drop it as `dropped_empty_input` BEFORE tenant
 * resolution — a silent no-op the user sees as "The application did not respond"
 * after the 15-min interaction-token TTL. The command-prefix funnel is what keeps
 * the verb. Until now that transform was mirrored in discord-slash-commands.test.ts's
 * HARNESS handler and kept in lockstep by a CODE COMMENT, not an automated check:
 * nothing went red if a future editor reverted mountInstall's funnel to
 * event.text-only. This file is that missing check.
 *
 * WHY A DRIVER TEST, NOT A SHARED SYMBOL (precedent: ack-first-indicator.test.ts's
 * mountRealInstall + its vacuous-green rationale): a shared-symbol unit test stays
 * GREEN if mountInstall reverts to event.text while the unused symbol survives —
 * it proves the symbol, not the wiring. The only honest proof is to exercise the
 * LITERAL production path: mount a REAL discord connector through the REAL exported
 * mountInstall, fire a REAL Ed25519-signed no-option slash interaction at
 * chat.webhooks.discord, and capture what the dispatch SEAM receives. dispatchInbound
 * is the seam mountInstall calls with the funnelled text as event.text, so mocking
 * it (vi.mock below) captures EXACTLY what the funnel produced — reverting the funnel
 * to event.text-only makes event.text "" here and reds this test (the mutation proof
 * recorded on the task). ZERO new production exports; this slice touches only this file.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { generateKeyPairSync, sign as edSign } from "node:crypto";
import { createMemoryState } from "@chat-adapter/state-memory";

import type { BridgeConfig } from "../src/config.js";
import { createConnectorRegistry } from "../src/connector/registry.js";
import type { ConnectorInstall, InboundEvent } from "../src/connector/types.js";
import {
  createDiscordConnector,
  DISCORD_PROVIDER,
} from "../src/connectors/discord.js";
import { dispatchInbound } from "../src/core/dispatch.js";
import { mountInstall, type BridgeDeps } from "../src/index.js";
import {
  createThreadSessionMap,
  type ThreadSessionStore,
} from "../src/state/thread-session-map.js";
import { createInMemoryInstallsLookup } from "../src/tenant/installs.js";

// THE SEAM (vi.mock is hoisted above the imports): dispatchInbound is the exact
// call mountInstall's onSlashCommand wrapper makes, with the funnelled text as
// event.text. Replacing it with a spy captures the funnel's output verbatim —
// reverting the funnel to event.text-only makes calls[0][0].text === "" and reds
// the assertions below. A no-op "posted" outcome keeps deps.onOutcome happy.
vi.mock("../src/core/dispatch.js", () => ({
  dispatchInbound: vi.fn(async () => ({ status: "posted" })),
}));

const dispatched = vi.mocked(dispatchInbound);

// ── Ed25519 test keypair (node:crypto, ZERO new dep) ────────────────────────
// The Discord adapter's verifyKey wants the RAW 32-byte public key, hex-encoded
// (the jwk.x route, mirroring discord-slash-commands.test.ts).
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const publicKeyHex = Buffer.from(
  publicKey.export({ format: "jwk" }).x as string,
  "base64url",
).toString("hex");

const APP_ID = "111111111111111111";

/** The BYO-bot credential triple Discord demands (D41), sealed as credential_ref. */
const install: ConnectorInstall = {
  provider: DISCORD_PROVIDER,
  installKey: APP_ID,
  workspaceId: "ws-alpha",
  credentialRef: JSON.stringify({
    applicationId: APP_ID,
    botToken: "test-bot-token",
    publicKey: publicKeyHex,
  }),
  chatToken: "test-token",
};

/** Discord signs the concatenation `timestamp + body`; Ed25519 sig, hex-encoded. */
function sign(timestamp: string, body: string): string {
  return edSign(null, Buffer.from(timestamp + body, "utf8"), privateKey).toString(
    "hex",
  );
}

/** A signed HTTP interactions request, exactly the shape the webhook seam takes. */
function signedRequest(body: string): Request {
  const timestamp = String(Math.floor(Date.now() / 1000));
  const headers = new Headers({ "content-type": "application/json" });
  headers.set("x-signature-ed25519", sign(timestamp, body));
  headers.set("x-signature-timestamp", timestamp);
  return new Request(`https://bridge.local/connectors/webhooks/discord/${APP_ID}`, {
    method: "POST",
    headers,
    body,
  });
}

/**
 * A NO-OPTION APPLICATION_COMMAND — the exact shape Discord sends for a
 * no-argument slash command: NO `options` key at all. The vendor delivers
 * event.text === "" for this, so only the command-prefix funnel survives dispatch.
 */
function noOptionSlashBody(name: string, token: string): string {
  return JSON.stringify({
    type: 2,
    id: "11",
    application_id: APP_ID,
    token,
    channel_id: "chan-9",
    guild_id: "guild-9",
    data: { id: `cmd-${name}`, name, type: 1 },
    member: { user: { id: "user-3", username: "carol", global_name: "Carol" } },
  });
}

/** An in-memory thread->session store: the map's logic, none of Postgres. */
function memoryStore(): ThreadSessionStore {
  const rows = new Map<string, string>();
  const key = (w: string, t: string) => JSON.stringify([w, t]);
  return {
    async get(workspaceId, threadId) {
      return rows.get(key(workspaceId, threadId)) ?? null;
    },
    async putIfAbsent(workspaceId, threadId, sessionUuid) {
      const k = key(workspaceId, threadId);
      const existing = rows.get(k);
      if (existing) return existing;
      rows.set(k, sessionUuid);
      return sessionUuid;
    },
  };
}

/**
 * Mount ONE discord install through the REAL mountInstall — the production wiring.
 * dispatchInbound is the mocked seam; chatClientForInstall THROWS to prove this
 * driver never reaches the turn loop (a call would mean the funnel captured the
 * wrong thing).
 */
function mountRealInstall() {
  const connector = createDiscordConnector();
  const registry = createConnectorRegistry();
  registry.register(connector);

  const config: BridgeConfig = {
    databaseUrl: "postgres://never-dialled.invalid/none",
    apiUrl: "http://127.0.0.1:1",
    credentialKey: "unused-by-mountInstall",
    previousCredentialKeys: [],
    userName: "barkpark",
    webhook: {
      enabled: false,
      host: "127.0.0.1",
      port: 0,
      pathPrefix: "/connectors",
      maxBodyBytes: 65_536,
    },
  };

  const deps: BridgeDeps = {
    config,
    registry,
    installs: createInMemoryInstallsLookup([install]),
    map: createThreadSessionMap(memoryStore()),
    state: createMemoryState(),
    chatClientForInstall: () => {
      throw new Error(
        "dispatch is mocked in this driver test — chatClientForInstall must not be reached",
      );
    },
  };

  const mounted = mountInstall(connector, install, deps);

  const fireWebhook = (
    request: Request,
    waitUntil: (p: Promise<unknown>) => void,
  ): Promise<Response> => {
    const handler = mounted.chat.webhooks[DISCORD_PROVIDER] as (
      r: Request,
      o: { waitUntil: (p: Promise<unknown>) => void },
    ) => Promise<Response>;
    return handler(request, { waitUntil });
  };

  return { mounted, fireWebhook };
}

async function waitFor(cond: () => boolean, ms = 2000): Promise<void> {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > ms) throw new Error("waitFor timed out");
    await new Promise((r) => setTimeout(r, 5));
  }
}

beforeEach(() => {
  dispatched.mockClear();
  // The interaction follow-up uses a bare global fetch (LAW 4) — stub it so a
  // stray post can never hit the network. With dispatch mocked, the reply closure
  // never fires, so this should stay uncalled; it is a safety net, not the proof.
  vi.stubGlobal(
    "fetch",
    async () =>
      new Response(JSON.stringify({ id: "resp-msg-id" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
  );
});

afterEach(async () => {
  vi.unstubAllGlobals();
});

describe("mountInstall slash funnel — driver test (D252 red-on-revert tripwire)", () => {
  it("a signed NO-OPTION /status funnels NON-EMPTY, command-prefixed text into the dispatch seam", async () => {
    const { fireWebhook } = mountRealInstall();

    const bg: Promise<unknown>[] = [];
    const res = await fireWebhook(
      signedRequest(noOptionSlashBody("status", "interaction-token-status")),
      (p) => bg.push(p),
    );

    // Synchronous deferred ack (type 5) — dispatch rides waitUntil.
    expect(res.status).toBe(200);
    expect(((await res.clone().json()) as { type: number }).type).toBe(5);

    await Promise.allSettled(bg);
    await waitFor(() => dispatched.mock.calls.length === 1);

    // THE FUNNEL, captured at the seam mountInstall calls. The vendor delivers
    // event.text === "" for a no-option command, so event.text-only wiring would
    // push "" here and core/dispatch.ts would drop it as dropped_empty_input. The
    // command-prefix funnel keeps the verb: NON-EMPTY "/status".
    const event = dispatched.mock.calls[0]![0] as InboundEvent;
    expect(event.provider).toBe(DISCORD_PROVIDER);
    expect(event.text).toBe("/status");
    expect(event.text).not.toBe("");
    expect(event.text.length).toBeGreaterThan(0);
    // Command-prefixed ("status" present, not the bare "" the empty-input trap drops).
    expect(event.text).toContain("status");
  });

  it("the driver reaches dispatch through mountInstall's OWN wrapper, never the turn loop", async () => {
    const { fireWebhook } = mountRealInstall();

    const bg: Promise<unknown>[] = [];
    await fireWebhook(
      signedRequest(noOptionSlashBody("status", "interaction-token-status-2")),
      (p) => bg.push(p),
    );
    await Promise.allSettled(bg);
    await waitFor(() => dispatched.mock.calls.length === 1);

    // dispatchInbound is the real production seam (mocked here); the threadId is
    // the vendor's namespaced channel id, passed VERBATIM through the funnel — a
    // second, independent witness that the REAL onSlashCommand wrapper ran (a
    // shared-symbol test could not observe this).
    const event = dispatched.mock.calls[0]![0] as InboundEvent;
    expect(event.threadId).toBe("discord:guild-9:chan-9");
    expect(event.installKey).toBe(APP_ID);
  });
});
