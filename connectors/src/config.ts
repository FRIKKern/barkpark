/**
 * Typed environment configuration for the connectors bridge.
 *
 * The bridge is a standalone, PERSISTENT Node service (charter D27/D32) and a
 * CLIENT of Barkpark's /v1/chat HTTP+SSE API (D33). It holds exactly one piece of
 * per-conversation state — the thread_id -> Session UUID map (D28) — in its OWN
 * Postgres schema (`chat_bridge`), never in a Barkpark/Ecto-owned table.
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
   * A workspace-bound ApiToken carrying the `chat` permission (D33).
   *
   * KNOWN GAP: this is ONE operator token for the whole process. Per-tenant
   * isolation of /v1/chat reads is therefore only as strong as this token — a
   * `:global` one would see every workspace's sessions. The per-workspace token
   * store is filed as `connectors-per-workspace-chat-token`; `chatClientFor()` in
   * index.ts is the seam it plugs into.
   */
  chatToken: string;
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
 * Read and validate the bridge configuration from the environment.
 * Fail-closed: a missing required variable throws rather than booting a
 * half-configured bridge. `env` is injectable for tests.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): BridgeConfig {
  return {
    databaseUrl: required(env, "DATABASE_URL"),
    apiUrl: required(env, "BARKPARK_API_URL"),
    chatToken: required(env, "BARKPARK_CHAT_TOKEN"),
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
