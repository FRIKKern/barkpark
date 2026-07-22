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
  /**
   * The HMAC secret that makes a CONNECT TICKET unforgeable
   * (`CONNECTORS_CONNECT_SECRET`, charter D50). Shared with the BEAM, which mints
   * the tickets this bridge verifies; generated once by `instance-deploy.sh`,
   * exactly like `CONNECTORS_CREDENTIAL_KEY`.
   *
   * OPTIONAL — and unlike `credentialKey` it is deliberately NOT read through
   * `required()`. Absent ⇒ the connect routes are simply NOT MOUNTED (with a loud
   * boot log) and answer the same opaque 404 as any unknown path. A `required()`
   * here would mean every host whose `.env` predates this feature REFUSES TO BOOT,
   * turning `/connectors` into the maintenance 503 for every tenant on the box —
   * an outage caused by a feature nobody is using yet. It also removes the
   * merge-order hazard between this slice and the deploy slice that writes the env.
   *
   * Never a plaintext fallback and never a default value: an empty secret would
   * make HMAC verify anything an attacker signs with an empty key.
   */
  connectSecret?: string;
  /** The agent's display name in a channel. */
  userName: string;
  /** The inbound HTTP transport for webhook channels (Slack/Teams/WhatsApp). */
  webhook: WebhookConfig;
  /**
   * How often the webhook mount index re-reads `connector_installs` and converges
   * against it (`CONNECTORS_MOUNT_RECONCILE_INTERVAL_MS`, charter D83). This is
   * what makes a horizontally-scaled bridge survive: replica A handles an OAuth
   * callback and mounts the new install in ITS OWN in-memory index; replica B,
   * which never saw the request, is stale until it rediscovers the row on a tick.
   *
   * `0` DISABLES the reconcile entirely — a single-replica deploy needs nothing
   * more than the boot mount + the connect-time `addInstall`, and the loop would
   * only burn a query. Optional in the TYPE so a hand-built test config can omit
   * it; `loadConfig` always sets it, and `startBridge` falls back to the default.
   */
  mountReconcileIntervalMs?: number;
  /**
   * How often the SOCKET/POLL ownership lease is renewed and lapsed leases are
   * taken over (`CONNECTORS_INSTALL_LEASE_INTERVAL_MS`, charter D93/D94). This is
   * what stops a horizontally-scaled bridge from opening a SECOND Discord socket /
   * a SECOND Telegram poll against one bot: exactly one replica holds each
   * install's lease and drives its transport; the others stand by and take over on
   * lapse. Distinct from `mountReconcileIntervalMs` (webhook mounts, replica-safe
   * a different way). `0` disables the loop — a single-replica deploy just holds
   * the lease from boot. Optional in the TYPE; `loadConfig` always sets it.
   */
  installLeaseIntervalMs?: number;
  /**
   * The lease TTL (`CONNECTORS_INSTALL_LEASE_TTL_MS`) — how long a claim stays
   * valid before a standby may steal it. MUST exceed `installLeaseIntervalMs` (the
   * holder renews every interval; a TTL below the interval would let a healthy
   * holder's lease lapse mid-cycle and flap). `loadConfig` enforces `ttl >
   * interval` by defaulting the TTL to 3× the interval.
   */
  installLeaseTtlMs?: number;
  /**
   * The Discord modal-OPEN hold window in ms
   * (`CONNECTORS_DISCORD_MODAL_WINDOW_MS`, charter D249). The webhook wrapper
   * HOLDS the vendor's synchronous type-5 ack for an APPLICATION_COMMAND
   * interaction and races {openModal-called, dispatch-settled, deadline}: a
   * modal opened inside the window becomes the interaction's HTTP response
   * (type 9) and the held ack is discarded — the only way Discord accepts a
   * modal (it must be the FIRST response, and an ack that already left would
   * make it 40060 "already acknowledged").
   *
   * The cost is honest: every NON-modal slash command's ack is delayed by
   * min(dispatch-settled, window), so the cap is tight — max 2500ms, well under
   * Discord's 3-second interaction deadline. `0` DISABLES the hold entirely
   * (immediate vendor ack; `openModal` answers warn + undefined, the pre-D249
   * contract). Optional in the TYPE so a hand-built test config can omit it;
   * `loadConfig` always sets it and the wrapper defaults to 250.
   */
  discordModalWindowMs?: number;
}

/**
 * Inbound webhook transport config (charter D34/D39).
 *
 * `host`/`port` come from `CONNECTORS_HTTP_ADDR` — the ONE name the deploy writes
 * into `/etc/barkpark/connectors.env` (`127.0.0.1:4020`, D34). It is `host:port`,
 * not a bare port, and the host half is load-bearing: on guerrilla the bridge must
 * bind LOOPBACK only, because Caddy fronts it on a path route and a bridge
 * listening on 0.0.0.0 would put every provider webhook — and the `x-forwarded-*`
 * headers the seam trusts — directly on the public internet.
 *
 * `pathPrefix` is load-bearing too: Caddy's `handle` does NOT strip the prefix, so
 * the bridge's router owns the FULL `/connectors/...` path. If the proxy and the
 * bridge disagree about it, EVERY webhook 404s silently.
 *
 * `publicBaseUrl` is equally load-bearing behind a proxy: the socket speaks plain
 * http, but adapters that validate the audience/URL (Teams' Bot Framework JWT)
 * need the PUBLIC https URL in the request they are handed.
 */
export interface WebhookConfig {
  /** Poll/socket-only deployments (Telegram, Discord) can turn the listener off. */
  enabled: boolean;
  /** The interface to bind. `127.0.0.1` behind Caddy — never `0.0.0.0` in Cloud. */
  host: string;
  port: number;
  /** Default `/connectors`. Must match the path the provider is configured with. */
  pathPrefix: string;
  /** e.g. `https://guerrilla.barkpark.cloud`. Unset = derive from x-forwarded-proto/host. */
  publicBaseUrl?: string;
  /** Bodies larger than this are rejected with a 413 (never a socket teardown). */
  maxBodyBytes: number;
}

/**
 * Loopback by default, and deliberately so: the seam trusts `x-forwarded-proto` /
 * `x-forwarded-host` when `publicBaseUrl` is unset (that is what makes Teams' JWT
 * audience check work behind Caddy), and those headers are only trustworthy from a
 * proxy. A bridge that defaulted to 0.0.0.0 would let a stranger spoof them.
 */
const DEFAULT_WEBHOOK_HOST = "127.0.0.1";
const DEFAULT_WEBHOOK_PORT = 4020;
const DEFAULT_WEBHOOK_PATH_PREFIX = "/connectors";
const DEFAULT_WEBHOOK_MAX_BODY_BYTES = 1_048_576;
/**
 * 30s: fast enough that a second replica picks up a new install within one poll
 * of the OAuth callback that wrote it, slow enough that the reconcile query is
 * noise against real traffic. `0` in the env disables it.
 */
export const DEFAULT_MOUNT_RECONCILE_INTERVAL_MS = 30_000;
/**
 * 15s renew: comfortably under the 45s default TTL (3×), so two consecutive
 * renew-misses still leave headroom before a standby steals a lease from a holder
 * that is merely slow. Fast enough that a dead owner's socket/poll install is
 * taken over within ~one TTL; slow enough that the claim query is noise. `0`
 * disables the loop for a single-replica deploy.
 */
export const DEFAULT_INSTALL_LEASE_INTERVAL_MS = 15_000;
/** 3× the renew interval — a holder must miss three renews before a lapse is stealable. */
export const DEFAULT_INSTALL_LEASE_TTL_MS = DEFAULT_INSTALL_LEASE_INTERVAL_MS * 3;
/**
 * 250ms: long enough for a handler that opens a modal to reach `openModal`
 * (that call is typically the handler's FIRST await), short enough that a
 * non-modal command's deferred ack still lands with ~10× headroom inside
 * Discord's 3-second interaction deadline. See `discordModalWindowMs`.
 */
export const DEFAULT_DISCORD_MODAL_WINDOW_MS = 250;
/** The knob's hard cap — the hold must stay well under Discord's 3s deadline. */
export const MAX_DISCORD_MODAL_WINDOW_MS = 2500;

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

  // Blank is the same as absent. A whitespace-only CONNECTORS_CONNECT_SECRET must
  // NOT mount the routes with an effectively empty HMAC key.
  const connectSecret = env["CONNECTORS_CONNECT_SECRET"]?.trim();

  return {
    databaseUrl: required(env, "DATABASE_URL"),
    apiUrl: required(env, "BARKPARK_API_URL"),
    credentialKey: required(env, "CONNECTORS_CREDENTIAL_KEY"),
    previousCredentialKeys: splitKeys(env["CONNECTORS_CREDENTIAL_KEY_PREVIOUS"]),
    ...(connectSecret ? { connectSecret } : {}),
    userName: env["BRIDGE_USER_NAME"]?.trim() || "barkpark",
    webhook: loadWebhookConfig(env),
    mountReconcileIntervalMs: intFromEnv(
      env,
      "CONNECTORS_MOUNT_RECONCILE_INTERVAL_MS",
      DEFAULT_MOUNT_RECONCILE_INTERVAL_MS,
      0,
      Number.MAX_SAFE_INTEGER,
    ),
    installLeaseIntervalMs: intFromEnv(
      env,
      "CONNECTORS_INSTALL_LEASE_INTERVAL_MS",
      DEFAULT_INSTALL_LEASE_INTERVAL_MS,
      0,
      Number.MAX_SAFE_INTEGER,
    ),
    installLeaseTtlMs: intFromEnv(
      env,
      "CONNECTORS_INSTALL_LEASE_TTL_MS",
      // Default the TTL to the LARGER of the healthy default and 3× the (possibly
      // overridden) interval, so `ttl > interval` holds when the interval is raised
      // AND a `0` interval (loop disabled) still yields a full-length TTL — never a
      // 1ms lease that a second replica could steal on its own boot pass.
      Math.max(
        DEFAULT_INSTALL_LEASE_TTL_MS,
        intFromEnv(
          env,
          "CONNECTORS_INSTALL_LEASE_INTERVAL_MS",
          DEFAULT_INSTALL_LEASE_INTERVAL_MS,
          0,
          Number.MAX_SAFE_INTEGER,
        ) * 3,
      ),
      1,
      Number.MAX_SAFE_INTEGER,
    ),
    discordModalWindowMs: intFromEnv(
      env,
      "CONNECTORS_DISCORD_MODAL_WINDOW_MS",
      DEFAULT_DISCORD_MODAL_WINDOW_MS,
      0,
      MAX_DISCORD_MODAL_WINDOW_MS,
    ),
  };
}

/**
 * Parse `CONNECTORS_HTTP_ADDR` — `host:port`, or a bare `port`.
 *
 * This is the name `deploy/instance-deploy.sh` writes into
 * `/etc/barkpark/connectors.env` (D34), so it is the name that has to work: a
 * bridge that silently ignored it would bind its default port while Caddy
 * reverse-proxied :4020, and EVERY provider webhook would land on the maintenance
 * 503 — with a green deploy and a running unit to look at.
 *
 * A malformed value is an ERROR, never a silent fallback, for the same reason.
 * IPv6 is accepted in bracket form (`[::1]:4020`).
 */
function httpAddrFromEnv(env: NodeJS.ProcessEnv): {
  host: string;
  port: number;
} {
  const raw = env["CONNECTORS_HTTP_ADDR"]?.trim();
  if (raw === undefined || raw === "") {
    return {
      host: env["CONNECTORS_WEBHOOK_HOST"]?.trim() || DEFAULT_WEBHOOK_HOST,
      port: intFromEnv(
        env,
        "CONNECTORS_WEBHOOK_PORT",
        DEFAULT_WEBHOOK_PORT,
        1,
        65535,
      ),
    };
  }

  // `[::1]:4020` | `127.0.0.1:4020` | `4020`
  const bracketed = /^\[(.+)\]:(\d+)$/.exec(raw);
  const hostPort = bracketed ?? /^([^:]*):(\d+)$/.exec(raw);
  const bare = /^(\d+)$/.exec(raw);

  const host = hostPort ? (hostPort[1] as string) : DEFAULT_WEBHOOK_HOST;
  const portText = hostPort ? hostPort[2] : bare?.[1];
  if (portText === undefined) {
    throw new InvalidConfigError(
      "CONNECTORS_HTTP_ADDR",
      `expected "host:port" (e.g. 127.0.0.1:4020) or a bare port, got "${raw}"`,
    );
  }

  const port = Number(portText);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new InvalidConfigError(
      "CONNECTORS_HTTP_ADDR",
      `port must be an integer in [1, 65535], got "${portText}"`,
    );
  }

  return { host: host === "" ? DEFAULT_WEBHOOK_HOST : host, port };
}

/**
 * Webhook transport config. Every value has a working default — a bridge with no
 * webhook channels installed still boots, and one with them needs only an address.
 * A malformed number is an ERROR, never a silent fallback: a bridge listening on
 * the wrong port is a bridge that 404s every provider event.
 */
export function loadWebhookConfig(
  env: NodeJS.ProcessEnv = process.env,
): WebhookConfig {
  const { host, port } = httpAddrFromEnv(env);

  return {
    enabled: boolFromEnv(env["CONNECTORS_WEBHOOK_ENABLED"], true),
    host,
    port,
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
