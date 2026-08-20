/**
 * Discord dev-loop smoke — the runnable half of an HONEST BYO-bot gate (charter
 * D41/D228/D230).
 *
 * TWO legs, ONE command:
 *
 *   1. THE OFFLINE PROOF (runs on EVERY invocation, no credentials, no network,
 *      no public tunnel). A locally-generated Ed25519 keypair signs a real
 *      Discord interaction the way Discord does — `sign(timestamp + rawBody)`,
 *      hex-encoded — and POSTs it to a LOCAL bridge mounted at the same
 *      `/connectors/webhooks/discord/:installKey` route production serves. We
 *      assert the vendor answers HTTP 200 with a synchronous `type: 5` deferred
 *      ack, exactly as `test/discord-slash-commands.test.ts` proves. This is the
 *      ONLY leg this repo can prove on its own, so it always runs.
 *
 *   2. THE OPT-IN LIVE REGISTRATION (runs ONLY when the BYO-bot credential triple
 *      + a dev guild id are present). It PUTs a guild-scoped command to Discord's
 *      v10 REST API — guild scope propagates INSTANTLY, unlike global's ~1h — so
 *      an operator can then invoke `/smoke` in that guild. This leg needs live
 *      Discord credentials, so it is a DOCUMENTED OPS STEP and is NEVER wired into
 *      CI (charter D230): with no credentials the script prints the exact gate and
 *      exits non-zero, having already proven leg 1.
 *
 * The offline leg CANNOT use the real bot's key: Discord holds the private half,
 * so a real signature can only be produced by Discord. We generate our own
 * keypair and build the adapter with OUR public key — this proves the BRIDGE's
 * verify → ack → dispatch path, not Discord's signing. The live leg proves the
 * REST registration reaches Discord. Neither pretends to be the other.
 *
 * Full runbook: connectors/docs/discord-byo-bot.md
 */
import { createServer, type IncomingMessage } from "node:http";
import { generateKeyPairSync, sign as edSign } from "node:crypto";

import { Chat } from "chat";
import { createDiscordAdapter } from "@chat-adapter/discord";
import { createMemoryState } from "@chat-adapter/state-memory";

import {
  DISCORD_PROVIDER,
  extendDiscordInteractionWebhook,
  parseDiscordCredential,
} from "../src/connectors/discord.js";

/** Discord's REST API — pinned to v10 (matches @chat-adapter/discord@4.34.0). */
const DISCORD_API_BASE = "https://discord.com/api/v10";

/**
 * The BYO-bot credential triple + the dev guild, read ONLY by the opt-in live
 * registration leg. All four are required together; the offline leg needs none
 * of them and never reads them.
 */
const REQUIRED = [
  {
    name: "DISCORD_APPLICATION_ID",
    why: "the Application ID of YOUR Discord app (non-secret; also the install key)",
    how: [
      "https://discord.com/developers/applications -> your app ->",
      "  General Information -> Application ID -> Copy.",
      "  export DISCORD_APPLICATION_ID='111111111111111111'",
    ],
  },
  {
    name: "DISCORD_BOT_TOKEN",
    why: "that app's bot token — the secret that authorizes the REST registration",
    how: [
      "Same app -> Bot -> Reset Token -> Copy (shown once).",
      "  export DISCORD_BOT_TOKEN='...'",
    ],
  },
  {
    name: "DISCORD_PUBLIC_KEY",
    why: "the app's Ed25519 public key (non-secret; verifies interaction signatures)",
    how: [
      "Same app -> General Information -> Public Key -> Copy.",
      "  export DISCORD_PUBLIC_KEY='<64 hex chars>'",
    ],
  },
  {
    name: "DISCORD_GUILD_ID",
    why: "a DEV guild id — guild-scoped registration propagates INSTANTLY (global is ~1h)",
    how: [
      "In Discord: User Settings -> Advanced -> enable Developer Mode, then",
      "right-click your server -> Copy Server ID. Invite the bot to it first.",
      "  export DISCORD_GUILD_ID='222222222222222222'",
    ],
  },
] as const;

function printGate(missing: string[]): void {
  const lines: string[] = [];
  lines.push("");
  lines.push(
    "  Discord LIVE registration — OPT-IN OPS STEP, not run (charter D230).",
  );
  lines.push("");
  lines.push(`  Missing: ${missing.join(", ")}`);
  lines.push("");
  lines.push(
    "  The offline Ed25519 proof above already ran. This leg additionally",
  );
  lines.push(
    "  registers a guild-scoped /command against Discord's live REST API, so it",
  );
  lines.push(
    "  needs real BYO-bot credentials and is DELIBERATELY never wired into CI.",
  );
  lines.push("");
  for (const spec of REQUIRED) {
    const have = !missing.includes(spec.name);
    lines.push(`  [${have ? "ok" : "  "}] ${spec.name} — ${spec.why}`);
    if (!have) for (const step of spec.how) lines.push(`         ${step}`);
    lines.push("");
  }
  lines.push("  Also enable, in the Developer Portal (no API can read these):");
  lines.push("    - Bot -> Privileged Gateway Intents -> Message Content Intent");
  lines.push(
    "    - General Information -> Interactions Endpoint URL -> your PUBLIC",
  );
  lines.push(
    "      https://<host>/connectors/webhooks/discord/<applicationId> (Discord",
  );
  lines.push(
    "      PING-validates it at save time; the route must be live and reachable).",
  );
  lines.push("");
  lines.push("  Optional:");
  lines.push(
    "    SMOKE_DISCORD_COMMAND   command name to register (default: 'smoke')",
  );
  lines.push(
    "    SMOKE_DISCORD_PORT      local bridge port for the offline proof (default: 8477)",
  );
  lines.push("");
  lines.push("  Then:  cd connectors && npm run smoke:discord");
  lines.push(
    "  Then:  in the dev guild, type /<command>. Cleanup: re-run the PUT with [].",
  );
  lines.push("");
  lines.push("  Full runbook: connectors/docs/discord-byo-bot.md");
  lines.push("");
  console.error(lines.join("\n"));
}

/** Read a node:http request body to a single UTF-8 string (raw bytes preserved). */
async function readBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}

/**
 * THE OFFLINE PROOF. A local Ed25519 keypair, a local bridge, a real signed HTTP
 * POST to the real webhook route — zero credentials, zero public tunnel, and the
 * only egress the adapter attempts (its follow-up PATCH to discord.com) is
 * captured by a scoped fetch shim so nothing leaves the machine.
 *
 * Returns true iff the signed PING answered `{type:1}` AND the signed
 * APPLICATION_COMMAND answered HTTP 200 `{type:5}`.
 */
async function proveOfflineSignedInteraction(): Promise<boolean> {
  const port = Number(process.env.SMOKE_DISCORD_PORT?.trim() || "8477");
  const installKey =
    process.env.DISCORD_APPLICATION_ID?.trim() || "offline-smoke-app";

  // A throwaway keypair. The adapter's verifyKey wants the RAW 32-byte public
  // key, hex-encoded (the recipe banked in discord-slash-commands.test.ts).
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const publicKeyHex = Buffer.from(
    publicKey.export({ format: "jwk" }).x as string,
    "base64url",
  ).toString("hex");

  // Discord signs the concatenation `timestamp + rawBody`; Ed25519, hex-encoded.
  const sign = (timestamp: string, body: string): string =>
    edSign(null, Buffer.from(timestamp + body, "utf8"), privateKey).toString("hex");

  const adapter = createDiscordAdapter({
    applicationId: installKey,
    botToken: "offline-smoke-bot-token",
    publicKey: publicKeyHex,
  });
  const chat = new Chat({
    userName: "barkpark",
    adapters: { [DISCORD_PROVIDER]: adapter },
    state: createMemoryState(),
  });

  let handlerRan = false;
  chat.onSlashCommand(async (event) => {
    handlerRan = true;
    // The reply rides event.channel.post — the adapter routes it to the
    // interaction follow-up (a PATCH to discord.com), which the shim below
    // captures rather than lets escape.
    await event.channel.post(`handled ${event.command}`);
  });
  // The W30/W31 seam (verified type-5 MODAL_SUBMIT re-route + D249 hold),
  // wrapped in place exactly as mountInstall does. Defaults for the smoke.
  extendDiscordInteractionWebhook(chat, adapter, {});

  const webhook = chat.webhooks[DISCORD_PROVIDER];
  if (!webhook) {
    console.error(
      "[smoke] no webhook handler for 'discord' — adapter key mismatch. Aborting.",
    );
    await chat.shutdown().catch(() => {});
    return false;
  }

  // Scoped fetch shim: fake ONLY discord.com egress (the adapter's follow-up
  // PATCH), pass everything else (our localhost POST) through to the real fetch.
  const realFetch = globalThis.fetch.bind(globalThis);
  const followUps: string[] = [];
  globalThis.fetch = (async (input: unknown, init?: RequestInit) => {
    const url =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.href
          : (input as Request).url;
    if (url.startsWith("https://discord.com/")) {
      followUps.push(`${init?.method ?? "GET"} ${url}`);
      return new Response(JSON.stringify({ id: "offline-follow-up" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    return realFetch(input as string | URL | Request, init);
  }) as typeof fetch;

  const routePath = `/connectors/webhooks/discord/${installKey}`;
  const bg: Promise<unknown>[] = [];
  const server = createServer((req, res) => {
    void (async () => {
      if (req.method !== "POST" || !req.url?.startsWith(routePath)) {
        res.writeHead(404).end("not found");
        return;
      }
      // Read the raw bytes ONCE and re-send them verbatim — Ed25519 signs the
      // raw body, so a re-serialize would break verification (D228).
      const raw = await readBody(req);
      const response = await webhook(
        new Request(`http://localhost:${port}${req.url}`, {
          method: "POST",
          headers: Object.entries(req.headers).flatMap(([k, v]) =>
            typeof v === "string" ? [[k, v] as [string, string]] : [],
          ),
          body: raw,
        }),
        { waitUntil: (p: Promise<unknown>) => bg.push(p) },
      );
      const text = await response.text();
      res.writeHead(response.status, {
        "content-type": response.headers.get("content-type") ?? "text/plain",
      });
      res.end(text);
    })().catch((err) => {
      console.error("[smoke] local webhook error:", err);
      if (!res.headersSent) res.writeHead(500).end("error");
    });
  });

  async function post(body: string): Promise<Response> {
    const timestamp = String(Math.floor(Date.now() / 1000));
    return realFetch(`http://localhost:${port}${routePath}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-signature-ed25519": sign(timestamp, body),
        "x-signature-timestamp": timestamp,
      },
      body,
    });
  }

  let ok = false;
  try {
    await new Promise<void>((resolve) => server.listen(port, resolve));
    console.log(
      `[smoke] offline bridge up on http://localhost:${port}${routePath}`,
    );

    // (1) A signed PING → 200 {type:1}. This is EXACTLY what Discord sends to
    // validate the Interactions Endpoint URL at save time (portal PING order):
    // the route must answer this before Discord will accept the URL.
    const pingRes = await post(JSON.stringify({ type: 1 }));
    const pingBody = (await pingRes.json()) as { type?: number };
    const pingOk = pingRes.status === 200 && pingBody.type === 1;
    console.log(
      `[smoke] signed PING       -> HTTP ${pingRes.status} {type:${pingBody.type}} ${
        pingOk ? "OK (this is Discord's save-time PING)" : "FAIL"
      }`,
    );

    // (2) A signed APPLICATION_COMMAND → 200 {type:5} synchronous deferred ack,
    // dispatch backgrounded onto waitUntil (the vendor contract this bridge is
    // built on). A bare no-option command exercises the D232 non-empty funnel.
    const token = "smoke-interaction-token";
    const commandBody = JSON.stringify({
      type: 2,
      id: "smoke-1",
      application_id: installKey,
      token,
      channel_id: "chan-smoke",
      guild_id: "guild-smoke",
      data: { id: "cmd-smoke", name: "smoke", type: 1 },
      member: {
        user: { id: "user-smoke", username: "smoker", global_name: "Smoker" },
      },
    });
    const cmdRes = await post(commandBody);
    const cmdBody = (await cmdRes.json()) as { type?: number };
    const cmdOk = cmdRes.status === 200 && cmdBody.type === 5;
    console.log(
      `[smoke] signed COMMAND    -> HTTP ${cmdRes.status} {type:${cmdBody.type}} ${
        cmdOk ? "OK (synchronous deferred ack)" : "FAIL"
      }`,
    );

    // Drain the backgrounded dispatch and confirm the follow-up leg fired
    // (captured, never escaped): the handler's reply PATCHed the interaction.
    await Promise.allSettled(bg);
    const patched = followUps.some(
      (f) => f.startsWith("PATCH ") && f.includes(`/${token}/messages/@original`),
    );
    console.log(
      `[smoke] dispatch drained  -> handler ran=${handlerRan}, follow-up PATCH captured=${patched} ` +
        "(no real egress — discord.com calls were stubbed)",
    );

    // A forged signature MUST be rejected before any handling — the fail-closed
    // half, proven the same way the test does.
    const forgedRes = await realFetch(`http://localhost:${port}${routePath}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-signature-ed25519": "00".repeat(64),
        "x-signature-timestamp": String(Math.floor(Date.now() / 1000)),
      },
      body: commandBody,
    });
    const forgedOk = forgedRes.status === 401;
    await forgedRes.text();
    console.log(
      `[smoke] forged signature  -> HTTP ${forgedRes.status} ${
        forgedOk ? "OK (Ed25519 fail-closed)" : "FAIL"
      }`,
    );

    ok = pingOk && cmdOk && handlerRan && patched && forgedOk;
    console.log(
      ok
        ? "[smoke] PASS — signed interaction verified, acked type-5, dispatched, forgery rejected."
        : "[smoke] FAIL — the offline signed-interaction path did not hold. Do not ship.",
    );
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await chat.shutdown().catch(() => {});
    globalThis.fetch = realFetch;
  }
  return ok;
}

/**
 * THE OPT-IN LIVE LEG. PUT a guild-scoped command to Discord's v10 REST API.
 * Guild scope propagates instantly, so the operator can invoke it immediately.
 * Never called without the full credential triple + guild id.
 */
async function registerGuildCommand(triple: {
  applicationId: string;
  botToken: string;
  guildId: string;
  command: string;
}): Promise<boolean> {
  const url = `${DISCORD_API_BASE}/applications/${triple.applicationId}/guilds/${triple.guildId}/commands`;
  console.log(
    `[smoke] registering guild-scoped /${triple.command} (instant propagation)…`,
  );
  // A bare no-option command (like /status): exercises the D232 funnel where the
  // command NAME itself is the non-empty text the bridge dispatches.
  const body = JSON.stringify([
    {
      name: triple.command,
      description: "Barkpark connectors dev smoke",
      type: 1,
    },
  ]);
  let response: Response;
  try {
    response = await fetch(url, {
      method: "PUT",
      headers: {
        authorization: `Bot ${triple.botToken}`,
        "content-type": "application/json",
      },
      body,
    });
  } catch (err) {
    console.error(
      `[smoke] could not reach Discord: ${err instanceof Error ? err.message : String(err)}`,
    );
    return false;
  }
  const text = await response.text();
  if (!response.ok) {
    console.error(`[smoke] registration FAILED — HTTP ${response.status}`);
    // The body may carry a Discord error message; it never contains our secret.
    console.error(`[smoke] ${text.slice(0, 400)}`);
    if (response.status === 401) {
      console.error(
        "[smoke] 401 => the bot token is wrong/revoked. Reset it in the portal.",
      );
    }
    if (response.status === 403) {
      console.error(
        "[smoke] 403 => the bot is not in that guild, or lacks applications.commands.",
      );
    }
    return false;
  }
  console.log(`[smoke] registered — HTTP ${response.status}. In the dev guild:`);
  console.log(`[smoke]   type /${triple.command} and expect the bot to respond.`);
  console.log("[smoke] cleanup — remove it again with an empty array:");
  console.log(
    `[smoke]   curl -X PUT '${url}' -H 'Authorization: Bot <token>' -H 'Content-Type: application/json' -d '[]'`,
  );
  return true;
}

async function main(): Promise<void> {
  const env = process.env;
  console.log("[smoke] Discord dev-loop — BYO-bot (D41). Offline proof first.");
  console.log("");

  // LEG 1 — always. A hard failure here means the bridge is broken; exit 2.
  const offlineOk = await proveOfflineSignedInteraction();
  console.log("");
  if (!offlineOk) {
    process.exitCode = 2;
    return;
  }

  // LEG 2 — opt-in. Missing any of the four => explicit gate + non-zero exit.
  const missing = REQUIRED.map((r) => r.name).filter((n) => !env[n]?.trim());
  if (missing.length > 0) {
    printGate(missing);
    process.exitCode = 1;
    return;
  }

  const applicationId = (env.DISCORD_APPLICATION_ID as string).trim();
  const botToken = (env.DISCORD_BOT_TOKEN as string).trim();
  const publicKey = (env.DISCORD_PUBLIC_KEY as string).trim();
  const guildId = (env.DISCORD_GUILD_ID as string).trim();
  const command = env.SMOKE_DISCORD_COMMAND?.trim() || "smoke";

  // Validate the credential triple as one shape — WITHOUT printing any secret.
  // parseDiscordCredential throws on any missing/blank field (fail-closed, D41).
  try {
    parseDiscordCredential(JSON.stringify({ applicationId, botToken, publicKey }));
  } catch (err) {
    console.error(
      `[smoke] credential triple rejected: ${err instanceof Error ? err.message : String(err)}`,
    );
    process.exitCode = 1;
    return;
  }
  console.log(
    `[smoke] credential triple OK (app ${applicationId}; token + public key present, not shown).`,
  );

  const registered = await registerGuildCommand({
    applicationId,
    botToken,
    guildId,
    command,
  });
  process.exitCode = registered ? 0 : 1;
}

main().catch((err) => {
  console.error("[smoke] fatal:", err);
  process.exit(1);
});
