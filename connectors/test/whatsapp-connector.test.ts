import { createMemoryState } from "@chat-adapter/state-memory";
import { Chat } from "chat";
import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";

import { createConnectorRegistry } from "../src/connector/registry.js";
import type { ConnectorInstall } from "../src/connector/types.js";
import {
  createWhatsappConnector,
  encodeWhatsappCredential,
  parseWhatsappCredential,
  whatsappInboundTimestampMs,
  whatsappInstallKey,
  whatsappPayloadMatchesInstall,
  WHATSAPP_PROVIDER,
} from "../src/connectors/whatsapp.js";
import { createInMemoryInstallsLookup } from "../src/tenant/installs.js";
import { resolveTenantForEvent } from "../src/tenant/resolve.js";

/**
 * WhatsApp (charter D43). Proven here, with NO live number and no Meta account:
 *
 *   1. The GET verification handshake through the seam: matching verifyToken -> 200 with
 *      the challenge echoed; wrong token -> 403.
 *   2. POST with a bad HMAC -> 401.
 *   3. CROSS-TENANT (the mandatory negative): a body signed with install A's App Secret
 *      is REJECTED by install B's adapter. Two tenants, two Meta apps, no leak.
 *   4. The install key is the phone_number_id, read by ONE function from either the raw
 *      Meta body or the SDK message.
 *
 * The Meta Graph base URL is pointed at a dead local port in every test: the adapter
 * fetches its business profile on initialize, and a unit test must never depend on
 * (or touch) graph.facebook.com.
 */

const DEAD_GRAPH = "http://127.0.0.1:1";

const PHONE_A = "111111111111111";
const PHONE_B = "222222222222222";
const SECRET_A = "app-secret-alpha";
const SECRET_B = "app-secret-beta";
const VERIFY_A = "verify-token-alpha";
const VERIFY_B = "verify-token-beta";

const installA: ConnectorInstall = {
  provider: WHATSAPP_PROVIDER,
  installKey: PHONE_A,
  workspaceId: "ws-alpha",
  credentialRef: encodeWhatsappCredential({
    accessToken: "system-user-token-alpha",
    appSecret: SECRET_A,
    verifyToken: VERIFY_A,
  }),
};
const installB: ConnectorInstall = {
  provider: WHATSAPP_PROVIDER,
  installKey: PHONE_B,
  workspaceId: "ws-beta",
  credentialRef: encodeWhatsappCredential({
    accessToken: "system-user-token-beta",
    appSecret: SECRET_B,
    verifyToken: VERIFY_B,
  }),
};

const installs = createInMemoryInstallsLookup([installA, installB]);

/** A Meta webhook body, exactly as the Cloud API posts it. */
function webhookBody(phoneNumberId: string, text = "hei"): string {
  return JSON.stringify({
    object: "whatsapp_business_account",
    entry: [
      {
        id: "waba-id",
        changes: [
          {
            field: "messages",
            value: {
              messaging_product: "whatsapp",
              metadata: {
                display_phone_number: "4712345678",
                phone_number_id: phoneNumberId,
              },
              contacts: [{ profile: { name: "Pelle" }, wa_id: "4799999999" }],
              messages: [
                {
                  from: "4799999999",
                  id: "wamid.TEST",
                  timestamp: "1752451200",
                  type: "text",
                  text: { body: text },
                },
              ],
            },
          },
        ],
      },
    ],
  });
}

function sign(secret: string, body: string): string {
  return "sha256=" + createHmac("sha256", secret).update(body).digest("hex");
}

/**
 * Mount one install exactly as the bridge does, plus a `settled()` that drains the
 * SDK's background message handling.
 *
 * The webhook responds BEFORE the message is processed (that is the point of
 * `waitUntil`). Without draining it, `shutdown()` disconnects the state adapter out from
 * under the in-flight handler — and the test would be asserting on a status code while
 * the thing it claims to prove was still running. Draining also lets the cross-tenant
 * test assert on the HANDLER, not merely on the status line.
 */
function mount(install: ConnectorInstall) {
  const connector = createWhatsappConnector({ apiUrl: DEAD_GRAPH });
  const adapter = connector.adapterFactory(install);
  const chat = new Chat({
    userName: "barkpark",
    adapters: { [WHATSAPP_PROVIDER]: adapter },
    state: createMemoryState(),
  });

  const background: Promise<unknown>[] = [];
  return {
    chat,
    waitUntil: (task: Promise<unknown>) => {
      background.push(task);
    },
    settled: async () => {
      await Promise.allSettled(background);
    },
  };
}

describe("whatsapp connector — registration shape (D43)", () => {
  it("declares credential-bound routing with a PATH install key", () => {
    const connector = createWhatsappConnector();

    expect(connector.id).toBe("whatsapp");
    expect(connector.direction).toBe("channel");
    expect(connector.auth).toBe("signing-secret");
    // BYO Meta app: all four credentials are per-install, so the inbound path IS the
    // tenant binding — exactly like Telegram, and unlike Teams.
    expect(connector.tenantResolution).toBe("credential-bound");
    // The body cannot be allowed to choose the secret that verifies the body.
    expect(connector.webhook.keySource).toBe("path");
    // GET is the Meta verification handshake. Without it, the webhook can never be
    // registered at all — which is why the seam must allow GET.
    expect(connector.webhook.allowedMethods).toEqual(["GET", "POST"]);
    expect(connector.listen).toBeUndefined();
  });

  it("registers as one ordinary channel entry", () => {
    const registry = createConnectorRegistry();
    registry.register(createWhatsappConnector());

    expect(registry.channels().map((c) => c.id)).toEqual([WHATSAPP_PROVIDER]);
  });

  it("refuses to mount an install with no credential — never falls back to WHATSAPP_* env", () => {
    const connector = createWhatsappConnector();
    const credentialless: ConnectorInstall = {
      provider: WHATSAPP_PROVIDER,
      installKey: PHONE_A,
      workspaceId: "ws-alpha",
      credentialRef: null,
    };

    // Teams tolerates a NULL credential (one operator app). WhatsApp must NOT: the SDK
    // would silently default to the operator's WHATSAPP_* env vars, i.e. send one
    // workspace's messages from another's number.
    expect(() => connector.adapterFactory(credentialless)).toThrow(
      /no credential_ref/,
    );
    expect(() => parseWhatsappCredential('{"appSecret":"x"}')).toThrow(
      /accessToken/,
    );
    expect(() => parseWhatsappCredential("not json")).toThrow(/valid JSON/);
  });
});

describe("whatsapp install key — the phone_number_id, read once", () => {
  it("reads it from the raw Meta webhook body", () => {
    expect(whatsappInstallKey(JSON.parse(webhookBody(PHONE_A)))).toBe(PHONE_A);
  });

  it("reads it from the SDK message's raw WhatsAppRawMessage", () => {
    expect(
      whatsappInstallKey({ text: "hei", raw: { phoneNumberId: PHONE_B } }),
    ).toBe(PHONE_B);
  });

  it("fails closed on an unreadable body", () => {
    expect(whatsappInstallKey(undefined)).toBeNull();
    expect(whatsappInstallKey({ entry: [] })).toBeNull();
    expect(
      whatsappInstallKey({ entry: [{ changes: [{ value: {} }] }] }),
    ).toBeNull();
  });

  it("cross-checks the path key against the body, and drops a mismatch", () => {
    const body = JSON.parse(webhookBody(PHONE_A));

    expect(whatsappPayloadMatchesInstall(PHONE_A, body)).toBe(true);
    // A body replayed onto another install's path: routed as B, carries A. Drop it.
    expect(whatsappPayloadMatchesInstall(PHONE_B, body)).toBe(false);
    // An unreadable body cannot be asserted to match — so it does not.
    expect(whatsappPayloadMatchesInstall(PHONE_A, {})).toBe(false);
  });

  it("converts the inbound unix-SECONDS timestamp to epoch ms for the window policy", () => {
    // 1752451200s. Reading the string as ms would put the window ~55 years in the past
    // and close it forever; reading ms as seconds would open it for ~55 years.
    expect(whatsappInboundTimestampMs(JSON.parse(webhookBody(PHONE_A)))).toBe(
      1752451200000,
    );
    expect(
      whatsappInboundTimestampMs({ raw: { message: { timestamp: "1752451200" } } }),
    ).toBe(1752451200000);
    expect(whatsappInboundTimestampMs({})).toBeNull();
  });
});

describe("whatsapp tenant routing — credential-bound, fail closed", () => {
  const registry = createConnectorRegistry();
  registry.register(createWhatsappConnector());
  const ctx = { installs };

  it("routes each phone_number_id to ITS OWN workspace", async () => {
    await expect(
      resolveTenantForEvent(
        {
          provider: WHATSAPP_PROVIDER,
          threadId: `whatsapp:${PHONE_A}:4799999999`,
          text: "hei",
          installKey: PHONE_A,
        },
        ctx,
        registry,
      ),
    ).resolves.toBe("ws-alpha");

    await expect(
      resolveTenantForEvent(
        {
          provider: WHATSAPP_PROVIDER,
          threadId: `whatsapp:${PHONE_B}:4799999999`,
          text: "hei",
          installKey: PHONE_B,
        },
        ctx,
        registry,
      ),
    ).resolves.toBe("ws-beta");
  });

  it("drops an event whose install key is unknown or missing", async () => {
    await expect(
      resolveTenantForEvent(
        {
          provider: WHATSAPP_PROVIDER,
          threadId: "whatsapp:999:4799999999",
          text: "hei",
          installKey: "999999999999999",
        },
        ctx,
        registry,
      ),
    ).resolves.toBeNull();

    await expect(
      resolveTenantForEvent(
        { provider: WHATSAPP_PROVIDER, threadId: "whatsapp::x", text: "hei" },
        ctx,
        registry,
      ),
    ).resolves.toBeNull();
  });
});

describe("whatsapp webhook — the GET handshake and the HMAC gate", () => {
  it("answers the Meta verification challenge with 200 + the challenge, for the RIGHT token", async () => {
    const { chat, settled } = mount(installA);

    const response = await chat.webhooks.whatsapp(
      new Request(
        `https://bridge.example/connectors/webhooks/whatsapp/${PHONE_A}` +
          `?hub.mode=subscribe&hub.verify_token=${VERIFY_A}&hub.challenge=CHALLENGE-9f2`,
      ),
    );

    expect(response.status).toBe(200);
    // Meta requires the challenge echoed VERBATIM as the body, or the webhook never
    // registers. This is the whole reason the seam must allow GET.
    expect(await response.text()).toBe("CHALLENGE-9f2");

    await settled();
    await chat.shutdown();
  });

  it("refuses the challenge for a WRONG verify token (403)", async () => {
    const { chat, settled } = mount(installA);

    const response = await chat.webhooks.whatsapp(
      new Request(
        `https://bridge.example/connectors/webhooks/whatsapp/${PHONE_A}` +
          `?hub.mode=subscribe&hub.verify_token=${VERIFY_B}&hub.challenge=CHALLENGE-9f2`,
      ),
    );

    expect(response.status).toBe(403);
    await settled();
    await chat.shutdown();
  });

  it("rejects a POST with a bad HMAC (401)", async () => {
    const { chat, settled } = mount(installA);
    const body = webhookBody(PHONE_A);

    const response = await chat.webhooks.whatsapp(
      new Request(
        `https://bridge.example/connectors/webhooks/whatsapp/${PHONE_A}`,
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-hub-signature-256":
              "sha256=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
          },
          body,
        },
      ),
    );

    expect(response.status).toBe(401);
    await settled();
    await chat.shutdown();
  });

  it("rejects a POST with NO signature at all (401)", async () => {
    const { chat, settled } = mount(installA);

    const response = await chat.webhooks.whatsapp(
      new Request(
        `https://bridge.example/connectors/webhooks/whatsapp/${PHONE_A}`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: webhookBody(PHONE_A),
        },
      ),
    );

    expect(response.status).toBe(401);
    await settled();
    await chat.shutdown();
  });
});

describe("whatsapp — CROSS-TENANT negative (mandatory)", () => {
  it("REJECTS a body signed with install A's app secret when it reaches install B", async () => {
    const body = webhookBody(PHONE_A);
    const signedByA = sign(SECRET_A, body);

    // SANITY FIRST — distrust vacuous green. If A's OWN adapter also rejected this body,
    // the 401 below would prove nothing at all: a broken signer would "pass" the leak
    // test. So first prove the body is genuinely valid for A, all the way to the HANDLER
    // (not merely to a 200 status line).
    const a = mount(installA);
    let handlerRanInA = false;
    a.chat.onDirectMessage(async (_thread, message) => {
      handlerRanInA = true;
      expect(message.text).toBe("hei");
    });

    const acceptedByA = await a.chat.webhooks.whatsapp(
      new Request(
        `https://bridge.example/connectors/webhooks/whatsapp/${PHONE_A}`,
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-hub-signature-256": signedByA,
          },
          body,
        },
      ),
      { waitUntil: a.waitUntil },
    );
    expect(acceptedByA.status).toBe(200);
    await a.settled();
    expect(handlerRanInA).toBe(true); // the body IS live for A
    await a.chat.shutdown();

    // THE LEAK ATTEMPT: the SAME bytes, the SAME valid-for-A signature, delivered to
    // workspace B's adapter (its own Meta app, its own App Secret).
    const b = mount(installB);
    let handlerRanInB = false;
    b.chat.onDirectMessage(async () => {
      handlerRanInB = true;
    });

    const rejectedByB = await b.chat.webhooks.whatsapp(
      new Request(
        `https://bridge.example/connectors/webhooks/whatsapp/${PHONE_B}`,
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-hub-signature-256": signedByA,
          },
          body,
        },
      ),
      { waitUntil: b.waitUntil },
    );

    // 401: B's App Secret does not verify A's signature. One tenant's inbound cannot be
    // replayed into another tenant's bridge — and B's handler never ran, so no Session
    // was minted and nothing was posted in B's name.
    expect(rejectedByB.status).toBe(401);
    await b.settled();
    expect(handlerRanInB).toBe(false);

    await b.chat.shutdown();
  });

  it("keeps each install's verify token to itself", async () => {
    const { chat, settled } = mount(installB);

    // A's verify token must not open B's webhook registration.
    const response = await chat.webhooks.whatsapp(
      new Request(
        `https://bridge.example/connectors/webhooks/whatsapp/${PHONE_B}` +
          `?hub.mode=subscribe&hub.verify_token=${VERIFY_A}&hub.challenge=X`,
      ),
    );

    expect(response.status).toBe(403);
    await settled();
    await chat.shutdown();
  });
});
