/**
 * Microsoft Teams smoke — the runnable half of an HONEST human gate (charter D42).
 *
 * STATUS: **the live Teams round-trip is NOT PASSED.** It cannot be, from here.
 * A Teams activity is authenticated by a Bot Framework JWT that MICROSOFT signs; we
 * cannot mint one, and the adapter rejects every activity we can synthesise with a
 * 401 in ~2ms. That 401 is the shipped fail-closed behaviour, not a defect — and it is
 * precisely why "Teams works" is unprovable until a human clears the Azure gate below.
 *
 * So this script does the two honest things:
 *
 *   1. WITHOUT the gate (no env at all) it still runs, and PROVES the fail-closed path:
 *      an unsigned activity through `chat.webhooks.teams` -> 401, no handler, no Session.
 *      Then it prints the exact gate. It never prints a success it did not observe.
 *
 *   2. WITH the gate cleared it starts a real webhook listener, so a real Teams message
 *      goes: Azure Bot -> this endpoint -> tenant routing -> /v1/chat -> ONE reply posted
 *      back into the Teams thread.
 *
 * The listener here is SMOKE-ONLY. Production inbound HTTP is the bridge's own webhook
 * seam; this script owns a `node:http` server just so the gate is runnable today.
 *
 * Full runbook: docs/ops/teams-azure-bot.md
 */
import { createServer, type IncomingMessage } from "node:http";

import { createChatClient } from "../src/chat-client/client.js";
import { createConnectorRegistry } from "../src/connector/registry.js";
import type { ConnectorInstall } from "../src/connector/types.js";
import { createTeamsConnector, TEAMS_PROVIDER } from "../src/connectors/teams.js";
import { loadWebhookConfig } from "../src/config.js";
import { createCredentialCipher } from "../src/crypto/credential-cipher.js";
import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import { mountInstall, type BridgeDeps } from "../src/index.js";
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
    name: "TEAMS_APP_ID",
    why: "the Microsoft App ID of the ONE operator Azure app (Multitenant)",
    how: [
      "Azure Portal -> App registrations -> New registration.",
      "  Supported account types: 'Accounts in any organizational directory' (MULTITENANT).",
      "Copy the Application (client) ID:",
      "  export TEAMS_APP_ID='00000000-0000-0000-0000-000000000000'",
      "There is NO per-workspace credential — one app serves every customer org (D42).",
    ],
  },
  {
    name: "TEAMS_APP_PASSWORD",
    why: "that app's client secret",
    how: [
      "Same app registration -> Certificates & secrets -> New client secret.",
      "Copy the VALUE (not the id — it is shown once):",
      "  export TEAMS_APP_PASSWORD='...'",
    ],
  },
  {
    name: "TEAMS_TENANT_ID",
    why: "the Microsoft tenant id of the org you will message from — the INSTALL KEY",
    how: [
      "It is the customer org's Azure AD tenant id (yours, for a self-smoke).",
      "Azure Portal -> Microsoft Entra ID -> Overview -> Tenant ID.",
      "  export TEAMS_TENANT_ID='11111111-1111-1111-1111-111111111111'",
      "This becomes connector_installs.install_key; credential_ref stays NULL.",
    ],
  },
  {
    name: "BARKPARK_CHAT_TOKEN",
    why: "a workspace-bound ApiToken carrying the `chat` permission (D33/D35)",
    how: [
      "In an api/ console (cd api && iex -S mix), with YOUR workspace id:",
      '  Barkpark.Auth.create_token("secret", "teams-bridge", "production", ["read", "chat"], ws.id)',
      "A `chat` token WITHOUT a workspace_id resolves to :global — WRONG for multi-tenant.",
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
    why: "Postgres for the bridge's own chat_bridge schema (thread -> session map)",
    how: [
      "  export DATABASE_URL='postgres://postgres:postgres@localhost:5432/barkpark_dev'",
    ],
  },
] as const;

/** The gates NO script can clear. Named exactly, never fabricated. */
const HUMAN_GATES = [
  "1. Azure AD app registration, type MULTITENANT            -> TEAMS_APP_ID",
  "2. A client secret on that app                            -> TEAMS_APP_PASSWORD",
  "3. An Azure Bot resource (Multi Tenant), reusing that app",
  "4. Its Messaging endpoint set to the bridge's public URL:",
  "     https://guerrilla.barkpark.cloud/connectors/webhooks/teams",
  "     (Bot Framework requires HTTPS — no plain HTTP, no bare IP.)",
  "5. The Microsoft Teams CHANNEL enabled on that bot",
  "6. A Teams app manifest + icons, zipped",
  "7. IRREDUCIBLE, once per customer org: THAT ORG'S OWN TEAMS ADMIN must",
  "   consent to / sideload / publish the app inside their tenant.",
  "   Barkpark can NEVER do this on a customer's behalf — it is their",
  "   tenant, their admin policy, their click.",
];

function printGate(missing: string[]): void {
  const lines: string[] = [];
  lines.push("");
  lines.push("  Teams smoke — HUMAN GATE. Live round-trip: NOT PASSED.");
  lines.push("");
  lines.push(`  Missing env: ${missing.join(", ")}`);
  lines.push("");
  for (const spec of REQUIRED) {
    const have = !missing.includes(spec.name);
    lines.push(`  [${have ? "ok" : "  "}] ${spec.name} — ${spec.why}`);
    if (!have) for (const step of spec.how) lines.push(`         ${step}`);
    lines.push("");
  }
  lines.push("  The gates no script can clear (docs/ops/teams-azure-bot.md):");
  lines.push("");
  for (const gate of HUMAN_GATES) lines.push(`    ${gate}`);
  lines.push("");
  lines.push("  Optional:");
  lines.push("    BARKPARK_WORKSPACE_ID   the workspace this Teams org maps to");
  lines.push("    PORT                    listener port (default 3978)");
  lines.push(
    "    BRIDGE_PERSIST_INSTALL  '1' writes chat_bridge.connector_installs",
  );
  lines.push("");
  lines.push("  Then:  cd connectors && npm run smoke:teams");
  lines.push("");
  console.error(lines.join("\n"));
}

/**
 * The fail-closed proof — runs with NO Azure gate, no network, in milliseconds.
 *
 * This is the ONLY thing about Teams this repo can prove on its own, so it runs on every
 * invocation, gate or no gate.
 */
async function proveFailClosed(): Promise<boolean> {
  const { Chat } = await import("chat");
  const { createMemoryState } = await import("@chat-adapter/state-memory");

  const connector = createTeamsConnector({
    appId: "smoke-app-id",
    appPassword: "smoke-app-password",
  });
  const chat = new Chat({
    userName: "barkpark",
    adapters: {
      [TEAMS_PROVIDER]: connector.adapterFactory({
        provider: TEAMS_PROVIDER,
        installKey: "00000000-0000-0000-0000-000000000000",
        workspaceId: "smoke-workspace",
        credentialRef: null, // <- the D42 fact, exercised
      }),
    },
    state: createMemoryState(),
  });

  let handlerRan = false;
  chat.onDirectMessage(async () => {
    handlerRan = true;
  });

  const started = Date.now();
  const response = await chat.webhooks.teams(
    new Request("http://localhost/connectors/webhooks/teams", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        type: "message",
        id: "smoke-1",
        text: "hello",
        conversation: {
          id: "19:smoke",
          tenantId: "11111111-1111-1111-1111-111111111111",
        },
        channelData: { tenant: { id: "11111111-1111-1111-1111-111111111111" } },
        serviceUrl: "https://smba.trafficmanager.net/emea/",
        from: { id: "29:u" },
        recipient: { id: "28:bot" },
      }),
    }),
  );
  const elapsed = Date.now() - started;
  await chat.shutdown();

  const ok = response.status === 401 && !handlerRan;
  console.log(
    `[smoke] fail-closed check: unsigned activity -> ${response.status} in ${elapsed}ms, ` +
      `handler ran = ${handlerRan}`,
  );
  console.log(
    ok
      ? "[smoke] PASS — no Bot Framework JWT, no turn. (This is the ONLY Teams behaviour\n" +
          "[smoke]        provable without Azure. A successful turn is NOT proven.)"
      : "[smoke] FAIL — an unsigned activity was NOT rejected. Do not ship this.",
  );
  return ok;
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
    "[smoke] Teams bridge — D42: ONE operator Azure app, no per-workspace credential",
  );
  console.log("");
  const failClosedOk = await proveFailClosed();
  console.log("");

  const missing = REQUIRED.map((r) => r.name).filter((n) => !env[n]?.trim());
  if (missing.length > 0) {
    printGate(missing);
    process.exitCode = failClosedOk ? 1 : 2;
    return;
  }

  const apiUrl = (env.BARKPARK_API_URL as string).replace(/\/$/, "");
  const chatToken = env.BARKPARK_CHAT_TOKEN as string;
  const databaseUrl = env.DATABASE_URL as string;
  const msTenantId = (env.TEAMS_TENANT_ID as string).trim();
  const workspaceId = env.BARKPARK_WORKSPACE_ID?.trim() || "smoke-workspace";
  const port = Number(env.PORT?.trim() || "3978");

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
    provider: TEAMS_PROVIDER,
    installKey: msTenantId, // the Microsoft tenant id IS the install key
    workspaceId,
    credentialRef: null, // D42: no per-workspace provider credential. NULL, not "".
    // THIS install's own workspace-bound chat token (D35). The bridge holds no
    // process-wide operator token to fall back on — and must not.
    chatToken,
  };

  const persist = env.BRIDGE_PERSIST_INSTALL === "1";
  const installs = persist
    ? createInstallsLookup(pool, cipher)
    : createInMemoryInstallsLookup([install]);
  if (persist) await upsertInstall(pool, cipher, install);

  const registry = createConnectorRegistry();
  const connector = createTeamsConnector({
    appId: env.TEAMS_APP_ID as string,
    appPassword: env.TEAMS_APP_PASSWORD as string,
    appType: "MultiTenant",
  });
  registry.register(connector);

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

  const server = createServer((req, res) => {
    void (async () => {
      if (!req.url?.startsWith("/connectors/webhooks/teams")) {
        res.writeHead(404).end("not found");
        return;
      }
      if (req.method !== "POST") {
        // Teams posts activities; there is no GET handshake (contrast WhatsApp).
        res.writeHead(405).end("method not allowed");
        return;
      }

      // Read the bytes ONCE, route on them, then hand the SAME bytes to the adapter.
      // The body stream cannot be consumed twice — the production seam has to do exactly
      // this, which is why extractInstallKey takes a parsed payload, not a Request.
      const raw = await readBody(req);
      let payload: unknown = null;
      try {
        payload = JSON.parse(raw);
      } catch {
        res.writeHead(400).end("bad json");
        return;
      }

      const inboundTenant = connector.webhook.extractInstallKey(payload);
      const resolved = await installs.resolveWorkspace(
        TEAMS_PROVIDER,
        inboundTenant,
      );
      console.log(
        `[smoke] webhook  tenant=${inboundTenant ?? "<none>"} -> workspace=${resolved ?? "<none — DROPPED>"}`,
      );
      if (!resolved) {
        // Fail closed: an org that has not installed the app gets nothing. 202 so
        // Bot Framework does not retry a message we will never accept.
        res.writeHead(202).end("no install for this tenant");
        return;
      }

      const response = await webhookHandler(
        mounted.chat,
        TEAMS_PROVIDER,
      )(
        new Request(`http://localhost${req.url}`, {
          method: "POST",
          headers: Object.entries(req.headers).flatMap(([k, v]) =>
            typeof v === "string" ? [[k, v] as [string, string]] : [],
          ),
          body: raw,
        }),
      );

      const text = await response.text();
      res.writeHead(response.status, {
        "content-type": response.headers.get("content-type") ?? "text/plain",
      });
      res.end(text);
      if (response.status === 401) {
        console.log(
          "[smoke] 401 — the Bot Framework JWT did not validate. Check that the Azure Bot\n" +
            "[smoke]       resource uses THIS app id, and that the messaging endpoint is this host.",
        );
      }
    })().catch((err) => {
      console.error("[smoke] webhook error:", err);
      if (!res.headersSent) res.writeHead(500).end("error");
    });
  });

  server.listen(port, () => {
    console.log("");
    console.log(
      `[smoke] listening on http://localhost:${port}/connectors/webhooks/teams`,
    );
    console.log(
      `[smoke] install   tenant=${msTenantId} -> workspace=${workspaceId} (credential_ref NULL)`,
    );
    console.log("");
    console.log(
      "[smoke] Point the Azure Bot's Messaging endpoint at a PUBLIC HTTPS URL that",
    );
    console.log(
      "[smoke] forwards here, then message the bot in Teams. Expect ONE reply.",
    );
    console.log(
      "[smoke] Until a real activity is processed, the live round-trip is NOT PASSED.",
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
