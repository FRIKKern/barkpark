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
}

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
  };
}
