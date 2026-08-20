/**
 * DUAL TRANSPORT (charter D225/D226/D227) — a connector declaring BOTH a
 * `webhook` block AND a `listen()` runs BOTH transports: the webhook mounts into
 * the W8 replica-safe index (any replica serves HTTP) AND the socket/poll side is
 * lease-managed (exactly one replica drives `listen()`). Discord is the customer:
 * a bot keeps its Gateway socket for messages while interactions arrive as
 * Ed25519-signed HTTP webhooks.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE BUG THIS FILE EXISTS TO PIN (red-first on the pre-D225 XOR)
 * ─────────────────────────────────────────────────────────────────────────────
 * Before D225 the transport model was an XOR at TWO code sites: `isLeaseManaged`
 * (src/index.ts) and its circular-import-forced inline duplicate
 * `socketPollConnectors()` (src/tenant/install-lease.ts) both required
 * `connector.webhook === undefined`. Adding a webhook block to Discord would
 * therefore SILENTLY KILL its Gateway: the predicate flips false, the lease
 * coordinator's filter excludes the install, `onAcquire` never fires, and normal
 * DMs/mentions stop with no error anywhere — while slash commands keep working.
 * This file's first two cases are exactly the assertions that FAILED on the
 * pre-fix tree (`isLeaseManaged(dual)` was false; `reconcileOnce()` acquired 0):
 * they pin the fix at BOTH sites.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE CONTROLS (the boundary must not move anywhere else)
 * ─────────────────────────────────────────────────────────────────────────────
 * A webhook-only channel (Slack/Teams/WhatsApp) is still NEVER lease-managed; a
 * listen-only channel (Telegram/Discord-today) leases exactly as before; and
 * mount-reconcile still mounts the DUAL install's webhook side (its filter is
 * presence-only and additive by construction — D226 proved zero change needed).
 * The lease stays PER-INSTALL (D227): one row, no transport column — only the
 * socket needs single ownership; webhooks are stateless on every replica.
 */
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { randomBytes } from "node:crypto";
import pg from "pg";

import { isLeaseManaged } from "../src/index.js";
import {
  createBridgeLeaseStore,
  createInstallLease,
  type InstallLease,
  type LeaseStore,
} from "../src/tenant/install-lease.js";
import { createMountReconcile } from "../src/http/mount-reconcile.js";
import {
  createWebhookMountIndex,
  type WebhookCapableChat,
  type WebhookHandler,
  type WebhookMountIndex,
} from "../src/http/mounts.js";
import { createConnectorRegistry } from "../src/connector/registry.js";
import { createCredentialCipher } from "../src/crypto/credential-cipher.js";
import {
  createBridgePool,
  ensureBridgeSchema,
  type BridgePool,
} from "../src/db/pool.js";
import { createInstallsLookup, upsertInstall } from "../src/tenant/installs.js";
import type { Adapter } from "chat";
import type {
  Connector,
  ConnectorInstall,
  MutableInstallsLookup,
} from "../src/connector/types.js";

const cipher = createCredentialCipher({ key: randomBytes(32).toString("base64") });

const WS_A = "11111111-1111-4111-8111-111111111111";

const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";
const TEST_DB = `connectors_dual_transport_test_${process.pid}_${Date.now()}`;

async function postgresReachable(): Promise<boolean> {
  const client = new pg.Client({ connectionString: ADMIN_URL });
  try {
    await client.connect();
    await client.end();
    return true;
  } catch {
    return false;
  }
}

const reachable = await postgresReachable();

function urlForDatabase(base: string, db: string): string {
  const url = new URL(base);
  url.pathname = `/${db}`;
  return url.toString();
}

// ---------------------------------------------------------------------------
// Fixtures. The DUAL connector is the wave's whole point: BOTH a `webhook`
// block (per-install URL, WhatsApp's path-keyed precedent — what Discord's
// interaction endpoint will declare) AND a `listen()` (the Gateway socket).
// The webhook-only and listen-only fixtures are the controls: the D225
// redefinition must not move the boundary for either of them.
// ---------------------------------------------------------------------------

/** Discord-after-W27 shape: Gateway socket AND an interactions webhook. */
function dualConnector(id: string): Connector {
  return {
    id,
    direction: "channel",
    auth: "token",
    tenantResolution: "credential-bound",
    adapterFactory: () => ({}) as Adapter,
    async resolveTenant() {
      return null;
    },
    webhook: { keySource: "path" },
    // The lease coordinator, never boot, starts this (single-owner socket).
    async listen() {},
    async stopListening() {},
  };
}

/** Slack/Teams/WhatsApp shape: HTTP is the ONLY transport. Never leased. */
function webhookOnlyConnector(id: string): Connector {
  return {
    id,
    direction: "channel",
    auth: "signing-secret",
    tenantResolution: "payload-team-id",
    adapterFactory: () => ({}) as Adapter,
    async resolveTenant() {
      return null;
    },
    webhook: { keySource: "payload" },
  };
}

/** Telegram/Discord-today shape: `listen()` is the ONLY transport. Leased. */
function listenOnlyConnector(id: string): Connector {
  return {
    id,
    direction: "channel",
    auth: "token",
    tenantResolution: "credential-bound",
    adapterFactory: () => ({}) as Adapter,
    async resolveTenant() {
      return null;
    },
    async listen() {},
    async stopListening() {},
  };
}

const DUAL = "dualprov";
const WEBHOOK_ONLY = "hookonly";
const LISTEN_ONLY = "pollonly";

const installFor = (provider: string, installKey: string): ConnectorInstall => ({
  provider,
  installKey,
  workspaceId: WS_A,
  credentialRef: "credential-bytes",
  chatToken: "bp_chat_ws_token",
});

// ─────────────────────────────────────────────────────────────────────────────
// SITE 1 — the exported predicate (src/index.ts). Pure, no DB. The dual case
// REDS on the pre-D225 tree: `webhook === undefined` made the predicate an XOR.
// ─────────────────────────────────────────────────────────────────────────────
describe("isLeaseManaged — transports are additive, derived from connector shape (D225)", () => {
  it("a DUAL connector (webhook + listen) IS lease-managed — the webhook must not evict the socket", () => {
    // THE red-first assertion: pre-D225 this was `false` (the XOR), and adding
    // an interactions webhook to Discord would have silently killed its Gateway.
    expect(isLeaseManaged(dualConnector(DUAL))).toBe(true);
  });

  it("CONTROL: a webhook-only connector is still NEVER lease-managed", () => {
    expect(isLeaseManaged(webhookOnlyConnector(WEBHOOK_ONLY))).toBe(false);
  });

  it("CONTROL: a listen-only connector is still lease-managed, exactly as today", () => {
    expect(isLeaseManaged(listenOnlyConnector(LISTEN_ONLY))).toBe(true);
  });

  it("CONTROL: a channel with neither transport is not lease-managed", () => {
    const inert: Connector = {
      id: "inert",
      direction: "channel",
      auth: "token",
      tenantResolution: "credential-bound",
      adapterFactory: () => ({}) as Adapter,
      async resolveTenant() {
        return null;
      },
    };
    expect(isLeaseManaged(inert)).toBe(false);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// SITE 2 — the lease coordinator's inline duplicate (src/tenant/install-lease.ts
// `socketPollConnectors()`, which CANNOT import isLeaseManaged — circular). Real
// Postgres: the coordinator must ACQUIRE the Gateway lease for a dual install.
// Pre-D225 this redded with acquired=0 — the exact silent-eviction failure mode.
// ─────────────────────────────────────────────────────────────────────────────
describe.skipIf(!reachable && !REQUIRE_DB)(
  "install-lease coordinator — a dual-transport install keeps its socket lease (D226, real Postgres)",
  () => {
    let admin: pg.Client;
    let pool: pg.Pool;
    let writerPool: pg.Pool;
    let installs: MutableInstallsLookup;
    let registry: ReturnType<typeof createConnectorRegistry>;

    beforeAll(async () => {
      if (!reachable && REQUIRE_DB) {
        throw new Error(
          `CONNECTORS_REQUIRE_DB=1 but no Postgres is reachable at ${ADMIN_URL}`,
        );
      }
      admin = new pg.Client({ connectionString: ADMIN_URL });
      await admin.connect();
      await admin.query(`CREATE DATABASE ${TEST_DB}`);

      const url = urlForDatabase(ADMIN_URL, TEST_DB);
      pool = createBridgePool({ connectionString: url });
      writerPool = createBridgePool({ connectionString: url });
      await ensureBridgeSchema(pool);
      installs = createInstallsLookup(pool, cipher);

      // One registry carrying all three shapes, so each case also proves the
      // OTHERS were left alone in the very same pass.
      registry = createConnectorRegistry();
      registry.register(dualConnector(DUAL));
      registry.register(webhookOnlyConnector(WEBHOOK_ONLY));
      registry.register(listenOnlyConnector(LISTEN_ONLY));
    }, 30_000);

    afterAll(async () => {
      await pool?.end();
      await writerPool?.end();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)`);
        await admin.end();
      }
    }, 30_000);

    afterEach(async () => {
      await writerPool.query("DELETE FROM chat_bridge.connector_install_leases");
      await writerPool.query("DELETE FROM chat_bridge.connector_installs");
    });

    interface Replica {
      lease: InstallLease;
      acquired: string[];
      released: string[];
    }

    function makeReplica(ownerId: string, replicaPool: BridgePool): Replica {
      const acquired: string[] = [];
      const released: string[] = [];
      const store: LeaseStore = createBridgeLeaseStore(replicaPool, {
        ownerId,
        ttlMs: 60_000,
      });
      const lease = createInstallLease(
        {
          registry,
          installs,
          lease: store,
          onAcquire: async (install) => {
            acquired.push(`${install.provider}:${install.installKey}`);
          },
          onRelease: async (install) => {
            released.push(`${install.provider}:${install.installKey}`);
          },
        },
        { intervalMs: 0 },
      );
      return { lease, acquired, released };
    }

    async function leaseOwner(
      provider: string,
      installKey: string,
    ): Promise<string | null> {
      const { rows } = await writerPool.query(
        "SELECT owner_id FROM chat_bridge.connector_install_leases WHERE provider = $1 AND install_key = $2",
        [provider, installKey],
      );
      return (rows[0] as { owner_id?: string } | undefined)?.owner_id ?? null;
    }

    it("ACQUIRES the socket lease for a dual-transport install — the webhook block does not exclude it", async () => {
      await upsertInstall(writerPool, cipher, installFor(DUAL, "bot-dual"));

      const a = makeReplica("replica-A", pool);
      const summary = await a.lease.reconcileOnce();

      // THE red-first pair, verbatim from the executed D226 probe: pre-fix this
      // pass returned acquired=0 (the inline XOR excluded the connector), and
      // failures===0 pins the red's CAUSE — a DB error would also read acquired=0.
      expect(summary.acquired).toBe(1);
      expect(summary.failures).toBe(0);
      // onAcquire — the real `connector.listen()` in production — actually fired.
      expect(a.acquired).toEqual([`${DUAL}:bot-dual`]);
      expect(a.lease.serving()).toEqual([
        { provider: DUAL, installKey: "bot-dual" },
      ]);
      // And the lease row exists, owned by this replica.
      expect(await leaseOwner(DUAL, "bot-dual")).toBe("replica-A");
    });

    it("CONTROL: a webhook-only install is still never touched — no lease row, no onAcquire", async () => {
      await upsertInstall(writerPool, cipher, installFor(WEBHOOK_ONLY, "T_TEAM"));

      const a = makeReplica("replica-A", pool);
      const summary = await a.lease.reconcileOnce();

      expect(summary).toMatchObject({ acquired: 0, released: 0, standby: 0 });
      expect(a.acquired).toEqual([]);
      const { rows } = await writerPool.query(
        "SELECT count(*)::int AS n FROM chat_bridge.connector_install_leases",
      );
      expect((rows[0] as { n: number }).n).toBe(0);
    });

    it("CONTROL: a listen-only install leases exactly as today — one acquire, then renew", async () => {
      await upsertInstall(writerPool, cipher, installFor(LISTEN_ONLY, "bot-1"));

      const a = makeReplica("replica-A", pool);
      const first = await a.lease.reconcileOnce();
      expect(first.acquired).toBe(1);
      expect(first.failures).toBe(0);
      expect(a.acquired).toEqual([`${LISTEN_ONLY}:bot-1`]);
      expect(await leaseOwner(LISTEN_ONLY, "bot-1")).toBe("replica-A");

      const second = await a.lease.reconcileOnce();
      expect(second.renewed).toBe(1);
      expect(second.acquired).toBe(0);
      expect(a.acquired).toEqual([`${LISTEN_ONLY}:bot-1`]); // still exactly one listen() ever
    });

    it("dual + listen-only in ONE pass: both leased, the webhook-only sibling untouched", async () => {
      await upsertInstall(writerPool, cipher, installFor(DUAL, "bot-dual"));
      await upsertInstall(writerPool, cipher, installFor(LISTEN_ONLY, "bot-1"));
      await upsertInstall(writerPool, cipher, installFor(WEBHOOK_ONLY, "T_TEAM"));

      const a = makeReplica("replica-A", pool);
      const summary = await a.lease.reconcileOnce();

      expect(summary.acquired).toBe(2);
      expect(summary.failures).toBe(0);
      expect([...a.acquired].sort()).toEqual([
        `${DUAL}:bot-dual`,
        `${LISTEN_ONLY}:bot-1`,
      ]);
      // The webhook-only install wrote no lease row — the DB carries exactly two.
      const { rows } = await writerPool.query(
        "SELECT count(*)::int AS n FROM chat_bridge.connector_install_leases",
      );
      expect((rows[0] as { n: number }).n).toBe(2);
    });
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// THE OTHER HALF OF DUAL — mount-reconcile still mounts the dual install's
// WEBHOOK side (its `webhook !== undefined` filter is presence-only and already
// additive; D226 proved zero change needed there). Green before AND after the
// fix — pinned so a future "optimisation" cannot turn that filter exclusive.
// ─────────────────────────────────────────────────────────────────────────────
describe.skipIf(!reachable && !REQUIRE_DB)(
  "mount-reconcile — the dual install's webhook side still mounts (D226 boundary, real Postgres)",
  () => {
    const MOUNT_DB = `${TEST_DB}_mount`;
    let admin: pg.Client;
    let pool: pg.Pool;
    let installs: MutableInstallsLookup;
    let registry: ReturnType<typeof createConnectorRegistry>;

    beforeAll(async () => {
      if (!reachable && REQUIRE_DB) {
        throw new Error(
          `CONNECTORS_REQUIRE_DB=1 but no Postgres is reachable at ${ADMIN_URL}`,
        );
      }
      admin = new pg.Client({ connectionString: ADMIN_URL });
      await admin.connect();
      await admin.query(`CREATE DATABASE ${MOUNT_DB}`);
      pool = createBridgePool({
        connectionString: urlForDatabase(ADMIN_URL, MOUNT_DB),
      });
      await ensureBridgeSchema(pool);
      installs = createInstallsLookup(pool, cipher);

      registry = createConnectorRegistry();
      registry.register(dualConnector(DUAL));
      registry.register(listenOnlyConnector(LISTEN_ONLY));
    }, 30_000);

    afterAll(async () => {
      await pool?.end();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${MOUNT_DB} WITH (FORCE)`);
        await admin.end();
      }
    }, 30_000);

    it("mounts the DUAL install's webhook and leaves the listen-only sibling alone", async () => {
      await upsertInstall(pool, cipher, installFor(DUAL, "bot-dual"));
      await upsertInstall(pool, cipher, installFor(LISTEN_ONLY, "bot-1"));

      const mounts: WebhookMountIndex = createWebhookMountIndex();
      const handler: WebhookHandler = async () =>
        new Response("{}", { status: 200 });
      const chat: WebhookCapableChat = { webhooks: { [DUAL]: handler } };

      const reconcile = createMountReconcile(
        {
          registry,
          installs,
          mounts,
          addInstall: async (install) => {
            const connector = registry.get(install.provider);
            if (!connector) throw new Error(`no connector for ${install.provider}`);
            mounts.mount({ connector, install, chat });
          },
          removeInstall: async (provider, installKey) =>
            mounts.unmount(provider, installKey),
        },
        { intervalMs: 0 },
      );

      const summary = await reconcile.reconcileOnce();
      // Exactly the dual install mounted: its webhook side is any-replica-safe.
      // The listen-only sibling is the lease coordinator's, never this loop's.
      expect(summary).toEqual({ added: 1, removed: 0, failures: 0 });
      expect(mounts.handlerFor(installFor(DUAL, "bot-dual"))).toBeDefined();
      expect(mounts.handlerFor(installFor(LISTEN_ONLY, "bot-1"))).toBeUndefined();
    });
  },
);
