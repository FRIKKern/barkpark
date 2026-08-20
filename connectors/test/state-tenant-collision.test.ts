/**
 * Cross-tenant collision proofs for the Chat SDK's OWN state (charter D160).
 *
 * The bridge's thread_session_map is composite-PK-safe (D28/D31), but the SDK's
 * state-pg backend gets ONE global keyPrefix at boot and key_prefix is the only
 * tenant column in all five chat_state_* tables. Two installs whose raw
 * provider thread ids collide (the same human talking to two Telegram bots, or
 * any provider whose ids are only workspace-unique) therefore shared
 * subscriptions, cache entries, and locks — a silent cross-tenant leak
 * underneath a correct-looking core. mountInstall now wraps the shared adapter
 * in scopeStateAdapter(state, connector.id, install.installKey); these tests
 * drive TWO tenants through that exact production path against the SAME raw
 * thread id and prove neither sees the other. With the namespacing removed
 * (scopeStateAdapter as identity), the subscription/cache/lock proofs all go
 * RED — the verifier's Block A triple-leak, pinned.
 *
 * Same harness discipline as thread-session-map.test.ts: a REAL, EPHEMERAL
 * Postgres database, never pg-mem (whose search_path no-op would fabricate the
 * green). No Postgres reachable → loud SKIP; CONNECTORS_REQUIRE_DB=1 (CI)
 * turns that into a hard failure.
 */

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import pg from "pg";
import type { StateAdapter } from "chat";

import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import {
  createBridgeState,
  scopeStateAdapter,
} from "../src/state/state-adapter.js";
import { CHAT_BRIDGE_SCHEMA } from "../src/db/schema.js";

/** Admin connection used only to CREATE/DROP the throwaway test database. */
const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";

const TEST_DB = `connectors_collision_test_${process.pid}_${Date.now()}`;

/**
 * The raw provider thread id BOTH tenants receive. Telegram chat ids are only
 * unique per bot: one human DM'ing two tenants' bots produces the same id on
 * both installs.
 */
const RAW_THREAD_ID = "tg-chat-777";

function urlForDatabase(base: string, database: string): string {
  const url = new URL(base);
  url.pathname = `/${database}`;
  return url.toString();
}

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
if (!reachable && !REQUIRE_DB) {
  console.warn(
    `\n[connectors] SKIPPING the cross-tenant state-collision proofs: no Postgres reachable at ${ADMIN_URL}.\n` +
      `[connectors] These tests prove per-install state isolation against a REAL ephemeral database.\n` +
      `[connectors] Start Postgres (or set CONNECTORS_TEST_DATABASE_URL) to run them.\n` +
      `[connectors] Set CONNECTORS_REQUIRE_DB=1 to make an unreachable database a hard failure.\n`,
  );
}

describe.skipIf(!reachable && !REQUIRE_DB)(
  "Chat SDK state isolation across installs (real Postgres)",
  () => {
    let admin: pg.Client;
    let pool: pg.Pool;
    let shared: ReturnType<typeof createBridgeState>;
    /** The two tenants, derived EXACTLY as mountInstall derives them. */
    let tenantA: StateAdapter;
    let tenantB: StateAdapter;

    beforeAll(async () => {
      if (!reachable && REQUIRE_DB) {
        throw new Error(
          `CONNECTORS_REQUIRE_DB=1 but no Postgres is reachable at ${ADMIN_URL}`,
        );
      }
      admin = new pg.Client({ connectionString: ADMIN_URL });
      await admin.connect();
      await admin.query(`CREATE DATABASE ${TEST_DB}`);

      // The exact production wiring: one schema-pinned pool, ONE shared
      // state-pg adapter (startBridge), then a per-install scope at mount
      // (mountInstall). Two installs of the same provider — the shape
      // workspace-only prefixing would NOT isolate.
      pool = createBridgePool({
        connectionString: urlForDatabase(ADMIN_URL, TEST_DB),
      });
      await ensureBridgeSchema(pool);
      shared = createBridgeState(pool);
      await shared.connect();
      tenantA = scopeStateAdapter(shared, "telegram", "install-team-a");
      tenantB = scopeStateAdapter(shared, "telegram", "install-team-b");
    }, 30_000);

    afterAll(async () => {
      await shared?.disconnect();
      await pool?.end();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)`);
        await admin.end();
      }
    }, 30_000);

    it("does not leak SUBSCRIPTIONS: tenant A subscribing never subscribes tenant B", async () => {
      await tenantA.subscribe(RAW_THREAD_ID);

      // A sees its own subscription; B, asking about the SAME raw id, does not.
      expect(await tenantA.isSubscribed(RAW_THREAD_ID)).toBe(true);
      expect(await tenantB.isSubscribed(RAW_THREAD_ID)).toBe(false);

      // And unsubscribing B's (nonexistent) view never tears down A's.
      await tenantB.unsubscribe(RAW_THREAD_ID);
      expect(await tenantA.isSubscribed(RAW_THREAD_ID)).toBe(true);

      await tenantA.unsubscribe(RAW_THREAD_ID);
      expect(await tenantA.isSubscribed(RAW_THREAD_ID)).toBe(false);
    });

    it("does not leak CACHE: the SDK's thread-keyed values stay per tenant", async () => {
      // The SDK builds keys like `slack:thread-participants:${threadId}` — no
      // tenant component. Same key, two tenants.
      const key = `telegram:thread-participants:${RAW_THREAD_ID}`;

      await tenantA.set(key, ["alice@team-a"]);
      expect(await tenantB.get(key)).toBeNull();

      await tenantB.set(key, ["bob@team-b"]);
      expect(await tenantA.get<string[]>(key)).toEqual(["alice@team-a"]);
      expect(await tenantB.get<string[]>(key)).toEqual(["bob@team-b"]);

      // Deleting B's value never touches A's.
      await tenantB.delete(key);
      expect(await tenantA.get<string[]>(key)).toEqual(["alice@team-a"]);
      expect(await tenantB.get(key)).toBeNull();
    });

    it("does not leak LOCKS: tenant A holding the thread lock never blocks tenant B", async () => {
      const lockA = await tenantA.acquireLock(RAW_THREAD_ID, 30_000);
      expect(lockA).not.toBeNull();

      // Unscoped, this is the deadlock leak: B's turn handler would see A's
      // lock and stall on a thread it has never touched.
      const lockB = await tenantB.acquireLock(RAW_THREAD_ID, 30_000);
      expect(lockB).not.toBeNull();

      // Inverse-mapping: the Lock each caller holds names the id it asked
      // about, not the internal scoped key.
      expect(lockA?.threadId).toBe(RAW_THREAD_ID);
      expect(lockB?.threadId).toBe(RAW_THREAD_ID);

      // Each tenant's OWN re-acquire is still correctly refused...
      expect(await tenantA.acquireLock(RAW_THREAD_ID, 30_000)).toBeNull();

      // ...and the round-tripped Lock releases through the decorator.
      if (lockA) await tenantA.releaseLock(lockA);
      const reacquired = await tenantA.acquireLock(RAW_THREAD_ID, 30_000);
      expect(reacquired).not.toBeNull();

      if (reacquired) await tenantA.releaseLock(reacquired);
      if (lockB) await tenantB.releaseLock(lockB);
    });

    it("does not leak QUEUES: tenant A's pending messages never surface in tenant B", async () => {
      const entry = {
        enqueuedAt: Date.now(),
        expiresAt: Date.now() + 60_000,
        // The queue stores the SDK's serialized Message; the adapter treats it
        // opaquely, so a minimal shape is enough to prove key isolation.
        message: { id: "m-1", text: "for team A only" },
      };

      await tenantA.enqueue(RAW_THREAD_ID, entry as never, 10);
      expect(await tenantA.queueDepth(RAW_THREAD_ID)).toBe(1);
      expect(await tenantB.queueDepth(RAW_THREAD_ID)).toBe(0);
      expect(await tenantB.dequeue(RAW_THREAD_ID)).toBeNull();

      // A's entry is still there for A.
      expect(await tenantA.queueDepth(RAW_THREAD_ID)).toBe(1);
      await tenantA.dequeue(RAW_THREAD_ID);
    });

    it("scopes at the STORAGE layer: the persisted keys carry connector.id + installKey", async () => {
      // Not workspace-only (D160): connector_installs' PK is
      // (provider, install_key), so this prefix isolates even two installs of
      // one provider inside one workspace.
      await tenantA.subscribe(RAW_THREAD_ID);

      const { rows } = await pool.query<{ thread_id: string }>(
        `SELECT thread_id FROM ${CHAT_BRIDGE_SCHEMA}.chat_state_subscriptions
        WHERE thread_id LIKE '%' || $1`,
        [RAW_THREAD_ID],
      );

      expect(rows).toEqual([
        { thread_id: `telegram:install-team-a:${RAW_THREAD_ID}` },
      ]);

      await tenantA.unsubscribe(RAW_THREAD_ID);
    });
  },
);
