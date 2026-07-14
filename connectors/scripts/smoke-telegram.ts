/**
 * Telegram end-to-end smoke — the runnable half of an HONEST human gate.
 *
 * This script cannot prove itself. A real round-trip needs a real BotFather
 * bot and a running Barkpark /v1/chat, and neither exists in CI. So:
 *
 *   - with the env set, it runs the REAL loop (getUpdates polling -> /v1/chat
 *     -> one reply posted back to your Telegram chat) and prints what happened;
 *   - with the env missing, it prints the EXACT steps to get there and exits
 *     non-zero. It never prints a success it did not observe.
 *
 * Polling mode (getUpdates) is deliberate: no public URL, no tunnel, so the
 * gate runs on a laptop.
 *
 * Full walkthrough: connectors/docs/telegram-smoke.md
 */
import { createChatClient } from "../src/chat-client/client.js";
import { loadWebhookConfig, MissingConfigError } from "../src/config.js";
import { createConnectorRegistry } from "../src/connector/registry.js";
import type { ConnectorInstall } from "../src/connector/types.js";
import {
  createTelegramConnector,
  telegramBotIdFromToken,
  TELEGRAM_PROVIDER,
} from "../src/connectors/telegram.js";
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
    name: "TELEGRAM_BOT_TOKEN",
    why: "the BotFather token for the bot you will message",
    how: [
      "Open Telegram, message @BotFather, send /newbot, follow the prompts.",
      'It replies with a token shaped "123456789:AA...". Export it:',
      "  export TELEGRAM_BOT_TOKEN='123456789:AA...'",
    ],
  },
  {
    name: "BARKPARK_CHAT_TOKEN",
    why: "THIS install's workspace-bound `chat` ApiToken — sealed into its connector_installs row (D33/D35), never used as a process-wide token",
    how: [
      "Mint the token out-of-band (no HTTP mint endpoint exists yet).",
      "In an api/ console (cd api && iex -S mix), with YOUR workspace id:",
      "  Barkpark.Auth.create_token(",
      '    "my-telegram-secret",        # the raw token you will export',
      '    "telegram-bridge",           # label',
      '    "production",                # dataset',
      '    ["read", "chat"],            # permissions — `chat` is required',
      "    ws.id                        # workspace_id — REQUIRED for tenancy",
      "  )",
      "Signature: create_token(raw_token, label, dataset, permissions, workspace_id \\\\ nil)",
      "A `chat` token WITHOUT a workspace_id resolves to :global (admin scope) —",
      "fine for a solo dev smoke, WRONG for real multi-tenant isolation.",
      "  export BARKPARK_CHAT_TOKEN='my-telegram-secret'",
      "This smoke SEALS it into chat_bridge.connector_installs.chat_token_ref for",
      "this bot's install. The running bridge reads it from there and nowhere else.",
    ],
  },
  {
    name: "CONNECTORS_CREDENTIAL_KEY",
    why: "the AES-256-GCM key that seals BOTH secrets in every install row (D35)",
    how: [
      "An INDEPENDENT key — not BARKPARK_KEK, not an ApiToken. 32 bytes, base64:",
      "  export CONNECTORS_CREDENTIAL_KEY=$(openssl rand -base64 32)",
      "Missing => the bridge REFUSES to boot. There is no plaintext fallback:",
      "encryption you can switch off by unsetting a variable is not encryption.",
      "Keep it: rows sealed under a lost key can never be opened again (rotate",
      "via CONNECTORS_CREDENTIAL_KEY_PREVIOUS, do not lose the current one).",
    ],
  },
  {
    name: "BARKPARK_API_URL",
    why: "a RUNNING Barkpark API that serves /v1/chat",
    how: [
      "Start it locally (cd api && mix phx.server), then:",
      "  export BARKPARK_API_URL='http://localhost:4000'",
      "Verify /v1/chat answers (401 without a token is the healthy answer):",
      "  curl -si localhost:4000/v1/chat/sessions | head -1",
    ],
  },
  {
    name: "DATABASE_URL",
    why: "Postgres for the bridge's own chat_bridge schema (thread -> session map)",
    how: [
      "Point at the same Postgres Barkpark uses; the bridge creates and owns",
      "ONLY the `chat_bridge` schema (never touches `public`).",
      "  export DATABASE_URL='postgres://postgres:postgres@localhost:5432/barkpark_dev'",
    ],
  },
] as const;

function printGate(missing: string[]): void {
  const lines: string[] = [];
  lines.push("");
  lines.push("  Telegram smoke — HUMAN GATE. Not run: prerequisites missing.");
  lines.push("");
  lines.push(`  Missing: ${missing.join(", ")}`);
  lines.push("");
  lines.push("  This proves nothing until a human supplies the following.");
  lines.push("  Nothing below is faked, mocked, or assumed.");
  lines.push("");

  for (const spec of REQUIRED) {
    const have = !missing.includes(spec.name);
    lines.push(`  [${have ? "ok" : "  "}] ${spec.name} — ${spec.why}`);
    if (!have) {
      for (const step of spec.how) lines.push(`         ${step}`);
    }
    lines.push("");
  }

  lines.push("  Optional:");
  lines.push("    BARKPARK_WORKSPACE_ID   the workspace this bot belongs to");
  lines.push("                            (default: 'smoke-workspace')");
  lines.push("    BRIDGE_PERSIST_INSTALL  '1' writes the install into");
  lines.push("                            chat_bridge.connector_installs");
  lines.push("");
  lines.push("  Then:  cd connectors && npm run smoke:telegram");
  lines.push(
    "  Then:  DM your bot on Telegram. Expect exactly ONE reply per message.",
  );
  lines.push("");
  lines.push("  Full walkthrough: connectors/docs/telegram-smoke.md");
  lines.push("");
  console.error(lines.join("\n"));
}

async function main(): Promise<void> {
  const env = process.env;
  const missing = REQUIRED.map((r) => r.name).filter((n) => !env[n]?.trim());

  if (missing.length > 0) {
    printGate(missing);
    process.exitCode = 1;
    return;
  }

  const apiUrl = (env.BARKPARK_API_URL as string).replace(/\/$/, "");
  const botToken = env.TELEGRAM_BOT_TOKEN as string;
  const chatToken = env.BARKPARK_CHAT_TOKEN as string;
  const databaseUrl = env.DATABASE_URL as string;
  const workspaceId = env.BARKPARK_WORKSPACE_ID?.trim() || "smoke-workspace";
  const botId = telegramBotIdFromToken(botToken);

  console.log("[smoke] Telegram bridge — live round-trip");
  console.log(`[smoke]   api          ${apiUrl}`);
  console.log(`[smoke]   bot id       ${botId}`);
  console.log(`[smoke]   workspace    ${workspaceId}`);
  console.log("");

  // Fail fast and LOUDLY if /v1/chat is not actually reachable — better than a
  // silent poll loop that never answers.
  const client = createChatClient({ baseUrl: apiUrl, token: chatToken });
  try {
    const probe = await client.createSession();
    console.log(`[smoke] /v1/chat reachable — probe session ${probe.id}`);
  } catch (err) {
    console.error("");
    console.error(
      "[smoke] FAILED to create a session on /v1/chat. The gate is NOT passed.",
    );
    console.error(`[smoke] ${err instanceof Error ? err.message : String(err)}`);
    console.error("");
    console.error(
      "[smoke] 401/403 => BARKPARK_CHAT_TOKEN lacks the `chat` permission,",
    );
    console.error(
      "[smoke]            or carries no workspace_id. See docs/telegram-smoke.md.",
    );
    console.error(
      "[smoke] ECONNREFUSED => no API is listening at BARKPARK_API_URL.",
    );
    process.exitCode = 1;
    return;
  }

  // Boot-fatal if the key is missing or malformed (D35) — the same failure the
  // real bridge takes, taken here before anything is written.
  const cipher = createCredentialCipher({
    key: env.CONNECTORS_CREDENTIAL_KEY as string,
    previousKeys: (env.CONNECTORS_CREDENTIAL_KEY_PREVIOUS ?? "")
      .split(",")
      .map((k) => k.trim())
      .filter((k) => k !== ""),
  });

  const pool = createBridgePool({ connectionString: databaseUrl });
  // Fails CLOSED if the pool is not pinned to chat_bridge — better to refuse
  // than to scatter the SDK's tables across Barkpark's `public` schema (D28).
  await ensureBridgeSchema(pool);
  console.log(
    "[smoke] chat_bridge schema ready (thread_session_map, connector_installs)",
  );

  const install: ConnectorInstall = {
    provider: TELEGRAM_PROVIDER,
    installKey: botId,
    workspaceId,
    credentialRef: botToken,
    // THIS install's own chat token. The bridge has no other one to fall back on.
    chatToken,
  };

  // The install row is what routes an inbound update to a tenant AND what its
  // /v1/chat traffic is authenticated with. Persist it only on request — a smoke
  // run should not silently mutate a shared DB.
  const persist = env.BRIDGE_PERSIST_INSTALL === "1";
  const installs = persist
    ? createInstallsLookup(pool, cipher)
    : createInMemoryInstallsLookup([install]);

  if (persist) {
    await upsertInstall(pool, cipher, install);
    console.log("[smoke] install persisted to chat_bridge.connector_installs");
    console.log(
      "[smoke] both credential_ref and chat_token_ref are SEALED (AES-256-GCM,",
    );
    console.log(
      `[smoke] AAD-bound to provider=${TELEGRAM_PROVIDER} install=${botId} workspace=${workspaceId}).`,
    );
  } else {
    console.log(
      "[smoke] install held in memory (set BRIDGE_PERSIST_INSTALL=1 to persist)",
    );
  }

  const registry = createConnectorRegistry();
  const connector = createTelegramConnector({ mode: "polling" });
  registry.register(connector);

  const deps: BridgeDeps = {
    config: {
      apiUrl,
      databaseUrl,
      credentialKey: env.CONNECTORS_CREDENTIAL_KEY as string,
      previousCredentialKeys: [],
      userName: env.BRIDGE_USER_NAME?.trim() || "barkpark",
      // Inert here: the smoke drives Telegram by POLLING and never starts the
      // inbound HTTP listener. Carried so the config stays one shape.
      webhook: loadWebhookConfig(env),
    },
    registry,
    installs,
    map: createThreadSessionMap(createPgThreadSessionStore(pool)),
    state: createBridgeState(pool),
    // The token rides the INSTALL, exactly as the real bridge does (D35). The
    // probe client above is not reused: it would hide a broken install row.
    chatClientForInstall: (routed) =>
      createChatClient({ baseUrl: apiUrl, token: routed.chatToken }),
    onOutcome: (outcome, event) => {
      console.log("");
      console.log(
        `[smoke] inbound  thread=${event.threadId} text=${JSON.stringify(event.text)}`,
      );
      console.log(`[smoke] outcome  ${outcome.status}`);
      if (outcome.sessionUuid) {
        console.log(
          `[smoke] session  ${outcome.sessionUuid} ${outcome.minted ? "(MINTED — first message in this thread)" : "(RESUMED — same Session as before)"}`,
        );
      }
      if (outcome.status === "posted") {
        console.log(
          `[smoke] replied  ${JSON.stringify(outcome.text?.slice(0, 160))}`,
        );
        console.log("[smoke] ✓ round-trip complete — check your Telegram chat.");
      }
      if (outcome.status === "dropped_no_tenant") {
        console.log(
          "[smoke] ✗ no tenant resolved — the install row does not match this bot.",
        );
      }
      if (outcome.status === "dropped_no_install") {
        console.log(
          "[smoke] ✗ install row unusable — its sealed refs did not open. Wrong",
        );
        console.log(
          "[smoke]   CONNECTORS_CREDENTIAL_KEY, or the row was written under another one.",
        );
      }
      if (outcome.status === "dropped_no_chat_token") {
        console.log(
          "[smoke] ✗ this install has no chat token sealed into chat_token_ref.",
        );
        console.log(
          "[smoke]   The bridge will NOT fall back to an operator token (D35).",
        );
      }
      if (outcome.status === "empty_reply") {
        console.log(
          "[smoke] ! turn produced no text; nothing posted (we never post an empty message).",
        );
      }
    },
  };

  const mounted = mountInstall(connector, install, deps);
  await mounted.chat.initialize();
  await connector.listen?.(mounted.adapter);

  console.log("");
  console.log("[smoke] polling (getUpdates). No public URL needed.");
  console.log("[smoke] DM your bot on Telegram now. Ctrl-C to stop.");
  console.log(
    "[smoke] Expect EXACTLY ONE reply per message (post-once-per-turn, D12).",
  );

  const shutdown = async () => {
    console.log("\n[smoke] stopping…");
    await connector.stopListening?.(mounted.adapter);
    await mounted.chat.shutdown();
    await pool.end();
    process.exit(0);
  };
  process.on("SIGINT", () => void shutdown());
  process.on("SIGTERM", () => void shutdown());
}

main().catch((err) => {
  console.error(
    "[smoke] fatal:",
    err instanceof MissingConfigError ? err.message : err,
  );
  process.exit(1);
});
