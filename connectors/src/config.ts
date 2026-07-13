/**
 * Typed environment configuration for the connectors bridge.
 *
 * The bridge is a standalone Node service (charter D27) and a CLIENT of
 * Barkpark's /v1/chat HTTP+SSE API (D33). It holds exactly one piece of
 * per-conversation state — the thread_id -> Session UUID map (D28) — in its
 * OWN Postgres schema (`chat_bridge`), never in a Barkpark/Ecto-owned table.
 *
 * Nothing here reads secrets eagerly at import time: `loadConfig()` is called
 * by the composition root (the persistent process, D32) so tests can inject
 * their own values without a populated environment.
 */

export interface BridgeConfig {
  /** Postgres connection string. state-pg + the bridge-owned map share this. */
  databaseUrl: string;
  /** Base URL of the Barkpark API exposing /v1/chat (e.g. https://guerrilla.barkpark.cloud). */
  barkparkApiUrl: string;
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
 * Read and validate the bridge configuration from the environment.
 * Fail-closed: a missing required variable throws rather than booting a
 * half-configured bridge. `env` is injectable for tests.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): BridgeConfig {
  return {
    databaseUrl: required(env, "DATABASE_URL"),
    barkparkApiUrl: required(env, "BARKPARK_API_URL"),
  };
}
