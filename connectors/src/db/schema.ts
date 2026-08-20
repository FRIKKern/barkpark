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
CREATE TABLE IF NOT EXISTS ${CHAT_BRIDGE_SCHEMA}.thread_session_map (
  workspace_id text        NOT NULL,
  thread_id    text        NOT NULL,
  session_uuid text        NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, thread_id)
)`;

/**
 * whatsapp_window — the durable last-inbound-at behind the WhatsApp 24h-window
 * policy (charter D43/D169). (workspace_id, thread_id) -> the epoch-ms timestamp
 * of that thread's most recent INBOUND message from the user.
 *
 * WhatsApp's Cloud API accepts a free-form business-initiated send only within 24h
 * of the user's last inbound; the adapter does not auto-substitute templates
 * (policy/whatsapp-window.ts). The in-memory store loses every window on restart, so
 * a proactive/scheduled agent would read `no-inbound-recorded` — CLOSED — after every
 * deploy. This row is the persistence that survives the restart.
 *
 * PK is composite for the SAME reason thread_session_map's is: two workspaces' threads
 * can collide on a provider thread id, and a single-column key would let one tenant's
 * inbound open another tenant's send window.
 *
 * `last_inbound_at` is `bigint` epoch-ms — the exact shape recordInbound/getLastInboundAt
 * exchange — so the monotonic upsert is a plain numeric `GREATEST(...)` with no timestamp
 * conversion. Bridge-internal, NEVER read by Elixir (like connector_install_leases, D93):
 * no `@schema_prefix` schema, no test_helper.exs transcription, and the connector_installs
 * DDL drift gate does not touch it.
 */
export const CREATE_WHATSAPP_WINDOW_SQL = `
CREATE TABLE IF NOT EXISTS ${CHAT_BRIDGE_SCHEMA}.whatsapp_window (
  workspace_id    text   NOT NULL,
  thread_id       text   NOT NULL,
  last_inbound_at bigint NOT NULL,
  PRIMARY KEY (workspace_id, thread_id)
)`;

/**
 * connector_installs — the tenant-routing seam P3/OAuth writes into (D29/D35).
 * (provider, install_key) -> workspace_id + the tenant's TWO sealed secrets.
 * Designed so all six P3 channels land with zero core changes.
 *
 * `install_key` is the provider's per-installation identity (a Telegram bot id,
 * a Slack team_id, …) — non-secret by construction, since it is a PRIMARY KEY
 * column and the routing query matches on it.
 *
 * `credential_ref` — the PROVIDER secret (bot token / signing secret).
 * `chat_token_ref` — THIS workspace's Barkpark `chat`-permission ApiToken, the
 *                    bearer the bridge presents to /v1/chat for this tenant.
 *
 * Both columns hold a SEALED blob, never plaintext: `Base64(iv‖tag‖ciphertext)`
 * from `src/crypto/credential-cipher.ts`, AES-256-GCM with the row's identity
 * (provider, install_key, workspace_id) as AAD. Flipping `workspace_id` on a row
 * therefore makes both blobs un-openable — the migration of a sealed token across
 * tenants fails closed instead of succeeding silently.
 *
 * (The names end in `_ref` for the same reason they always did: a later store
 * may hold a POINTER — a run-secret name, a KMS handle — rather than the sealed
 * bytes. Today they hold the sealed bytes. Earlier prose in this file claimed
 * "never the raw secret in this column" while the code wrote plaintext; the
 * claim is true now, and the code is what makes it true.)
 *
 * `chat_token_ref` is NULLABLE: an install can exist before its chat token is
 * provisioned (an OAuth callback lands the provider secret first). A NULL token
 * is a fail-closed DROP at dispatch, never a fallback to an operator token.
 *
 * ⚠️ TWO SOURCES OF TRUTH — KEEP THEM IN LOCKSTEP (connectors D54).
 * The bridge OWNS this DDL (charter D28: no Ecto migration may create
 * `chat_bridge`), but Elixir READS the table — the Studio Connectors catalog
 * queries it through `Barkpark.Connectors.Install`, an `@schema_prefix` schema.
 * The Elixir TEST database therefore has to create the table itself, and it does
 * so by TRANSCRIBING the SQL below:
 *
 *   · api/test/test_helper.exs                    — the fixture (mirrors BOTH statements here)
 *   · api/lib/barkpark/connectors/install.ex      — the Ecto schema (the column set)
 *   · api/test/barkpark/connectors/install_schema_test.exs — pins the column set
 *     against information_schema, so a drift REDS the Elixir suite instead of
 *     500ing Studio in production.
 *
 * This file has already drifted once — `ADD_CHAT_TOKEN_REF_SQL` below exists
 * precisely because `CREATE TABLE IF NOT EXISTS` was a no-op against P2's
 * four-column table. Change a column here ⇒ change all three files above.
 */
export const CREATE_CONNECTOR_INSTALLS_SQL = `
CREATE TABLE IF NOT EXISTS ${CHAT_BRIDGE_SCHEMA}.connector_installs (
  provider       text NOT NULL,
  install_key    text NOT NULL,
  workspace_id   text NOT NULL,
  credential_ref text,
  chat_token_ref text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, install_key)
)`;

/**
 * pending_connect — the short-lived join for Add-to-Slack's OAuth flow (D63).
 *
 * A Slack OAuth install crosses a browser redirect, so the workspace-bound chat
 * token (which only Studio can mint) has to be handed to the bridge over LOOPBACK
 * AHEAD of the redirect, then joined to the public callback's one-time `code`.
 * This row is that join: keyed by the ticket `nonce`, carrying the SEALED chat
 * token and a short expiry. The public callback consumes it (single-use, D63) and
 * writes the install once with both secrets. A missing/expired row fails closed.
 *
 * `chat_token_ref` is SEALED (AES-256-GCM) under the PENDING identity
 * `(provider, "pending:<nonce>", workspace_id)` — a distinct AAD from the install
 * row, so a pending blob can never open as an install blob (see
 * `src/connect/pending-connect.ts`). It is NOT NULL: a pending row with no token
 * could never complete a connect, so there is no honest "provisioned later" state.
 *
 * This is a SEPARATE table from `connector_installs`: it does not change that
 * table's column set, so the DDL drift gate (connectors D68) is unaffected.
 */
export const CREATE_PENDING_CONNECT_SQL = `
CREATE TABLE IF NOT EXISTS ${CHAT_BRIDGE_SCHEMA}.pending_connect (
  nonce          text        NOT NULL,
  workspace_id   text        NOT NULL,
  provider       text        NOT NULL,
  chat_token_ref text        NOT NULL,
  expires_at     timestamptz NOT NULL,
  PRIMARY KEY (nonce)
)`;

/**
 * chat_token_ref for a table that already exists (D35).
 *
 * `CREATE TABLE IF NOT EXISTS` is a no-op against P2's four-column table, so the
 * new column would never appear on any deployment that already booted the bridge.
 * `ADD COLUMN IF NOT EXISTS` is the idempotent forward path — and it is why the
 * bridge still needs no Ecto migration.
 */
export const ADD_CHAT_TOKEN_REF_SQL = `
ALTER TABLE ${CHAT_BRIDGE_SCHEMA}.connector_installs
  ADD COLUMN IF NOT EXISTS chat_token_ref text`;

/**
 * connector_install_leases — the single-owner lease for SOCKET/POLL channels
 * (charter D93). One row per install of a poll/socket connector (Discord's
 * Gateway websocket, Telegram's getUpdates loop), claimed by exactly ONE bridge
 * replica at a time so a horizontally-scaled bridge does not open a SECOND socket
 * / a SECOND long-poll against the same bot (Discord double-POST, Telegram 409
 * Conflict). Webhook channels do NOT need this — an inbound HTTP request is
 * stateless and any replica can serve it (W8 mount-reconcile already makes the
 * webhook mount index replica-safe); the lease covers exactly the complement.
 *
 * The claim/renew/steal is ONE atomic statement (`tenant/install-lease.ts`):
 *
 *   INSERT … ON CONFLICT (provider, install_key) DO UPDATE
 *     SET owner_id = EXCLUDED.owner_id, expires_at = EXCLUDED.expires_at
 *     WHERE connector_install_leases.owner_id = EXCLUDED.owner_id
 *        OR connector_install_leases.expires_at < now()
 *     RETURNING owner_id
 *
 * 0 rows returned ⇒ another replica holds a LIVE lease ⇒ stand by. A live lease
 * whose `expires_at < now()` (the holder crashed without releasing) is stolen on
 * the next tick — takeover on lapse falls out of the same statement.
 *
 * `owner_id` is a per-PROCESS `crypto.randomUUID()` (container-safe — a hostname
 * collides across templated pods; a fresh UUID never does).
 *
 * ⚠️ UNLIKE `connector_installs`, this table is NEVER read by Elixir (D93 LAW,
 * mirroring the D54 discipline): the Studio Connectors catalog lists installs,
 * not their runtime lease-holder, so there is NO `@schema_prefix` schema, NO
 * `test_helper.exs` transcription, and the DDL drift gate deliberately ignores
 * it (it scans `connector_installs` by hardcoded name). A future Elixir read
 * would reintroduce the two-source-of-truth transcription cost this LAW exists to
 * prevent — do not add one.
 */
export const CREATE_CONNECTOR_INSTALL_LEASES_SQL = `
CREATE TABLE IF NOT EXISTS ${CHAT_BRIDGE_SCHEMA}.connector_install_leases (
  provider     text        NOT NULL,
  install_key  text        NOT NULL,
  owner_id     text        NOT NULL,
  expires_at   timestamptz NOT NULL,
  taken_at     timestamptz NOT NULL DEFAULT now(),
  renewed_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, install_key)
)`;

/**
 * All bridge-owned DDL, in dependency order, to run once the schema exists.
 *
 * Note these are schema-QUALIFIED while state-pg's five are not. That asymmetry is
 * the point: the `search_path` pin exists to corral the SDK's unqualified DDL, and
 * the bridge's own SQL deliberately does not lean on it. Both land in
 * `chat_bridge`; only one of them has a choice about it.
 */
export const BRIDGE_TABLE_DDL: readonly string[] = [
  CREATE_THREAD_SESSION_MAP_SQL,
  // Durable last-inbound-at for the WhatsApp 24h-window policy (D43/D169).
  // Bridge-internal, never Elixir-read, so it does NOT touch the connector_installs
  // column set the drift gate guards.
  CREATE_WHATSAPP_WINDOW_SQL,
  CREATE_CONNECTOR_INSTALLS_SQL,
  // AFTER the create: on a fresh database the column is already there and this is
  // a no-op; on a P2 database it is the only thing that adds it.
  ADD_CHAT_TOKEN_REF_SQL,
  CREATE_PENDING_CONNECT_SQL,
  // Socket/poll single-owner lease (D93). Bridge-internal, never Elixir-read, so
  // it does NOT touch the connector_installs column set the drift gate guards.
  CREATE_CONNECTOR_INSTALL_LEASES_SQL,
];
