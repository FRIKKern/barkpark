/**
 * Typed environment configuration for the connectors bridge.
 *
 * The bridge is a standalone, PERSISTENT Node service (charter D27/D32) and a
 * CLIENT of Barkpark's /v1/chat HTTP+SSE API (D33). It holds two pieces of
 * per-tenant state, both in its OWN Postgres schema (`chat_bridge`), never in a
 * Barkpark/Ecto-owned table: the thread_id -> Session UUID map (D28) and the
 * connector_installs routing table (D29).
 *
 * There is NO process-wide chat token any more. Each install carries its OWN
 * workspace-bound `chat` ApiToken, sealed in its `connector_installs` row and
 * opened per turn (D35) — so the credential a tenant's traffic travels on is
 * derived from the same row that routed it, and nothing else.
 *
 * Nothing here reads secrets eagerly at import time: `loadConfig()` is called by
 * the composition root, so tests inject their own values without a populated
 * environment.
 */

export interface BridgeConfig {
  /** Postgres connection string. state-pg + the bridge-owned tables share this. */
  databaseUrl: string;
  /** Base URL of the Barkpark API exposing /v1/chat (e.g. https://guerrilla.barkpark.cloud). */
  apiUrl: string;
  /**
   * Base64 32-byte AES-256-GCM key sealing every install's secrets
   * (`CONNECTORS_CREDENTIAL_KEY`). An INDEPENDENT key — not `BARKPARK_KEK`, not
   * an ApiToken.
   *
   * Read through `required()` on purpose: a missing key is a BOOT FAILURE, never
   * a plaintext fallback. Encryption you can accidentally turn off by unsetting
   * a variable is not encryption.
   */
  credentialKey: string;
  /**
   * Base64 keys tried only AFTER `credentialKey` fails to open a blob
   * (`CONNECTORS_CREDENTIAL_KEY_PREVIOUS`, comma-separated for a rotation chain).
   * Never used to seal. Lets a key rotation drain as rows are rewritten instead
   * of demanding a flag day.
   */
  previousCredentialKeys: string[];
  /** The agent's display name in a channel. */
  userName: string;
  /** The inbound HTTP transport for webhook channels (Slack/Teams/WhatsApp). */
  webhook: WebhookConfig;
}

/**
 * Inbound webhook transport config (charter D39).
 *
 * `pathPrefix` is load-bearing: Caddy's `handle` does NOT strip the prefix, so the
 * bridge's router owns the FULL `/connectors/...` path. If the proxy and the
 * bridge disagree about it, EVERY webhook 404s silently.
 *
 * `publicBaseUrl` is equally load-bearing behind a proxy: the socket speaks plain
 * http, but adapters that validate the audience/URL (Teams' Bot Framework JWT)
 * need the PUBLIC https URL in the request they are handed.
 */
export interface WebhookConfig {
  /** Poll/socket-only deployments (Telegram, Discord) can turn the listener off. */
  enabled: boolean;
  port: number;
  /** Default `/connectors`. Must match the path the provider is configured with. */
  pathPrefix: string;
  /** e.g. `https://bridge.barkpark.cloud`. Unset = derive from x-forwarded-proto/host. */
  publicBaseUrl?: string;
  /** Bodies larger than this are rejected with a 413 (never a socket teardown). */
  maxBodyBytes: number;
}

const DEFAULT_WEBHOOK_PORT = 3000;
const DEFAULT_WEBHOOK_PATH_PREFIX = "/connectors";
const DEFAULT_WEBHOOK_MAX_BODY_BYTES = 1_048_576;

export class MissingConfigError extends Error {
  constructor(key: string) {
    super(`connectors: required environment variable ${key} is not set`);
    this.name = "MissingConfigError";
  }
}

function required(env: NodeJS.ProcessEnv, key: string): string {
  const value = env[key];
  if (value === undefined || value.trim() === "") {
    throw new MissingConfigError(key);
  }
  return value;
}

/**
 * MIGRATION NOTE — `BARKPARK_CHAT_TOKEN` is DEAD on the request path.
 *
 * It used to be one operator token that served every tenant: `chatClientFor()`
 * ignored its `workspaceId` argument entirely, so a `:global` token would have
 * read every workspace's sessions. The token now lives per install, sealed in
 * `chat_bridge.connector_installs.chat_token_ref` (D35). An operator whose old
 * `.env` still exports it deserves to be told it does nothing, rather than to
 * discover it silently by a tenant reading another tenant's Session.
 */
const RETIRED_ENV = "BARKPARK_CHAT_TOKEN";

function warnRetiredEnv(env: NodeJS.ProcessEnv): void {
  if (env[RETIRED_ENV]?.trim()) {
    console.warn(
      `[bridge] ${RETIRED_ENV} is set but IGNORED — the bridge no longer uses a ` +
        "process-wide chat token. Each install carries its own workspace-bound " +
        "token, sealed in chat_bridge.connector_installs.chat_token_ref. " +
        "Provision one per install (see connectors/README.md) and unset this.",
    );
  }
}

/** Split a comma-separated key list, tolerating whitespace and trailing commas. */
function splitKeys(value: string | undefined): string[] {
  if (!value) return [];
  return value
    .split(",")
    .map((k) => k.trim())
    .filter((k) => k !== "");
}

/**
 * Read and validate the bridge configuration from the environment.
 * Fail-closed: a missing required variable throws rather than booting a
 * half-configured bridge. `env` is injectable for tests.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): BridgeConfig {
  warnRetiredEnv(env);

  return {
    databaseUrl: required(env, "DATABASE_URL"),
    apiUrl: required(env, "BARKPARK_API_URL"),
    credentialKey: required(env, "CONNECTORS_CREDENTIAL_KEY"),
    previousCredentialKeys: splitKeys(env["CONNECTORS_CREDENTIAL_KEY_PREVIOUS"]),
    userName: env["BRIDGE_USER_NAME"]?.trim() || "barkpark",
    webhook: loadWebhookConfig(env),
  };
}

/**
 * Webhook transport config. Every value has a working default — a bridge with no
 * webhook channels installed still boots, and one with them needs only a port.
 * A malformed number is an ERROR, never a silent fallback: a bridge listening on
 * the wrong port is a bridge that 404s every provider event.
 */
export function loadWebhookConfig(
  env: NodeJS.ProcessEnv = process.env,
): WebhookConfig {
  return {
    enabled: boolFromEnv(env["CONNECTORS_WEBHOOK_ENABLED"], true),
    port: intFromEnv(
      env,
      "CONNECTORS_WEBHOOK_PORT",
      DEFAULT_WEBHOOK_PORT,
      1,
      65535,
    ),
    pathPrefix:
      env["CONNECTORS_PATH_PREFIX"]?.trim() || DEFAULT_WEBHOOK_PATH_PREFIX,
    publicBaseUrl: env["CONNECTORS_PUBLIC_BASE_URL"]?.trim() || undefined,
    maxBodyBytes: intFromEnv(
      env,
      "CONNECTORS_MAX_BODY_BYTES",
      DEFAULT_WEBHOOK_MAX_BODY_BYTES,
      1,
      Number.MAX_SAFE_INTEGER,
    ),
  };
}

/** `0`/`false`/`no`/`off` disable; anything else set is on; unset takes the default. */
function boolFromEnv(raw: string | undefined, fallback: boolean): boolean {
  const value = raw?.trim().toLowerCase();
  if (value === undefined || value === "") return fallback;
  return !["0", "false", "no", "off"].includes(value);
}

function intFromEnv(
  env: NodeJS.ProcessEnv,
  key: string,
  fallback: number,
  min: number,
  max: number,
): number {
  const raw = env[key]?.trim();
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new InvalidConfigError(
      key,
      `expected an integer in [${min}, ${max}], got "${raw}"`,
    );
  }
  return value;
}

export class InvalidConfigError extends Error {
  constructor(key: string, detail: string) {
    super(`connectors: environment variable ${key} is invalid — ${detail}`);
    this.name = "InvalidConfigError";
  }
}
