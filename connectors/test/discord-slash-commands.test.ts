/**
 * Discord slash commands — the Ed25519-signed HTTP interactions transport (D228)
 * and the `chat.onSlashCommand` handler registration (D229/D232), proven offline
 * with a node:crypto Ed25519 test keypair.
 *
 * THE REFRAME (charter W27 survey, D228): slash commands are WIRING + PROOF, not
 * new protocol code. The vendor `DiscordAdapter.handleWebhook` already ships the
 * ENTIRE interaction protocol — raw-body Ed25519 verify, PING→PONG, the
 * synchronous type-5 deferred ack, and `waitUntil`-backgrounded dispatch. This
 * suite drives that seam with a signed request and proves the registered handler
 * fires and its reply reaches the interaction follow-up.
 *
 * Four vendor-contract laws (charter D229) are each exercised:
 *   (1) drive chat.webhooks.discord(request,{waitUntil}) — NOT adapter.handleWebhook.
 *   (2) reply targets event.channel.id (channel.post routes to the interaction token).
 *   (3) dispatch stays inside the vendor's requestContext.run (ALS) — via waitUntil.
 *   (4) offline tests MUST stub globalThis.fetch (follow-up = bare global fetch +
 *       hardcoded DISCORD_API_BASE; no options.fetch seam reaches it).
 *
 * The harness handler funnels EXACTLY as `mountInstall` (connectors/src/index.ts)
 * does — `${event.command} ${event.text}`.trim()` — so the D232 command-prefix
 * case below discriminates the real wiring: a bare no-option command has
 * event.text === "" and would silently no-op under event.text-only wiring
 * (core/dispatch.ts drops empty text as dropped_empty_input).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { generateKeyPairSync, sign as edSign } from "node:crypto";
import { Chat, type ModalElement, type SlashCommandEvent } from "chat";
import { createDiscordAdapter } from "@chat-adapter/discord";
import { createMemoryState } from "@chat-adapter/state-memory";

import {
  decodeDiscordModalCustomId,
  extendDiscordInteractionWebhook,
} from "../src/connectors/discord.js";

const APP_ID = "111111111111111111";

// ── Ed25519 test keypair (node:crypto, ZERO new dep) ────────────────────────
// The adapter's verifyKey wants the RAW 32-byte public key, hex-encoded.
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const publicKeyHex = Buffer.from(
  publicKey.export({ format: "jwk" }).x as string,
  "base64url",
).toString("hex");
// Sanity: the jwk.x route and the spki-last-32 route agree (Paper w28-121).
const spkiHex = Buffer.from(
  publicKey.export({ type: "spki", format: "der" }).subarray(-32),
).toString("hex");

// Discord signs the concatenation `timestamp + body`; Ed25519 sig, hex-encoded.
function sign(timestamp: string, body: string): string {
  return edSign(null, Buffer.from(timestamp + body, "utf8"), privateKey).toString(
    "hex",
  );
}

function makeRequest(body: string, opts: { signed: boolean; headers?: boolean }) {
  const timestamp = String(Math.floor(Date.now() / 1000));
  const headers = new Headers({ "content-type": "application/json" });
  if (opts.headers !== false) {
    headers.set(
      "x-signature-ed25519",
      opts.signed ? sign(timestamp, body) : "00".repeat(64),
    );
    headers.set("x-signature-timestamp", timestamp);
  }
  return new Request(`https://bridge.local/connectors/webhooks/discord/${APP_ID}`, {
    method: "POST",
    headers,
    body,
  });
}

// A fresh harness per test: one adapter, one Chat, ONE registered handler whose
// reply closure is channel-shaped (knows nothing about interaction tokens).
interface Harness {
  chat: InstanceType<typeof Chat>;
  adapter: ReturnType<typeof createDiscordAdapter>;
  // RULE 1: drive chat.webhooks[provider], NEVER adapter.handleWebhook. The
  // vendor types webhooks[k] as possibly-undefined (index type) so the cast
  // lives here, once.
  webhook: (
    req: Request,
    opts: { waitUntil: (p: Promise<unknown>) => void },
  ) => Promise<Response>;
  // handleGatewayInteraction is a PROTECTED method — legal at runtime (JS) but
  // tsc rejects an external call, so the cast lives here too.
  gateway: (fixture: unknown) => Promise<void>;
  captured: { method: string; url: string; body?: string }[];
  entered: string[];
  completed: string[];
  events: { command: string; text: string; channelId: string | undefined }[];
  // The exact text `mountInstall` would funnel into dispatchInbound — computed
  // here with the IDENTICAL `${event.command} ${event.text}`.trim()` transform
  // the src uses, so the D232 case proves the funnel is non-empty for a bare
  // no-option command (event.text-only wiring would push "" and be dropped).
  dispatched: string[];
  setGate: (p: Promise<void>) => void;
  // W30 component/modal recorders — the harness mirrors mountInstall's 5th/6th
  // wrappers, while the type-5 intercept itself is the REAL src seam
  // (extendDiscordInteractionWebhook, applied below).
  actions: { actionId: string; value: string | undefined; threadId: string }[];
  actionDispatched: string[];
  modals: {
    callbackId: string;
    values: Record<string, string>;
    relatedChannelId: string | undefined;
  }[];
  modalDispatched: string[];
  // Per-test slash-handler hook (e.g. call event.openModal); default no-op.
  setSlashHook: (fn: (event: SlashCommandEvent) => Promise<void>) => void;
}

let harness: Harness;

function makeHarness(opts: { withInteractionHandlers?: boolean } = {}): Harness {
  const withInteractionHandlers = opts.withInteractionHandlers ?? true;
  const captured: { method: string; url: string; body?: string }[] = [];
  const entered: string[] = [];
  const completed: string[] = [];
  const events: { command: string; text: string; channelId: string | undefined }[] =
    [];
  const dispatched: string[] = [];
  const actions: {
    actionId: string;
    value: string | undefined;
    threadId: string;
  }[] = [];
  const actionDispatched: string[] = [];
  const modals: {
    callbackId: string;
    values: Record<string, string>;
    relatedChannelId: string | undefined;
  }[] = [];
  const modalDispatched: string[] = [];
  let gate: Promise<void> = Promise.resolve();
  let slashHook: ((event: SlashCommandEvent) => Promise<void>) | undefined;

  // LAW 4: stub the GLOBAL fetch — the interaction follow-up uses a bare global
  // fetch + hardcoded DISCORD_API_BASE, so options.fetch would silently miss it.
  vi.stubGlobal("fetch", async (url: unknown, init: RequestInit = {}) => {
    captured.push({
      method: (init.method ?? "GET") as string,
      url: String(url),
      ...(typeof init.body === "string" ? { body: init.body } : {}),
    });
    return new Response(JSON.stringify({ id: "resp-msg-id" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  });

  const adapter = createDiscordAdapter({
    applicationId: APP_ID,
    botToken: "test-bot-token",
    publicKey: publicKeyHex,
  });
  const chat = new Chat({
    userName: "w28bot",
    adapters: { discord: adapter },
    state: createMemoryState(),
  });

  // LAW 2: reply via event.channel.post — the adapter routes it to the
  // interaction follow-up (PATCH .../messages/@original) via AsyncLocalStorage.
  chat.onSlashCommand(async (event) => {
    events.push({
      command: event.command,
      text: event.text,
      channelId: event.channel?.id,
    });
    // D232: mirror mountInstall's funnel VERBATIM. A bare no-option command has
    // event.text === "" — only the command-prefixed form survives dispatch.
    dispatched.push(`${event.command} ${event.text}`.trim());
    entered.push(event.command);
    if (slashHook) await slashHook(event);
    await gate;
    await event.channel.post(`handled ${event.command}`);
    completed.push(event.command);
  });

  if (withInteractionHandlers) {
    // W30 5th wrapper mirror: component actions. Same funnel transform as
    // mountInstall — actionId always non-empty, value only when it adds info.
    chat.onAction(async (event) => {
      actions.push({
        actionId: event.actionId,
        value: event.value,
        threadId: event.threadId,
      });
      const detail =
        event.value && event.value !== event.actionId ? event.value : "";
      actionDispatched.push(`${event.actionId} ${detail}`.trim());
      await event.thread?.post(`acted ${event.actionId}`);
    });

    // W30 6th wrapper mirror: modal submits reply via the RELATED channel.
    chat.onModalSubmit(async (event) => {
      modals.push({
        callbackId: event.callbackId,
        values: event.values,
        relatedChannelId: event.relatedChannel?.id,
      });
      modalDispatched.push(
        `${event.callbackId} ${JSON.stringify(event.values)}`.trim(),
      );
      await event.relatedChannel?.post(`modal ${event.callbackId}`);
    });
  }

  // THE REAL SRC SEAM under test (not a mirror): the type-5 MODAL_SUBMIT
  // intercept + onOpenModal injection, wrapping chat.webhooks.discord in place
  // exactly as mountInstall does.
  extendDiscordInteractionWebhook(chat, adapter);

  return {
    chat,
    adapter,
    webhook: (req, opts) =>
      (chat.webhooks.discord as (r: Request, o: typeof opts) => Promise<Response>)(
        req,
        opts,
      ),
    gateway: (fixture) =>
      (
        adapter as unknown as {
          handleGatewayInteraction: (f: unknown) => Promise<void>;
        }
      ).handleGatewayInteraction(fixture),
    captured,
    entered,
    completed,
    events,
    dispatched,
    setGate: (p) => (gate = p),
    actions,
    actionDispatched,
    modals,
    modalDispatched,
    setSlashHook: (fn) => (slashHook = fn),
  };
}

async function waitFor(cond: () => boolean, ms = 2000): Promise<void> {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > ms) throw new Error("waitFor timed out");
    await new Promise((r) => setTimeout(r, 5));
  }
}

beforeEach(() => {
  harness = makeHarness();
});

afterEach(async () => {
  await harness.chat.shutdown().catch(() => {});
  vi.unstubAllGlobals();
});

describe("Discord slash commands — Ed25519 webhook + onSlashCommand funnel", () => {
  it("keypair: jwk.x and spki-last-32 yield the same raw 32-byte public key", () => {
    expect(publicKeyHex).toHaveLength(64);
    expect(publicKeyHex).toBe(spkiHex);
  });

  it("(b) signed PING → 200 {type:1}", async () => {
    const req = makeRequest(JSON.stringify({ type: 1 }), { signed: true });
    const res = await harness.webhook(req, { waitUntil: () => {} });
    expect(res.status).toBe(200);
    expect(((await res.clone().json()) as { type: number }).type).toBe(1);
  });

  it("(a) forged/unsigned interaction → 401, handler NEVER fires; 401 isolates verify not routing", async () => {
    const body = JSON.stringify({
      type: 2,
      id: "9",
      application_id: APP_ID,
      token: "tok",
      channel_id: "c1",
      data: { name: "ping" },
      member: { user: { id: "u1", username: "u" } },
    });

    // A SIGNED PING to the SAME live seam returns 200 → the route resolves.
    const ok = await harness.webhook(
      makeRequest(JSON.stringify({ type: 1 }), { signed: true }),
      {
        waitUntil: () => {},
      },
    );
    expect(ok.status).toBe(200);

    // Forged signature → 401 (crypto rejection, not a 404 missing route).
    const forged = await harness.webhook(makeRequest(body, { signed: false }), {
      waitUntil: () => {},
    });
    expect(forged.status).toBe(401);

    // Unsigned (no signature headers at all) to the same seam → also 401.
    const unsigned = await harness.webhook(
      makeRequest(body, { signed: false, headers: false }),
      {
        waitUntil: () => {},
      },
    );
    expect(unsigned.status).toBe(401);

    expect(harness.entered).toHaveLength(0);
    expect(harness.completed).toHaveLength(0);
    expect(harness.captured).toHaveLength(0);
  });

  it("(c) signed APPLICATION_COMMAND → sync 200 {type:5}; dispatch UNRESOLVED at ack, rides waitUntil; drain → PATCH @original", async () => {
    const token = "interaction-token-webhook";
    const body = JSON.stringify({
      type: 2,
      id: "10",
      application_id: APP_ID,
      token,
      channel_id: "chan-1",
      guild_id: "guild-1",
      data: {
        id: "cmd1",
        name: "ask",
        type: 1,
        options: [{ name: "q", type: 3, value: "hi" }],
      },
      member: { user: { id: "user-1", username: "alice", global_name: "Alice" } },
    });

    // Hold the handler pending so we can prove the ack precedes dispatch.
    let release!: () => void;
    harness.setGate(new Promise<void>((r) => (release = r)));

    const bg: Promise<unknown>[] = [];
    const res = await harness.webhook(makeRequest(body, { signed: true }), {
      waitUntil: (p: Promise<unknown>) => bg.push(p),
    });

    // Synchronous deferred ack.
    expect(res.status).toBe(200);
    expect(((await res.clone().json()) as { type: number }).type).toBe(5);
    // Dispatch did NOT complete before the ack returned…
    expect(harness.completed).toHaveLength(0);
    // …and it was backgrounded onto waitUntil (LAW 3), not run inline.
    expect(bg.length).toBeGreaterThan(0);
    // No follow-up PATCH could have happened yet.
    expect(
      harness.captured.filter((c) => c.url.includes("/messages/@original")),
    ).toHaveLength(0);

    // Release the handler and drain the backgrounded dispatch.
    release();
    await Promise.allSettled(bg);
    await waitFor(() => harness.completed.length === 1);

    // VENDOR TRUTHS (each a silent-failure trap the src wiring must respect):
    //  1. event.command is SLASH-PREFIXED ("/ask", not "ask").
    //  2. event.text carries ONLY the option values (NOT the command name) —
    //     "/ask hi" → text:"hi".
    //  3. event.channel.id is the vendor's NAMESPACED id "discord:{guild}:{chan}",
    //     NOT the raw Discord channel_id — passed VERBATIM to the reply closure.
    expect(harness.entered).toEqual(["/ask"]);
    expect(harness.events[0]).toMatchObject({
      command: "/ask",
      text: "hi",
      channelId: "discord:guild-1:chan-1",
    });
    // The funnel keeps the command AND the option values.
    expect(harness.dispatched).toEqual(["/ask hi"]);
    const patch = harness.captured.find(
      (c) =>
        c.method === "PATCH" &&
        c.url.includes(`/webhooks/${APP_ID}/${token}/messages/@original`),
    );
    expect(patch, JSON.stringify(harness.captured)).toBeTruthy();
  });

  it("(d) Gateway-shaped interaction drives the SAME handler and PATCHes its OWN token", async () => {
    await harness.chat.initialize();
    const token = "interaction-token-gateway";
    let deferReplyCalled = false;
    const gwFixture: Record<string, unknown> = {
      applicationId: APP_ID,
      id: "gw-interaction-id",
      token,
      type: 2,
      version: 1,
      commandType: 1,
      commandName: "ask",
      channelId: "chan-gw-456",
      guildId: "guild-gw-888",
      options: { data: [] },
      channel: { id: "chan-gw-456", type: 0 },
      user: {
        id: "user-gw-2",
        username: "bob",
        discriminator: "0",
        globalName: "Bob",
        bot: false,
        avatar: null,
      },
      isChatInputCommand: () => true,
      isMessageComponent: () => false,
      deferReply: async () => {
        deferReplyCalled = true;
      },
    };

    await harness.gateway(gwFixture);
    await waitFor(() => harness.completed.length === 1);

    expect(deferReplyCalled).toBe(true);
    expect(harness.entered).toEqual(["/ask"]);
    // SAME registry, DIFFERENT (own) interaction token.
    const patch = harness.captured.find(
      (c) =>
        c.method === "PATCH" &&
        c.url.includes(`/webhooks/${APP_ID}/${token}/messages/@original`),
    );
    expect(patch, JSON.stringify(harness.captured)).toBeTruthy();
  });

  it("(e) D232: a bare no-option command (/status) reaches the handler and funnels NON-EMPTY command-prefixed text", async () => {
    const token = "interaction-token-status";
    // NO `options` key at all — the shape Discord sends for a no-argument command.
    const body = JSON.stringify({
      type: 2,
      id: "11",
      application_id: APP_ID,
      token,
      channel_id: "chan-9",
      guild_id: "guild-9",
      data: { id: "cmd-status", name: "status", type: 1 },
      member: { user: { id: "user-3", username: "carol", global_name: "Carol" } },
    });

    const bg: Promise<unknown>[] = [];
    const res = await harness.webhook(makeRequest(body, { signed: true }), {
      waitUntil: (p: Promise<unknown>) => bg.push(p),
    });
    expect(res.status).toBe(200);
    expect(((await res.clone().json()) as { type: number }).type).toBe(5);

    await Promise.allSettled(bg);
    await waitFor(() => harness.completed.length === 1);

    // THE D232 TRAP, asserted both ways:
    //  - the vendor delivers event.text === "" for a no-option command, so
    //    event.text-only wiring would dispatch "" and core/dispatch.ts would drop
    //    it as dropped_empty_input BEFORE tenant resolution (a silent no-op that
    //    the user sees as "The application did not respond" after the 15-min TTL);
    expect(harness.events[0]).toMatchObject({ command: "/status", text: "" });
    //  - the command-prefix funnel keeps the verb: NON-EMPTY "/status".
    expect(harness.dispatched).toEqual(["/status"]);
    expect(harness.dispatched[0]).not.toBe("");

    const patch = harness.captured.find(
      (c) =>
        c.method === "PATCH" &&
        c.url.includes(`/webhooks/${APP_ID}/${token}/messages/@original`),
    );
    expect(patch, JSON.stringify(harness.captured)).toBeTruthy();
  });
});

describe("Discord component + modal interactions — W30 (stop acked-then-dropped)", () => {
  function componentBody(customId: string, extra: Record<string, unknown> = {}) {
    return JSON.stringify({
      type: 3,
      id: "30",
      application_id: APP_ID,
      token: "interaction-token-component",
      channel_id: "chan-1",
      guild_id: "guild-1",
      message: { id: "msg-77" },
      data: { custom_id: customId, component_type: 2 },
      member: { user: { id: "user-5", username: "dana", global_name: "Dana" } },
      ...extra,
    });
  }

  it("(f) CONTROL: with ZERO registered handlers a signed MESSAGE_COMPONENT is still acked type-6 — the ack is NOT proof of handling", async () => {
    // A second, handler-less harness — the pre-W30 bridge state. Its fetch stub
    // supersedes the default harness's (unstubAllGlobals clears both).
    const bare = makeHarness({ withInteractionHandlers: false });
    try {
      const bg: Promise<unknown>[] = [];
      const res = await bare.webhook(
        makeRequest(componentBody("approve"), { signed: true }),
        { waitUntil: (p) => bg.push(p) },
      );
      await Promise.allSettled(bg);

      expect(res.status).toBe(200);
      expect(((await res.clone().json()) as { type: number }).type).toBe(6);
      // Verified, acked … and dropped. THIS is the defect the wrappers close.
      expect(bare.actions).toHaveLength(0);
    } finally {
      await bare.chat.shutdown().catch(() => {});
    }
  });

  it("(g) signed MESSAGE_COMPONENT → sync 200 {type:6} AND the registered onAction handler FIRES (invocation asserted, not the ack)", async () => {
    const bg: Promise<unknown>[] = [];
    const res = await harness.webhook(
      makeRequest(componentBody("approve"), { signed: true }),
      { waitUntil: (p) => bg.push(p) },
    );

    // The vendor acks synchronously with a type-6 deferred update.
    expect(res.status).toBe(200);
    expect(((await res.clone().json()) as { type: number }).type).toBe(6);

    await Promise.allSettled(bg);
    await waitFor(() => harness.actions.length === 1);

    // VENDOR TRUTHS: a plain button's value defaults to its actionId, and the
    // threadId is the NAMESPACED "discord:{guild}:{chan}" id.
    expect(harness.actions[0]).toEqual({
      actionId: "approve",
      value: "approve",
      threadId: "discord:guild-1:chan-1",
    });
    // The funnel is NON-EMPTY (never dropped_empty_input) and does not stutter
    // the defaulted value.
    expect(harness.actionDispatched).toEqual(["approve"]);
    expect(harness.entered).toHaveLength(0); // no slash handler involved
  });

  it("(g2) a select value rides the funnel when it differs from the actionId", async () => {
    const bg: Promise<unknown>[] = [];
    await harness.webhook(
      makeRequest(
        componentBody("pick-env", {
          data: {
            custom_id: "pick-env",
            component_type: 3,
            values: ["staging"],
          },
        }),
        { signed: true },
      ),
      { waitUntil: (p) => bg.push(p) },
    );
    await Promise.allSettled(bg);
    await waitFor(() => harness.actions.length === 1);

    expect(harness.actions[0]).toMatchObject({
      actionId: "pick-env",
      value: "staging",
    });
    expect(harness.actionDispatched).toEqual(["pick-env staging"]);
  });

  it("(h) modal round-trip: openModal from a slash handler → type-9 callback POST; signed MODAL_SUBMIT → routed to onModalSubmit with its fields; reply PATCHes the SUBMIT's own token", async () => {
    // STEP 1 — a slash handler opens a modal.
    let openResult: { viewId: string } | undefined;
    harness.setSlashHook(async (event) => {
      const modal: ModalElement = {
        type: "modal",
        callbackId: "feedback-modal",
        title: "Feedback",
        children: [{ type: "text_input", id: "note", label: "Your note" }],
      };
      openResult = await event.openModal(modal);
    });

    const commandToken = "interaction-token-open";
    const bg: Promise<unknown>[] = [];
    const commandRes = await harness.webhook(
      makeRequest(
        JSON.stringify({
          type: 2,
          id: "31",
          application_id: APP_ID,
          token: commandToken,
          channel_id: "chan-1",
          guild_id: "guild-1",
          data: { id: "cmd-feedback", name: "feedback", type: 1 },
          member: {
            user: { id: "user-6", username: "erik", global_name: "Erik" },
          },
        }),
        { signed: true },
      ),
      { waitUntil: (p) => bg.push(p) },
    );
    expect(commandRes.status).toBe(200);
    await Promise.allSettled(bg);
    await waitFor(() => harness.completed.length === 1);

    // The openModal seam POSTed a REAL type-9 modal to the interaction
    // callback endpoint (offline the stub answers 200; live, the vendor's
    // auto-ack wins the race and Discord would answer 40060 — see the W30
    // seam note in discord.ts).
    const modalPost = harness.captured.find(
      (c) =>
        c.method === "POST" &&
        c.url.includes(`/interactions/31/${commandToken}/callback`),
    );
    expect(modalPost, JSON.stringify(harness.captured)).toBeTruthy();
    const posted = JSON.parse(modalPost?.body ?? "{}") as {
      type: number;
      data: { custom_id: string; title: string; components: unknown[] };
    };
    expect(posted.type).toBe(9);
    expect(posted.data.title).toBe("Feedback");
    expect(posted.data.components).toHaveLength(1);
    expect(openResult).toEqual({ viewId: posted.data.custom_id });

    // The custom_id round-trips callbackId + contextId (the stored modal
    // context that will restore relatedChannel on submit).
    const decoded = decodeDiscordModalCustomId(posted.data.custom_id);
    expect(decoded.callbackId).toBe("feedback-modal");
    expect(decoded.contextId).toBeTruthy();

    // STEP 2 — the user submits: a NEW signed type-5 interaction carrying the
    // modal's custom_id and the filled fields. Pre-W30 this answered 400.
    const submitToken = "interaction-token-submit";
    const bg2: Promise<unknown>[] = [];
    const submitRes = await harness.webhook(
      makeRequest(
        JSON.stringify({
          type: 5,
          id: "32",
          application_id: APP_ID,
          token: submitToken,
          channel_id: "chan-1",
          guild_id: "guild-1",
          data: {
            custom_id: posted.data.custom_id,
            components: [
              {
                type: 1,
                components: [{ type: 4, custom_id: "note", value: "love it" }],
              },
            ],
          },
          member: {
            user: { id: "user-6", username: "erik", global_name: "Erik" },
          },
        }),
        { signed: true },
      ),
      { waitUntil: (p) => bg2.push(p) },
    );

    // Deferred ack, no more 400.
    expect(submitRes.status).toBe(200);
    expect(((await submitRes.clone().json()) as { type: number }).type).toBe(5);

    await Promise.allSettled(bg2);
    await waitFor(() => harness.modals.length === 1);

    // Routed WITH its fields, and the stored context restored the channel the
    // modal was opened from.
    expect(harness.modals[0]).toEqual({
      callbackId: "feedback-modal",
      values: { note: "love it" },
      relatedChannelId: "discord:guild-1:chan-1",
    });
    expect(harness.modalDispatched).toEqual([
      `feedback-modal ${JSON.stringify({ note: "love it" })}`,
    ]);

    // The handler's relatedChannel.post ran inside the ALS store the intercept
    // set up, so the reply PATCHes the SUBMIT interaction's OWN token — the
    // deferred ack never dangles as "did not respond".
    const patch = harness.captured.find(
      (c) =>
        c.method === "PATCH" &&
        c.url.includes(`/webhooks/${APP_ID}/${submitToken}/messages/@original`),
    );
    expect(patch, JSON.stringify(harness.captured)).toBeTruthy();
  });

  it("(i) forged/unsigned MODAL_SUBMIT → 401, the intercept NEVER dispatches (Ed25519 stays in front)", async () => {
    const body = JSON.stringify({
      type: 5,
      id: "33",
      application_id: APP_ID,
      token: "tok-forged",
      channel_id: "chan-1",
      guild_id: "guild-1",
      data: {
        custom_id: "feedback-modal",
        components: [
          { type: 1, components: [{ type: 4, custom_id: "note", value: "x" }] },
        ],
      },
      member: { user: { id: "u", username: "u" } },
    });

    const forged = await harness.webhook(makeRequest(body, { signed: false }), {
      waitUntil: () => {},
    });
    expect(forged.status).toBe(401);

    const unsigned = await harness.webhook(
      makeRequest(body, { signed: false, headers: false }),
      { waitUntil: () => {} },
    );
    expect(unsigned.status).toBe(401);

    expect(harness.modals).toHaveLength(0);
    expect(harness.captured).toHaveLength(0);
  });

  it("(j) a signed MODAL_SUBMIT with a FOREIGN custom_id still routes (whole id becomes the callbackId, no restored context)", async () => {
    const bg: Promise<unknown>[] = [];
    const res = await harness.webhook(
      makeRequest(
        JSON.stringify({
          type: 5,
          id: "34",
          application_id: APP_ID,
          token: "tok-foreign",
          channel_id: "chan-2",
          guild_id: "guild-1",
          data: {
            custom_id: "legacy-modal",
            components: [
              { type: 1, components: [{ type: 4, custom_id: "a", value: "b" }] },
            ],
          },
          member: { user: { id: "user-7", username: "fay" } },
        }),
        { signed: true },
      ),
      { waitUntil: (p) => bg.push(p) },
    );
    expect(res.status).toBe(200);
    await Promise.allSettled(bg);
    await waitFor(() => harness.modals.length === 1);

    expect(harness.modals[0]).toEqual({
      callbackId: "legacy-modal",
      values: { a: "b" },
      relatedChannelId: undefined, // no stored context — honest degradation
    });
  });
});
