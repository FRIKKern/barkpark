import {
  createWhatsAppAdapter,
  type WhatsAppAdapter,
} from "@chat-adapter/whatsapp";

import type {
  Connector,
  ConnectorInstall,
  InboundEvent,
  TenantContext,
} from "../connector/types.js";
import { credentialBoundResolver } from "../tenant/resolve.js";

/**
 * WhatsApp — the heavy pair's second half (charter D3/D29/D30, D43).
 *
 * The mirror image of Teams. Where Teams has ONE operator app and no per-workspace
 * credential, WhatsApp is **bring-your-own Meta app**: all FOUR of the adapter's
 * credentials are per-install —
 *
 *     accessToken     a System User token (whatsapp_business_messaging)
 *     appSecret       the Meta App Secret — verifies the inbound HMAC
 *     phoneNumberId   the WABA number's id
 *     verifyToken     the shared secret of the GET webhook handshake
 *
 * — so the tenant is bound to the CREDENTIAL (`tenantResolution: "credential-bound"`),
 * and the install key is the `phone_number_id`.
 *
 * WHY THE KEY COMES FROM THE PATH, NOT THE BODY (`keySource: "path"`): the body's
 * signature is verified with THAT install's `appSecret`. If the body chose which
 * install verifies it, an attacker would pick the install whose secret they know — the
 * body would select the key that authenticates the body. So the seam takes the install
 * key from the URL (`/connectors/webhooks/whatsapp/<phone_number_id>`), verifies with
 * that install's secret, and only THEN may cross-check the body's own
 * `metadata.phone_number_id` (see {@link whatsappPayloadMatchesInstall}). Teams can
 * safely do the opposite because every Teams install verifies against the same
 * operator JWT.
 *
 * The GET handshake (`hub.mode` / `hub.verify_token` / `hub.challenge`) MUST reach the
 * adapter — that is why the webhook seam's `allowedMethods` includes GET. Observed
 * (`test/whatsapp-connector.test.ts`, no live number): matching verifyToken -> 200 with
 * the challenge echoed as the body; wrong token -> 403; POST with a bad HMAC -> 401.
 *
 * THE 24-HOUR WINDOW IS OURS: the adapter deliberately "does not auto-substitute
 * templates for outbound text posts". A free-form post outside the window is rejected by
 * Meta at send time — a runtime discovery in production. So the policy is a PURE,
 * unit-tested function in `src/policy/whatsapp-window.ts`, decided before we ever call
 * the API. Nothing in this file silently upgrades a message to a template.
 */

export const WHATSAPP_PROVIDER = "whatsapp";

/**
 * One install's Meta credentials, stored as JSON in `connector_installs.credential_ref`.
 *
 * `phoneNumberId` is NOT in here — it is the `install_key` (a PRIMARY KEY column, and
 * non-secret by construction). Keeping it out means the routing key can never be read
 * out of a secret blob.
 *
 * KNOWN GAP (unchanged by this slice): `credential_ref` is plaintext today. The
 * envelope cipher is `connectors-encrypt-install-credentials`; a JSON blob is exactly
 * what it will wrap, so this shape survives it.
 */
export interface WhatsappCredential {
  accessToken: string;
  appSecret: string;
  verifyToken: string;
}

/** Serialise a credential for `connector_installs.credential_ref`. */
export function encodeWhatsappCredential(cred: WhatsappCredential): string {
  return JSON.stringify({
    accessToken: cred.accessToken,
    appSecret: cred.appSecret,
    verifyToken: cred.verifyToken,
  });
}

function requireField(
  parsed: Record<string, unknown>,
  key: keyof WhatsappCredential,
): string {
  const value = parsed[key];
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(
      `whatsapp: connector_installs.credential_ref is missing "${key}" — ` +
        "an install without all four Meta credentials cannot verify its own webhook. " +
        "See docs/ops/whatsapp-meta.md.",
    );
  }
  return value;
}

/**
 * Read an install's credential. Throws rather than constructing a half-credentialled
 * adapter: an adapter with a blank `appSecret` would verify NOTHING, and the SDK
 * silently defaults missing fields from `WHATSAPP_*` env vars — which in a
 * multi-tenant process would hand one workspace another's (or the operator's)
 * credentials. Fail loud at mount, never fail open at request time.
 */
export function parseWhatsappCredential(
  credentialRef: string | null | undefined,
): WhatsappCredential {
  if (
    credentialRef === null ||
    credentialRef === undefined ||
    credentialRef.trim() === ""
  ) {
    throw new Error(
      "whatsapp: install has no credential_ref — WhatsApp is bring-your-own Meta app; " +
        "all four credentials are per-install. See docs/ops/whatsapp-meta.md.",
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(credentialRef);
  } catch {
    throw new Error(
      "whatsapp: credential_ref is not valid JSON — expected " +
        '{"accessToken":…,"appSecret":…,"verifyToken":…}',
    );
  }
  if (typeof parsed !== "object" || parsed === null) {
    throw new Error("whatsapp: credential_ref must be a JSON object");
  }
  const record = parsed as Record<string, unknown>;

  return {
    accessToken: requireField(record, "accessToken"),
    appSecret: requireField(record, "appSecret"),
    verifyToken: requireField(record, "verifyToken"),
  };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null
    ? (value as Record<string, unknown>)
    : null;
}

function asKey(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

function firstRecord(value: unknown): Record<string, unknown> | null {
  return Array.isArray(value) ? asRecord(value[0]) : null;
}

/**
 * THE ONE WhatsApp install-key derivation: the business `phone_number_id`.
 *
 * Webhook body:  `entry[].changes[].value.metadata.phone_number_id`
 * SDK message:   `raw.phoneNumberId` (`WhatsAppRawMessage`), so the dispatched event
 *                resolves through the same function with zero core change.
 *
 * Used to CROSS-CHECK the path key after verification — never to select the secret that
 * verifies the body (see the module docstring). Unreadable -> null -> drop.
 */
// @canonical capability:whatsapp-install-key aka:whatsapp,phone_number_id,install-key,metadata doc:docs/ops/whatsapp-meta.md
export function whatsappInstallKey(payload: unknown): string | null {
  const outer = asRecord(payload);
  if (!outer) return null;

  // SDK Message -> WhatsAppRawMessage.phoneNumberId
  const raw = asRecord(outer["raw"]);
  const fromRaw = asKey(raw?.["phoneNumberId"]);
  if (fromRaw !== null) return fromRaw;

  // A WhatsAppRawMessage handed to us directly.
  const direct = asKey(outer["phoneNumberId"]);
  if (direct !== null) return direct;

  // The raw Meta webhook body.
  const entry = firstRecord(outer["entry"]);
  const change = firstRecord(entry?.["changes"]);
  const value = asRecord(change?.["value"]);
  const metadata = asRecord(value?.["metadata"]);
  return asKey(metadata?.["phone_number_id"]);
}

/**
 * Post-verification cross-check: does the body's own `phone_number_id` agree with the
 * install the path selected? A mismatch means the request was routed by one identity
 * and carries another — drop it. (Meta will not send this; a proxy misconfiguration or
 * an attacker replaying a body across paths would.)
 */
export function whatsappPayloadMatchesInstall(
  installKey: string,
  payload: unknown,
): boolean {
  const fromPayload = whatsappInstallKey(payload);
  // A status-only callback (delivery receipts) carries metadata too; a body we cannot
  // read at all is not a match we can assert, so it fails closed.
  return fromPayload !== null && fromPayload === installKey;
}

/**
 * The last inbound message's timestamp, in epoch ms — the input to the 24-hour window
 * policy. Meta sends `timestamp` as a unix-SECONDS string; the window is in ms, and
 * mixing the two would make every window look 1000x too old (i.e. always closed) or
 * too new (always open). Converted once, here.
 */
export function whatsappInboundTimestampMs(payload: unknown): number | null {
  const outer = asRecord(payload);
  if (!outer) return null;

  // SDK Message -> raw.message.timestamp; or a WhatsAppRawMessage handed over directly.
  const raw = asRecord(outer["raw"]) ?? outer;
  let message = asRecord(raw["message"]);

  if (!message) {
    // The raw Meta webhook body: entry[0].changes[0].value.messages[0].timestamp
    const entry = firstRecord(outer["entry"]);
    const change = firstRecord(entry?.["changes"]);
    const value = asRecord(change?.["value"]);
    message = firstRecord(value?.["messages"]);
  }
  if (!message) return null;

  const stamp = message["timestamp"];
  const seconds = typeof stamp === "string" ? Number(stamp) : stamp;
  if (typeof seconds !== "number" || !Number.isFinite(seconds) || seconds <= 0) {
    return null;
  }
  return Math.round(seconds * 1000);
}

/** The inbound-HTTP contract the webhook seam reads (structural). */
export interface WhatsappWebhookDescriptor {
  /** The body cannot pick the secret that verifies the body. The path does. */
  keySource: "path";
  /** GET is the Meta verification handshake; POST is the event. Both must reach the adapter. */
  allowedMethods: readonly ["GET", "POST"];
  extractInstallKey(payload: unknown): string | null;
}

export type WhatsappConnector = Connector & {
  webhook: WhatsappWebhookDescriptor;
};

export interface WhatsappConnectorOptions {
  /** Meta Graph API base URL override (tests point this at a dead local port). */
  apiUrl?: string;
  /** Meta Graph API version. */
  apiVersion?: string;
  /** The agent's display name in the chat. */
  userName?: string;
}

export function createWhatsappConnector(
  options: WhatsappConnectorOptions = {},
): WhatsappConnector {
  const resolver = credentialBoundResolver();

  return {
    id: WHATSAPP_PROVIDER,
    direction: "channel",
    // The Meta App Secret signs every inbound body: a signing-secret connector.
    auth: "signing-secret",
    tenantResolution: "credential-bound",

    /**
     * One adapter per install, built from THAT workspace's four Meta credentials and
     * nothing else (D1). Every field is passed explicitly — never left to the adapter's
     * `WHATSAPP_*` env fallbacks, which in a multi-tenant process would leak the
     * operator's (or another tenant's) credentials into this adapter.
     */
    adapterFactory(install: ConnectorInstall): WhatsAppAdapter {
      const cred = parseWhatsappCredential(install.credentialRef);
      return createWhatsAppAdapter({
        accessToken: cred.accessToken,
        appSecret: cred.appSecret,
        verifyToken: cred.verifyToken,
        phoneNumberId: install.installKey,
        ...(options.apiUrl !== undefined ? { apiUrl: options.apiUrl } : {}),
        ...(options.apiVersion !== undefined
          ? { apiVersion: options.apiVersion }
          : {}),
        ...(options.userName !== undefined ? { userName: options.userName } : {}),
      });
    },

    async resolveTenant(
      event: InboundEvent,
      ctx: TenantContext,
    ): Promise<string | null> {
      return resolver(event, ctx);
    },

    // The core loop reads this to feed the durable 24-hour window store (D178).
    // Pure wiring: the parsing + unix-seconds→ms conversion already live in the
    // unit-tested whatsappInboundTimestampMs; nothing new is parsed here.
    inboundTimestampMs: whatsappInboundTimestampMs,

    // No `listen`: the transport IS the HTTP request (chat.webhooks.whatsapp).

    webhook: {
      keySource: "path",
      allowedMethods: ["GET", "POST"],
      extractInstallKey: whatsappInstallKey,
    },
  };
}
