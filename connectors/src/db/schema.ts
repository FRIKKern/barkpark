/**
 * Bridge-owned Postgres DDL (charter D28/D29).
 *
 * Everything the bridge writes lives in a dedicated `chat_bridge` schema, kept
 * strictly separate from Barkpark's Ecto-owned tables (chat_sessions, the
 * schema_migrations, etc.) which sit in `public`. There is NO Ecto migration
 * for any of this — the bridge creates its own tables idempotently at boot.
 *
 * @chat-adapter/state-pg's 5 tables (chat_state_subscriptions / _locks /
 * _cache / _lists / _queues) are UNQUALIFIED `CREATE TABLE IF NOT EXISTS`
 * statements: they land in whatever the connection's search_path points at.
 * By pinning the Pool's search_path to `chat_bridge` (see db/pool.ts) those
 * tables also land in `chat_bridge`, never `public`. keyPrefix namespaces the
 * SDK's ROW keys, not the schema — it is not a table-isolation mechanism.
 */

export const CHAT_BRIDGE_SCHEMA = "chat_bridge";

/** `CREATE SCHEMA IF NOT EXISTS chat_bridge` — safe to run on every boot. */
export const CREATE_SCHEMA_SQL = `CREATE SCHEMA IF NOT EXISTS ${CHAT_BRIDGE_SCHEMA}`;

/**
 * thread_session_map — the ONLY per-conversation state the bridge holds.
 * (workspace_id, thread_id) -> Barkpark Session UUID (chat_sessions.id).
 * Minted on first message, resumed thereafter, so cross-surface continuity for
 * a single channel falls out (true cross-CHANNEL merge is deferred to P4, D31).
 * PK is composite so the same raw thread id in two workspaces never collides.
 */
export const CREATE_THREAD_SESSION_MAP_SQL = `
CREATE TABLE IF NOT EXISTS thread_session_map (
  workspace_id text        NOT NULL,
  thread_id    text        NOT NULL,
  session_uuid text        NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, thread_id)
)`;

/**
 * connector_installs — the tenant-routing seam P3/OAuth writes into (D29).
 * (provider, install_key) -> workspace_id + a reference to the tenant's stored
 * credential. Designed now so all six P3 channels land with zero core changes.
 * `install_key` is the provider's per-installation identity (a Telegram bot id,
 * a Slack team_id, …); `credential_ref` points at where the credential lives
 * (never the raw secret in this column).
 */
export const CREATE_CONNECTOR_INSTALLS_SQL = `
CREATE TABLE IF NOT EXISTS connector_installs (
  provider       text NOT NULL,
  install_key    text NOT NULL,
  workspace_id   text NOT NULL,
  credential_ref text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, install_key)
)`;

/** All bridge-owned DDL, in dependency order, to run once the schema exists. */
export const BRIDGE_TABLE_DDL: readonly string[] = [
  CREATE_THREAD_SESSION_MAP_SQL,
  CREATE_CONNECTOR_INSTALLS_SQL,
];
