/**
 * WhatsApp smoke — the runnable half of an HONEST human gate (charter D43).
 *
 * STATUS: **the live WhatsApp round-trip is NOT PASSED.** It needs a verified Meta
 * Business, a WABA phone number, and (to message anyone outside a ~5-recipient test
 * allowlist) App Review for Advanced Access. None of that can be scripted.
 *
 * What this script DOES prove, with no Meta account and no phone number at all — it runs
 * this self-check on every invocation, gate or no gate:
 *
 *   - the GET verification handshake: matching verifyToken -> 200 with the challenge
 *     echoed verbatim; a WRONG token -> 403;
 *   - a POST with a bad HMAC -> 401 (the App Secret gate);
 *   - the 24-hour window policy: outside it, a free-form send is REFUSED — never
 *     silently upgraded to a template.
 *
 * With the gate cleared it starts a real webhook listener so a real WhatsApp message
 * goes: Meta -> this endpoint -> tenant routing -> /v1/chat -> ONE reply.
 *
 * The listener is SMOKE-ONLY (production inbound HTTP is the bridge's webhook seam).
 *
 * Full runbook: docs/ops/whatsapp-meta.md
 */
import { createServer, type IncomingMessage } from "node:http";

import { createChatClient } from "../src/chat-client/client.js";
import { createConnectorRegistry } from "../src/connector/registry.js";
import type { ConnectorInstall } from "../src/connector/types.js";
import {
  createWhatsappConnector,
  encodeWhatsappCredential,
  whatsappInboundTimestampMs,
  whatsappPayloadMatchesInstall,
  WHATSAPP_PROVIDER,
} from "../src/connectors/whatsapp.js";
import { loadWebhookConfig } from "../src/config.js";
import { createCredentialCipher } from "../src/crypto/credential-cipher.js";
import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import { mountInstall, type BridgeDeps } from "../src/index.js";
import {
  createInMemoryWhatsappWindowStore,
  sendWhatsappWithinWindow,
  WHATSAPP_WINDOW_MS,
} from "../src/policy/whatsapp-window.js";
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

const REQUIRED = [
  {
    name: "WHATSAPP_PHONE_NUMBER_ID",
    why: "the WABA phone number's id — this is the INSTALL KEY (not the phone number)",
    how: [
      "Meta -> WhatsApp -> API Setup. Copy 'Phone number ID' (a long digit string).",
      "  export WHATSAPP_PHONE_NUMBER_ID='111111111111111'",
    ],
  },
  {
    name: "WHATSAPP_ACCESS_TOKEN",
    why: "a System User token with whatsapp_business_messaging",
    how: [
      "Business Settings -> Users -> System users -> Add -> Generate token,",
      "with the whatsapp_business_messaging + whatsapp_business_management scopes.",
      "  export WHATSAPP_ACCESS_TOKEN='EAAG...'",
    ],
  },
  {
    name: "WHATSAPP_APP_SECRET",
    why: "the Meta App Secret — it verifies the HMAC on every inbound webhook",
    how: [
      "Meta App -> Settings -> Basic -> App Secret -> Show.",
      "  export WHATSAPP_APP_SECRET='...'",
    ],
  },
  {
    name: "WHATSAPP_VERIFY_TOKEN",
    why: "a secret YOU choose; Meta echoes it back on the GET handshake",
    how: [
      "Any random string. You paste the SAME value into Meta's webhook config.",
      '  export WHATSAPP_VERIFY_TOKEN="$(openssl rand -hex 16)"',
    ],
  },
  {
    name: "BARKPARK_CHAT_TOKEN",
    why: "a workspace-bound ApiToken carrying the `chat` permission (D33/D35)",
    how: [
      '  Barkpark.Auth.create_token("secret", "whatsapp-bridge", "production", ["read", "chat"], ws.id)',
      "  export BARKPARK_CHAT_TOKEN='secret'",
    ],
  },
  {
    name: "BARKPARK_API_URL",
    why: "a RUNNING Barkpark API that serves /v1/chat",
    how: ["  export BARKPARK_API_URL='http://localhost:4000'"],
  },
  {
    name: "DATABASE_URL",
    why: "Postgres for the bridge's own chat_bridge schema",
    how: [
      "  export DATABASE_URL='postgres://postgres:postgres@localhost:5432/barkpark_dev'",
    ],
  },
] as const;

/** The gates NO script can clear. Named exactly, never fabricated. */
const HUMAN_GATES = [
  "1. Meta BUSINESS VERIFICATION of your business             (days; documents)",
  "2. A WhatsApp Business Account (WABA) + a phone number     -> PHONE_NUMBER_ID",
  "   (the number must not be registered to the WhatsApp consumer app)",
  "3. A System User token, whatsapp_business_messaging        -> ACCESS_TOKEN",
  "4. The Meta App Secret                                     -> APP_SECRET",
  "5. Webhook registration with YOUR chosen verify token      -> VERIFY_TOKEN",
  "     Callback URL: https://guerrilla.barkpark.cloud/connectors/webhooks/whatsapp/<phone_number_id>",
  "     Meta GETs it with hub.challenge and expects the challenge echoed. HTTPS only.",
  "6. APP REVIEW for Advanced Access. WITHOUT IT the number can only message",
  "   ~5 pre-registered TEST recipients — a demo, not a product.",
  "7. PER-TEMPLATE approval for every business-initiated message, because of the",
  "   24-hour window (see below). Templates are reviewed one at a time.",
];

function printGate(missing: string[]): void {
  const lines: string[] = [];
  lines.push("");
  lines.push("  WhatsApp smoke — HUMAN GATE. Live round-trip: NOT PASSED.");
  lines.push("");
  lines.push(`  Missing env: ${missing.join(", ")}`);
  lines.push("");
  for (const spec of REQUIRED) {
    const have = !missing.includes(spec.name);
    lines.push(`  [${have ? "ok" : "  "}] ${spec.name} — ${spec.why}`);
    if (!have) for (const step of spec.how) lines.push(`         ${step}`);
    lines.push("");
  }
  lines.push("  The gates no script can clear (docs/ops/whatsapp-meta.md):");
  lines.push("");
  for (const gate of HUMAN_GATES) lines.push(`    ${gate}`);
  lines.push("");
  lines.push("  Optional:");
  lines.push("    BARKPARK_WORKSPACE_ID   the workspace this number maps to");
  lines.push("    PORT                    listener port (default 3979)");
  lines.push(
    "    BRIDGE_PERSIST_INSTALL  '1' writes chat_bridge.connector_installs",
  );
  lines.push("");
  lines.push("  Then:  cd connectors && npm run smoke:whatsapp");
  lines.push("");
  console.error(lines.join("\n"));
}

/**
 * The self-check — runs with NO Meta account, no number, no network. Everything about
 * WhatsApp this repo can prove on its own.
 */
async function proveSelfChecks(): Promise<boolean> {
  const { Chat } = await import("chat");
  const { createMemoryState } = await import("@chat-adapter/state-memory");

  const connector = createWhatsappConnector({ apiUrl: "http://127.0.0.1:1" });
  const install: ConnectorInstall = {
    provider: WHATSAPP_PROVIDER,
    installKey: "111111111111111",
    workspaceId: "smoke-workspace",
    credentialRef: encodeWhatsappCredential({
      accessToken: "smoke-access-token",
      appSecret: "smoke-app-secret",
      verifyToken: "smoke-verify-token",
    }),
  };
  const chat = new Chat({
    userName: "barkpark",
    adapters: { [WHATSAPP_PROVIDER]: connector.adapterFactory(install) },
    state: createMemoryState(),
  });

  const url = "http://localhost/connectors/webhooks/whatsapp/111111111111111";

  const good = await chat.webhooks.whatsapp(
    new Request(
      `${url}?hub.mode=subscribe&hub.verify_token=smoke-verify-token&hub.challenge=CHAL-42`,
    ),
  );
  const goodBody = await good.text();
  const okGood = good.status === 200 && goodBody === "CHAL-42";
  console.log(
    `[smoke] GET handshake, right token  -> ${good.status} body=${JSON.stringify(goodBody)} ${okGood ? "PASS" : "FAIL"}`,
  );

  const bad = await chat.webhooks.whatsapp(
    new Request(
      `${url}?hub.mode=subscribe&hub.verify_token=WRONG&hub.challenge=CHAL-42`,
    ),
  );
  const okBad = bad.status === 403;
  console.log(
    `[smoke] GET handshake, wrong token  -> ${bad.status} ${okBad ? "PASS" : "FAIL"}`,
  );

  const forged = await chat.webhooks.whatsapp(
    new Request(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-hub-signature-256": "sha256=deadbeef",
      },
      body: JSON.stringify({ object: "whatsapp_business_account", entry: [] }),
    }),
  );
  const okForged = forged.status === 401;
  console.log(
    `[smoke] POST, bad HMAC              -> ${forged.status} ${okForged ? "PASS" : "FAIL"}`,
  );
  await chat.shutdown();

  // The 24h window, on fake timestamps. No number, no send.
  const store = createInMemoryWhatsappWindowStore();
  const t0 = 1_752_451_200_000;
  await store.recordInbound("smoke-workspace", "whatsapp:111:47999", t0);
  let posted = 0;
  const outside = await sendWhatsappWithinWindow(
    {
      store,
      now: () => t0 + WHATSAPP_WINDOW_MS + 1,
      postText: async () => {
        posted += 1;
      },
    },
    {
      workspaceId: "smoke-workspace",
      threadId: "whatsapp:111:47999",
      text: "a business-initiated nudge",
    },
  );
  const okWindow = outside.status === "dropped_outside_24h_window" && posted === 0;
  console.log(
    `[smoke] 24h window, +24h01ms        -> ${outside.status} (sent ${posted}) ${okWindow ? "PASS" : "FAIL"}`,
  );

  const all = okGood && okBad && okForged && okWindow;
  console.log(
    all
      ? "[smoke] self-checks PASS. The LIVE round-trip is still NOT PASSED — it needs Meta."
      : "[smoke] self-checks FAILED. Do not ship this.",
  );
  return all;
}

/**
 * Drive `chat.webhooks[provider]` — NEVER `adapter.handleWebhook`, which on an
 * uninitialised adapter answers 500 "No handler registered". The lookup is typed as
 * possibly-undefined, and that is not pedantry: a provider id that does not match the
 * key in `new Chat({ adapters })` silently has NO handler, and the request would
 * disappear. Fail loudly instead.
 */
function webhookHandler(
  chat: {
    webhooks: Record<string, ((request: Request) => Promise<Response>) | undefined>;
  },
  provider: string,
): (request: Request) => Promise<Response> {
  const handler = chat.webhooks[provider];
  if (!handler) {
    throw new Error(
      `no webhook handler registered for "${provider}" — the adapter key in ` +
        "new Chat({ adapters }) must equal the connector id.",
    );
  }
  return handler;
}

async function readBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}

async function main(): Promise<void> {
  const env = process.env;

  console.log(
    "[smoke] WhatsApp bridge — D43: BYO Meta app, the 24h window is OUR policy",
  );
  console.log("");
  const selfChecksOk = await proveSelfChecks();
  console.log("");

  const missing = REQUIRED.map((r) => r.name).filter((n) => !env[n]?.trim());
  if (missing.length > 0) {
    printGate(missing);
    process.exitCode = selfChecksOk ? 1 : 2;
    return;
  }

  const apiUrl = (env.BARKPARK_API_URL as string).replace(/\/$/, "");
  const chatToken = env.BARKPARK_CHAT_TOKEN as string;
  const databaseUrl = env.DATABASE_URL as string;
  const phoneNumberId = (env.WHATSAPP_PHONE_NUMBER_ID as string).trim();
  const workspaceId = env.BARKPARK_WORKSPACE_ID?.trim() || "smoke-workspace";
  const port = Number(env.PORT?.trim() || "3979");

  const client = createChatClient({ baseUrl: apiUrl, token: chatToken });
  try {
    const probe = await client.createSession();
    console.log(`[smoke] /v1/chat reachable — probe session ${probe.id}`);
  } catch (err) {
    console.error(
      "[smoke] FAILED to create a session on /v1/chat. The gate is NOT passed.",
    );
    console.error(`[smoke] ${err instanceof Error ? err.message : String(err)}`);
    process.exitCode = 1;
    return;
  }

  // Boot-fatal if the key is missing or malformed (D35/D37) — the same failure
  // the real bridge takes, taken here before anything is written.
  const cipher = createCredentialCipher({
    key: env.CONNECTORS_CREDENTIAL_KEY as string,
    previousKeys: (env.CONNECTORS_CREDENTIAL_KEY_PREVIOUS ?? "")
      .split(",")
      .map((k) => k.trim())
      .filter((k) => k !== ""),
  });

  const pool = createBridgePool({ connectionString: databaseUrl });
  await ensureBridgeSchema(pool);

  const install: ConnectorInstall = {
    provider: WHATSAPP_PROVIDER,
    installKey: phoneNumberId,
    workspaceId,
    // All four Meta credentials are per-install (D43). Plaintext today — the envelope
    // cipher is filed as connectors-encrypt-install-credentials.
    credentialRef: encodeWhatsappCredential({
      accessToken: env.WHATSAPP_ACCESS_TOKEN as string,
      appSecret: env.WHATSAPP_APP_SECRET as string,
      verifyToken: env.WHATSAPP_VERIFY_TOKEN as string,
    }),
  };

  const persist = env.BRIDGE_PERSIST_INSTALL === "1";
  const installs = persist
    ? createInstallsLookup(pool, cipher)
    : createInMemoryInstallsLookup([install]);
  if (persist) {
    await upsertInstall(pool, cipher, install);
    console.log(
      "[smoke] install persisted — credential_ref and chat_token_ref are SEALED",
    );
    console.log(
      "[smoke] (AES-256-GCM, AAD-bound to this row's provider/install_key/workspace_id).",
    );
  }

  const registry = createConnectorRegistry();
  const connector = createWhatsappConnector();
  registry.register(connector);

  const windowStore = createInMemoryWhatsappWindowStore();

  const deps: BridgeDeps = {
    config: {
      apiUrl,
      databaseUrl,
      credentialKey: env.CONNECTORS_CREDENTIAL_KEY as string,
      previousCredentialKeys: [],
      userName: env.BRIDGE_USER_NAME?.trim() || "barkpark",
      webhook: loadWebhookConfig(env),
    },
    registry,
    installs,
    map: createThreadSessionMap(createPgThreadSessionStore(pool)),
    state: createBridgeState(pool),
    // The token rides the INSTALL ROW, exactly as the real bridge does (D35).
    chatClientForInstall: (routed) =>
      createChatClient({ baseUrl: apiUrl, token: routed.chatToken }),
    onOutcome: (outcome, event) => {
      console.log(`[smoke] inbound  thread=${event.threadId}`);
      console.log(`[smoke] outcome  ${outcome.status}`);
      if (outcome.sessionUuid) {
        console.log(
          `[smoke] session  ${outcome.sessionUuid} ${outcome.minted ? "(MINTED)" : "(RESUMED)"}`,
        );
      }
    },
  };

  const mounted = mountInstall(connector, install, deps);
  await mounted.chat.initialize();

  const prefix = `/connectors/webhooks/whatsapp/${phoneNumberId}`;

  const server = createServer((req, res) => {
    void (async () => {
      const url = new URL(req.url ?? "/", `http://localhost:${port}`);
      // keySource "path": the install key comes from the URL, NEVER from the body —
      // the body must not choose the secret that verifies the body.
      if (url.pathname !== prefix) {
        res.writeHead(404).end("not found");
        return;
      }

      if (req.method === "GET") {
        // Meta's verification handshake. The adapter owns it (it holds the verifyToken).
        const response = await webhookHandler(
          mounted.chat,
          WHATSAPP_PROVIDER,
        )(new Request(url.toString()));
        const text = await response.text();
        console.log(`[smoke] GET verification -> ${response.status}`);
        res.writeHead(response.status).end(text);
        return;
      }

      if (req.method !== "POST") {
        res.writeHead(405).end("method not allowed");
        return;
      }

      const raw = await readBody(req);

      // Hand the SAME bytes to the adapter: it recomputes the HMAC over them, so a
      // re-serialised body would fail its own signature check.
      const response = await webhookHandler(
        mounted.chat,
        WHATSAPP_PROVIDER,
      )(
        new Request(url.toString(), {
          method: "POST",
          headers: Object.entries(req.headers).flatMap(([k, v]) =>
            typeof v === "string" ? [[k, v] as [string, string]] : [],
          ),
          body: raw,
        }),
      );

      if (response.status === 200) {
        // Verified. NOW the body may be trusted — cross-check it against the path key,
        // and record the inbound timestamp that opens the 24-hour window.
        let payload: unknown = null;
        try {
          payload = JSON.parse(raw);
        } catch {
          /* the adapter already accepted it; a parse failure here only skips the record */
        }
        if (payload && !whatsappPayloadMatchesInstall(phoneNumberId, payload)) {
          console.log(
            `[smoke] WARNING: a verified body's phone_number_id does not match the path key ` +
              `(${phoneNumberId}). Routed by one identity, carrying another.`,
          );
        }
        const at = whatsappInboundTimestampMs(payload);
        if (at !== null) {
          await windowStore.recordInbound(
            workspaceId,
            `whatsapp:${phoneNumberId}`,
            at,
          );
          console.log(
            `[smoke] 24h window opened at ${new Date(at).toISOString()} (closes ${new Date(at + WHATSAPP_WINDOW_MS).toISOString()})`,
          );
        }
      } else {
        console.log(
          `[smoke] POST -> ${response.status} (401 = App Secret mismatch)`,
        );
      }

      const text = await response.text();
      res.writeHead(response.status).end(text);
    })().catch((err) => {
      console.error("[smoke] webhook error:", err);
      if (!res.headersSent) res.writeHead(500).end("error");
    });
  });

  server.listen(port, () => {
    console.log("");
    console.log(`[smoke] listening on http://localhost:${port}${prefix}`);
    console.log(
      `[smoke] install   phone_number_id=${phoneNumberId} -> workspace=${workspaceId}`,
    );
    console.log("");
    console.log(
      "[smoke] Register a PUBLIC HTTPS callback that forwards here, answer Meta's",
    );
    console.log(
      "[smoke] GET challenge, then message the number from an allowlisted device.",
    );
    console.log(
      "[smoke] Until a real message round-trips, the live gate is NOT PASSED.",
    );
  });

  const stop = async () => {
    server.close();
    await mounted.chat.shutdown();
    await pool.end();
    process.exit(0);
  };
  process.on("SIGINT", () => void stop());
  process.on("SIGTERM", () => void stop());
}

main().catch((err) => {
  console.error("[smoke] fatal:", err);
  process.exit(1);
});
