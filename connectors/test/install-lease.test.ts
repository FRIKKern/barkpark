/**
 * THE SOCKET/POLL SINGLE-OWNER LEASE (charter D93/D94/D95) — against a REAL
 * Postgres, because the whole point is that TWO bridge replicas agree, through one
 * shared table, that exactly ONE of them drives each Discord Gateway socket /
 * Telegram getUpdates poll. A fake table cannot model "two connections, one truth".
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE BUG THIS FILE EXISTS TO PIN
 * ─────────────────────────────────────────────────────────────────────────────
 * A socket/poll transport is a long-lived connection the bridge OPENS. Open it on
 * two replicas and the provider punishes it: Discord delivers every message twice
 * (the agent double-POSTs), Telegram 409-Conflicts two getUpdates long-polls on one
 * bot. W8's mount-reconcile made WEBHOOK channels replica-safe — a stateless HTTP
 * request any replica may serve — but explicitly left socket/poll as the honest
 * remainder (D83/D95). This lease closes it: one atomic claim/renew/steal statement,
 * so exactly one replica owns each install and a standby takes over on lapse.
 *
 * The test models the split brain with NO second deploy: two independently
 * constructed coordinators, each over its OWN `createBridgePool()`, in ONE vitest
 * process over ONE Postgres. Distinct pools are the whole point — one coordinator
 * cannot see the other's in-memory `served` map, only the shared lease table.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * WHAT THIS TEST DELIBERATELY DOES NOT PROVE (honest scope, D95)
 * ─────────────────────────────────────────────────────────────────────────────
 * It proves LEASE ARBITRATION: exactly-one-owner, takeover on lapse, clean release.
 * `onAcquire`/`onRelease` are recorders here, not real `connector.listen` calls —
 * the transport wiring is proven separately by the boot→shutdown case at the foot of
 * this file (which routes a real `startBridge` shutdown through `takeDown` and
 * asserts the lease row is gone). It does NOT prove a LIVE Discord/Telegram
 * round-trip — that is a human gate, never faked, and ZERO live installs exist.
 */
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { randomBytes } from "node:crypto";
import pg from "pg";

import {
  createBridgeLeaseStore,
  createInstallLease,
  type InstallLease,
  type LeaseStore,
} from "../src/tenant/install-lease.js";
import { createConnectorRegistry } from "../src/connector/registry.js";
import { createCredentialCipher } from "../src/crypto/credential-cipher.js";
import {
  createBridgePool,
  ensureBridgeSchema,
  type BridgePool,
} from "../src/db/pool.js";
import { startBridge, type Bridge } from "../src/index.js";
import { createInstallsLookup, upsertInstall } from "../src/tenant/installs.js";
import type { Adapter } from "chat";
import type {
  Connector,
  ConnectorInstall,
  MutableInstallsLookup,
} from "../src/connector/types.js";
import type { BridgeConfig } from "../src/config.js";

const cipher = createCredentialCipher({ key: randomBytes(32).toString("base64") });
const CREDENTIAL_KEY = randomBytes(32).toString("base64");

const WS_A = "11111111-1111-4111-8111-111111111111";
const WS_B = "22222222-2222-4222-8222-222222222222";

const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";
const TEST_DB = `connectors_install_lease_test_${process.pid}_${Date.now()}`;

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
// Connectors. A socket/poll channel is ONE registry entry WITHOUT a `webhook`
// block and WITH a `listen()` — the exact complement of mount-reconcile's filter.
// ---------------------------------------------------------------------------

/**
 * A minimal adapter the real Chat SDK accepts through `initialize()` — needed by
 * the boot→shutdown case, which builds a REAL bridge. The coordinator unit tests
 * never initialise a Chat (they inject recorders for onAcquire/onRelease), so they
 * can pass the empty default below.
 */
function stubAdapter(): Adapter {
  return {
    name: "stub",
    async initialize() {},
    async handleWebhook(): Promise<Response> {
      return new Response("{}", { status: 200 });
    },
  } as unknown as Adapter;
}

/** A poll/socket connector: no `webhook`, has `listen()`. Lease-managed. */
function pollConnector(
  id: string,
  adapterFactory: () => Adapter = () => ({}) as Adapter,
): Connector {
  return {
    id,
    direction: "channel",
    auth: "token",
    tenantResolution: "credential-bound",
    adapterFactory,
    async resolveTenant() {
      return null;
    },
    // The coordinator never calls this (it calls the injected onAcquire); it exists
    // only so `isLeaseManaged`/`socketPollConnectors` selects the connector. In the
    // boot→shutdown case the REAL bridge calls it — a no-op, so no real socket opens.
    async listen() {},
    async stopListening() {},
  };
}

/** A webhook channel: has `webhook`, so it is NOT lease-managed (mount-reconcile owns it). */
function webhookConnector(id: string): Connector {
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

/** A channel with neither webhook nor listen — not a real transport, never managed. */
function inertConnector(id: string): Connector {
  return {
    id,
    direction: "channel",
    auth: "token",
    tenantResolution: "credential-bound",
    adapterFactory: () => ({}) as Adapter,
    async resolveTenant() {
      return null;
    },
  };
}

const TELEGRAM = "telegram";
const KEY = "bot-1";

const pollInstall = (workspaceId: string, installKey = KEY): ConnectorInstall => ({
  provider: TELEGRAM,
  installKey,
  workspaceId,
  credentialRef: "123:telegram-bot-token",
  chatToken: "bp_chat_ws_token",
});

describe.skipIf(!reachable && !REQUIRE_DB)(
  "socket/poll ownership lease — exactly one replica drives each install (D93/D94, real Postgres)",
  () => {
    let admin: pg.Client;
    let poolA: pg.Pool;
    let poolB: pg.Pool;
    let writerPool: pg.Pool;
    let installsA: MutableInstallsLookup;
    let installsB: MutableInstallsLookup;
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
      // THREE independent pools to the SAME database: replica A, replica B, and a
      // "wire" writer that inserts install rows / forces a lease lapse the way
      // another process would. Distinct connections are the whole point.
      poolA = createBridgePool({ connectionString: url });
      poolB = createBridgePool({ connectionString: url });
      writerPool = createBridgePool({ connectionString: url });
      await ensureBridgeSchema(poolA);
      installsA = createInstallsLookup(poolA, cipher);
      installsB = createInstallsLookup(poolB, cipher);

      registry = createConnectorRegistry();
      registry.register(pollConnector(TELEGRAM));
      registry.register(webhookConnector("slack"));
      registry.register(inertConnector("inert"));
    }, 30_000);

    afterAll(async () => {
      await poolA?.end();
      await poolB?.end();
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

    // A coordinator wired to recorders, its own lease store over its own pool.
    interface Replica {
      lease: InstallLease;
      acquired: string[];
      released: string[];
      ownerId: string;
    }

    function makeReplica(
      ownerId: string,
      pool: BridgePool,
      installs: MutableInstallsLookup,
      ttlMs = 60_000,
    ): Replica {
      const acquired: string[] = [];
      const released: string[] = [];
      const store: LeaseStore = createBridgeLeaseStore(pool, { ownerId, ttlMs });
      const lease = createInstallLease(
        {
          registry,
          installs,
          lease: store,
          onAcquire: async (install) => {
            acquired.push(install.installKey);
          },
          onRelease: async (install) => {
            released.push(install.installKey);
          },
        },
        // intervalMs 0: no timer — we drive reconcileOnce() deterministically.
        { intervalMs: 0 },
      );
      return { lease, acquired, released, ownerId };
    }

    async function leaseOwner(installKey = KEY): Promise<string | null> {
      const { rows } = await writerPool.query(
        "SELECT owner_id FROM chat_bridge.connector_install_leases WHERE provider = $1 AND install_key = $2",
        [TELEGRAM, installKey],
      );
      return (rows[0] as { owner_id?: string } | undefined)?.owner_id ?? null;
    }

    async function forceLapse(installKey = KEY): Promise<void> {
      // How "the holder crashed without releasing" looks on the wire: its lease row
      // is still there, but its expiry is in the past.
      await writerPool.query(
        "UPDATE chat_bridge.connector_install_leases SET expires_at = now() - interval '1 hour' WHERE provider = $1 AND install_key = $2",
        [TELEGRAM, installKey],
      );
    }

    // ───────────────────────────────────────────────────────────────────────
    // THE HEADLINE: exactly one owner. A listens; B stands by.
    // ───────────────────────────────────────────────────────────────────────
    it("EXACTLY ONE replica owns a socket/poll install — the other stands by (no listen())", async () => {
      await upsertInstall(writerPool, cipher, pollInstall(WS_A));

      const a = makeReplica("replica-A", poolA, installsA);
      const b = makeReplica("replica-B", poolB, installsB);

      // A ticks first and wins the lease → it starts the transport ONCE.
      const summaryA = await a.lease.reconcileOnce();
      expect(summaryA.acquired).toBe(1);
      expect(a.acquired).toEqual([KEY]);
      expect(a.lease.serving()).toEqual([{ provider: TELEGRAM, installKey: KEY }]);
      expect(await leaseOwner()).toBe("replica-A");

      // B ticks and finds the lease LIVE and not its own → stands by, no onAcquire.
      const summaryB = await b.lease.reconcileOnce();
      expect(summaryB.acquired).toBe(0);
      expect(summaryB.standby).toBe(1);
      expect(b.acquired).toEqual([]);
      expect(b.lease.serving()).toEqual([]);

      // The invariant, stated as an assertion: across both replicas, exactly ONE
      // is serving this install.
      expect(a.lease.serving().length + b.lease.serving().length).toBe(1);
      // A's second tick just RENEWS — it does not start a second transport.
      const renewA = await a.lease.reconcileOnce();
      expect(renewA.renewed).toBe(1);
      expect(renewA.acquired).toBe(0);
      expect(a.acquired).toEqual([KEY]); // still exactly one listen() ever
    });

    // ───────────────────────────────────────────────────────────────────────
    // STANDBY TAKEOVER: the owner's lease lapses; the standby claims it.
    // ───────────────────────────────────────────────────────────────────────
    it("a standby TAKES OVER when the owner's lease lapses (expires without renewal)", async () => {
      await upsertInstall(writerPool, cipher, pollInstall(WS_A));

      const a = makeReplica("replica-A", poolA, installsA);
      const b = makeReplica("replica-B", poolB, installsB);

      await a.lease.reconcileOnce();
      await b.lease.reconcileOnce();
      expect(await leaseOwner()).toBe("replica-A");
      expect(b.acquired).toEqual([]);

      // A dies without releasing: its lease row lingers but is now past expiry.
      await forceLapse();

      // B's NEXT tick steals the lapsed lease and starts the transport — takeover
      // with no human, no restart.
      const takeover = await b.lease.reconcileOnce();
      expect(takeover.acquired).toBe(1);
      expect(b.acquired).toEqual([KEY]);
      expect(await leaseOwner()).toBe("replica-B");

      // And A, whenever it comes back / ticks again, finds the lease is B's now and
      // STANDS DOWN — it stops the transport it thought it still owned. Net: still
      // exactly one owner.
      const standDown = await a.lease.reconcileOnce();
      expect(standDown.released).toBe(1);
      expect(a.released).toEqual([KEY]);
      expect(a.lease.serving()).toEqual([]);
      expect(a.lease.serving().length + b.lease.serving().length).toBe(1);
    });

    // ───────────────────────────────────────────────────────────────────────
    // CLEAN RELEASE: the owner releases; the standby's next tick acquires.
    // ───────────────────────────────────────────────────────────────────────
    it("a released lease is immediately claimable by the standby (graceful handoff)", async () => {
      await upsertInstall(writerPool, cipher, pollInstall(WS_A));

      const a = makeReplica("replica-A", poolA, installsA);
      const b = makeReplica("replica-B", poolB, installsB);

      await a.lease.reconcileOnce();
      expect(await leaseOwner()).toBe("replica-A");

      // A releases its own lease (this is exactly what takeDown does on shutdown —
      // the owner-scoped DELETE). The row is gone.
      const store = createBridgeLeaseStore(poolA, {
        ownerId: "replica-A",
        ttlMs: 60_000,
      });
      await store.release(TELEGRAM, KEY);
      expect(await leaseOwner()).toBe(null);

      // B acquires on its very next tick — no TTL wait, because the row is free.
      const summaryB = await b.lease.reconcileOnce();
      expect(summaryB.acquired).toBe(1);
      expect(await leaseOwner()).toBe("replica-B");
    });

    it("a release by a NON-owner is a no-op — it cannot yank a live lease", async () => {
      await upsertInstall(writerPool, cipher, pollInstall(WS_A));
      const a = makeReplica("replica-A", poolA, installsA);
      await a.lease.reconcileOnce();
      expect(await leaseOwner()).toBe("replica-A");

      // B (which does NOT own it) tries to release — the owner-scoped DELETE matches
      // zero rows, so A keeps its lease.
      const bStore = createBridgeLeaseStore(poolB, {
        ownerId: "replica-B",
        ttlMs: 60_000,
      });
      await bStore.release(TELEGRAM, KEY);
      expect(await leaseOwner()).toBe("replica-A");
    });

    // ───────────────────────────────────────────────────────────────────────
    // ROW-GONE: a disconnect on another replica → the owner stands down.
    // ───────────────────────────────────────────────────────────────────────
    it("stands down when the install row disappears (a disconnect handled elsewhere)", async () => {
      await upsertInstall(writerPool, cipher, pollInstall(WS_A));
      const a = makeReplica("replica-A", poolA, installsA);
      await a.lease.reconcileOnce();
      expect(a.lease.serving()).toHaveLength(1);

      // Another replica handled DISCONNECT: the install row is gone from the table.
      await writerPool.query(
        "DELETE FROM chat_bridge.connector_installs WHERE provider = $1 AND install_key = $2",
        [TELEGRAM, KEY],
      );

      const summary = await a.lease.reconcileOnce();
      expect(summary.released).toBe(1);
      expect(a.released).toEqual([KEY]);
      expect(a.lease.serving()).toEqual([]);
      // The lease was released too, so nothing lingers claiming ownership.
      expect(await leaseOwner()).toBe(null);
    });

    // ───────────────────────────────────────────────────────────────────────
    // CONTAINMENT: a poisoned acquire is reported AND releases its lease, so a
    // standby can try — a bad row never squats a lease no one serves.
    // ───────────────────────────────────────────────────────────────────────
    it("releases the lease when onAcquire throws — a poisoned row cannot squat it", async () => {
      await upsertInstall(writerPool, cipher, pollInstall(WS_A));

      const failures: string[] = [];
      const store: LeaseStore = createBridgeLeaseStore(poolA, {
        ownerId: "replica-A",
        ttlMs: 60_000,
      });
      const lease = createInstallLease(
        {
          registry,
          installs: installsA,
          lease: store,
          onAcquire: async () => {
            throw new Error("chat.initialize() failed: credential revoked");
          },
          onRelease: async () => {},
        },
        { intervalMs: 0, onError: (context) => failures.push(context) },
      );

      const summary = await lease.reconcileOnce();
      expect(summary.failures).toBe(1);
      expect(summary.acquired).toBe(0);
      expect(lease.serving()).toEqual([]);
      expect(failures.some((c) => c.includes("onAcquire"))).toBe(true);
      // The lease was RELEASED after the failed acquire, so a healthy replica can
      // take it — a failed mount does not squat a lease forever.
      expect(await leaseOwner()).toBe(null);
    });

    // ───────────────────────────────────────────────────────────────────────
    // THE BOUNDARY: webhook + inert connectors are NEVER lease-managed.
    // ───────────────────────────────────────────────────────────────────────
    it("never touches a WEBHOOK connector's rows — mount-reconcile owns those", async () => {
      await upsertInstall(writerPool, cipher, {
        provider: "slack",
        installKey: "T_TEAM",
        workspaceId: WS_A,
        credentialRef: "slack-signing-secret",
        chatToken: "bp_chat_ws_token",
      });
      const a = makeReplica("replica-A", poolA, installsA);
      const summary = await a.lease.reconcileOnce();
      expect(summary).toMatchObject({ acquired: 0, released: 0, standby: 0 });
      expect(a.lease.serving()).toEqual([]);
      // No lease row was written for a webhook install.
      const { rows } = await writerPool.query(
        "SELECT count(*)::int AS n FROM chat_bridge.connector_install_leases",
      );
      expect((rows[0] as { n: number }).n).toBe(0);
    });

    it("never touches a channel with no listen() — nothing to single-own", async () => {
      await upsertInstall(writerPool, cipher, {
        provider: "inert",
        installKey: "inert-1",
        workspaceId: WS_A,
        credentialRef: "x",
        chatToken: "y",
      });
      const a = makeReplica("replica-A", poolA, installsA);
      const summary = await a.lease.reconcileOnce();
      expect(summary.acquired).toBe(0);
      expect(a.lease.serving()).toEqual([]);
    });
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// THE SHUTDOWN REFACTOR (D94, criterion 1b): a real bridge boot claims the lease;
// Bridge.shutdown() — now routed THROUGH takeDown — releases it immediately, so a
// standby takes over on its next tick instead of waiting out the TTL.
// ─────────────────────────────────────────────────────────────────────────────
describe.skipIf(!reachable && !REQUIRE_DB)(
  "Bridge.shutdown() releases the socket/poll lease through takeDown (D94, real Postgres)",
  () => {
    const SHUTDOWN_DB = `${TEST_DB}_shutdown`;
    let admin: pg.Client;
    let pool: pg.Pool;
    let bridge: Bridge | undefined;

    beforeAll(async () => {
      if (!reachable && REQUIRE_DB) {
        throw new Error(
          `CONNECTORS_REQUIRE_DB=1 but no Postgres is reachable at ${ADMIN_URL}`,
        );
      }
      admin = new pg.Client({ connectionString: ADMIN_URL });
      await admin.connect();
      await admin.query(`CREATE DATABASE ${SHUTDOWN_DB}`);
      pool = createBridgePool({
        connectionString: urlForDatabase(ADMIN_URL, SHUTDOWN_DB),
      });
      await ensureBridgeSchema(pool);
    }, 30_000);

    afterAll(async () => {
      await bridge?.shutdown().catch(() => {});
      await pool?.end();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${SHUTDOWN_DB} WITH (FORCE)`);
        await admin.end();
      }
    }, 30_000);

    it("boot claims the lease; shutdown releases it (no TTL wait for the standby)", async () => {
      const installCipher = createCredentialCipher({ key: CREDENTIAL_KEY });
      const install: ConnectorInstall = {
        provider: TELEGRAM,
        installKey: "bot-shutdown",
        workspaceId: WS_A,
        credentialRef: "123:telegram-bot-token",
        chatToken: "bp_chat_ws_token",
      };
      await upsertInstall(pool, installCipher, install);

      const registry = createConnectorRegistry();
      registry.register(pollConnector(TELEGRAM, stubAdapter));

      const config: BridgeConfig = {
        databaseUrl: urlForDatabase(ADMIN_URL, SHUTDOWN_DB),
        apiUrl: "http://127.0.0.1:1",
        credentialKey: CREDENTIAL_KEY,
        previousCredentialKeys: [],
        userName: "barkpark",
        webhook: {
          enabled: false,
          host: "127.0.0.1",
          port: 0,
          pathPrefix: "/connectors",
          maxBodyBytes: 65_536,
        },
        // 0 disables the periodic timer; the ONE boot pass still claims the lease.
        installLeaseIntervalMs: 0,
      };

      bridge = await startBridge(config, { registry });

      // Boot's single lease pass claimed it: a row exists for the poll install.
      const held = await pool.query(
        "SELECT count(*)::int AS n FROM chat_bridge.connector_install_leases WHERE provider = $1 AND install_key = $2",
        [TELEGRAM, "bot-shutdown"],
      );
      expect((held.rows[0] as { n: number }).n).toBe(1);

      await bridge.shutdown();
      bridge = undefined;

      // shutdown() went through takeDown, which released the lease — the row is
      // GONE, so a standby replica would acquire on its very next tick.
      const afterPool = createBridgePool({
        connectionString: urlForDatabase(ADMIN_URL, SHUTDOWN_DB),
      });
      try {
        const after = await afterPool.query(
          "SELECT count(*)::int AS n FROM chat_bridge.connector_install_leases WHERE provider = $1 AND install_key = $2",
          [TELEGRAM, "bot-shutdown"],
        );
        expect((after.rows[0] as { n: number }).n).toBe(0);
      } finally {
        await afterPool.end();
      }
    }, 30_000);
  },
);
