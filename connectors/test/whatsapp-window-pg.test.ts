/**
 * Durable WhatsApp 24h-window store, proven against a REAL, EPHEMERAL Postgres
 * (charter D43/D169). The in-memory store (policy/whatsapp-window.ts) loses every
 * recorded inbound on process restart — so on the next deploy a business-initiated
 * free-form send reads `no-inbound-recorded` and is silently refused. This suite
 * pins the Postgres-backed store that survives a restart.
 *
 * Same discipline as test/thread-session-map.test.ts: a per-pid throwaway database
 * created and dropped here, a `postgresReachable` guard that SKIPS loudly rather
 * than pretend, and CONNECTORS_REQUIRE_DB=1 (CI) to turn an unreachable database
 * into a hard failure. Never Barkpark's own database, never pg-mem — pg-mem accepts
 * `SET search_path` as a no-op, so it cannot prove the table lands in `chat_bridge`,
 * and it diverges from Postgres on `GREATEST` over a fresh connection.
 *
 * The restart proof is RED-FIRST by contrast: an in-memory store, "restarted" by
 * constructing a fresh instance, provably reads back null; the Postgres store, read
 * through a SECOND pool opened on the same database after the first is fully ended,
 * reads back the persisted timestamp. Persistence is the only difference.
 */

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import pg from "pg";

import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import { createPgWhatsappWindowStore } from "../src/state/whatsapp-window-store.js";
import { createInMemoryWhatsappWindowStore } from "../src/policy/whatsapp-window.js";

/** Admin connection used only to CREATE/DROP the throwaway test database. */
const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";

const TEST_DB = `connectors_wa_window_test_${process.pid}_${Date.now()}`;

const HOUR = 60 * 60 * 1000;
// A fixed epoch — the store's monotonicity must not depend on the wall clock.
const T0 = 1_752_451_200_000; // 2025-07-14T00:00:00Z

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
    `\n[connectors] SKIPPING the whatsapp-window persistence proofs: no Postgres reachable at ${ADMIN_URL}.\n` +
      `[connectors] These prove the durable 24h-window store survives a restart against a REAL ephemeral\n` +
      `[connectors] database. Start Postgres (or set CONNECTORS_TEST_DATABASE_URL) to run them.\n` +
      `[connectors] Set CONNECTORS_REQUIRE_DB=1 to make an unreachable database a hard failure.\n`,
  );
}

describe.skipIf(!reachable && !REQUIRE_DB)(
  "whatsapp_window store (real Postgres)",
  () => {
    let admin: pg.Client;
    let pool: pg.Pool;
    let testUrl: string;

    beforeAll(async () => {
      if (!reachable && REQUIRE_DB) {
        throw new Error(
          `CONNECTORS_REQUIRE_DB=1 but no Postgres is reachable at ${ADMIN_URL}`,
        );
      }
      admin = new pg.Client({ connectionString: ADMIN_URL });
      await admin.connect();
      await admin.query(`CREATE DATABASE ${TEST_DB}`);
      testUrl = urlForDatabase(ADMIN_URL, TEST_DB);

      // The exact production wiring, against the throwaway database.
      pool = createBridgePool({ connectionString: testUrl });
      await ensureBridgeSchema(pool);
    }, 30_000);

    afterAll(async () => {
      await pool?.end();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)`);
        await admin.end();
      }
    }, 30_000);

    it("creates chat_bridge.whatsapp_window with a composite (workspace_id, thread_id) PK", async () => {
      // The boot DDL, not an Ecto migration, is what creates this table — and it
      // must be composite-keyed so one tenant's inbound never opens another's window.
      const located = await pool.query<{
        table_schema: string;
        table_name: string;
      }>(
        `SELECT table_schema, table_name
           FROM information_schema.tables
          WHERE table_name = 'whatsapp_window'`,
      );
      expect(located.rows).toEqual([
        { table_schema: "chat_bridge", table_name: "whatsapp_window" },
      ]);

      const pk = await pool.query<{ attname: string }>(
        `SELECT a.attname
           FROM pg_index i
           JOIN pg_attribute a
             ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
          WHERE i.indrelid = 'chat_bridge.whatsapp_window'::regclass
            AND i.indisprimary
          ORDER BY a.attnum`,
      );
      expect(pk.rows.map((r) => r.attname)).toEqual(["workspace_id", "thread_id"]);
    });

    it("records and reads back the last inbound timestamp", async () => {
      const store = createPgWhatsappWindowStore(pool);
      expect(await store.getLastInboundAt("ws-a", "wa-1")).toBeNull();

      await store.recordInbound("ws-a", "wa-1", T0);
      expect(await store.getLastInboundAt("ws-a", "wa-1")).toBe(T0);
    });

    it("is monotonic: an out-of-order webhook never moves the window backwards", async () => {
      const store = createPgWhatsappWindowStore(pool);

      await store.recordInbound("ws-mono", "wa-mono", T0 + HOUR);
      // A late-delivered EARLIER inbound must not reopen a window from the past.
      await store.recordInbound("ws-mono", "wa-mono", T0);
      expect(await store.getLastInboundAt("ws-mono", "wa-mono")).toBe(T0 + HOUR);

      // A genuinely newer inbound still advances it.
      await store.recordInbound("ws-mono", "wa-mono", T0 + 2 * HOUR);
      expect(await store.getLastInboundAt("ws-mono", "wa-mono")).toBe(
        T0 + 2 * HOUR,
      );
    });

    it("isolates tenants: the same raw thread id under two workspaces has independent windows", async () => {
      const store = createPgWhatsappWindowStore(pool);

      await store.recordInbound("ws-one", "collide-99", T0);
      // A different tenant's identically-named thread is a MISS, not a share.
      expect(await store.getLastInboundAt("ws-two", "collide-99")).toBeNull();

      await store.recordInbound("ws-two", "collide-99", T0 + 5 * HOUR);
      expect(await store.getLastInboundAt("ws-one", "collide-99")).toBe(T0);
      expect(await store.getLastInboundAt("ws-two", "collide-99")).toBe(
        T0 + 5 * HOUR,
      );
    });

    it("survives a process restart — a fresh pool + store on the same DB reads the persisted window", async () => {
      // RED-FIRST contrast: the in-memory store, "restarted" by constructing a
      // new instance, has forgotten everything. This is exactly the amnesia that
      // silently refuses a proactive send after every deploy.
      const mem = createInMemoryWhatsappWindowStore();
      await mem.recordInbound("ws-restart", "wa-r", T0);
      expect(
        await createInMemoryWhatsappWindowStore().getLastInboundAt(
          "ws-restart",
          "wa-r",
        ),
      ).toBeNull();

      // Now the durable store: write through pool A, then FULLY END pool A so no
      // connection or in-process cache can serve the read.
      const poolA = createBridgePool({ connectionString: testUrl });
      await createPgWhatsappWindowStore(poolA).recordInbound(
        "ws-restart",
        "wa-r",
        T0,
      );
      await poolA.end();

      // A brand-new pool + a brand-new store instance — the closest thing to a
      // restarted process without forking one — must read the window back.
      const poolB = createBridgePool({ connectionString: testUrl });
      try {
        expect(
          await createPgWhatsappWindowStore(poolB).getLastInboundAt(
            "ws-restart",
            "wa-r",
          ),
        ).toBe(T0);
      } finally {
        await poolB.end();
      }
    }, 30_000);

    it("is idempotent under the boot DDL: ensureBridgeSchema can run again", async () => {
      await expect(ensureBridgeSchema(pool)).resolves.toBeUndefined();
      // …and the window written earlier is still there afterwards.
      expect(
        await createPgWhatsappWindowStore(pool).getLastInboundAt("ws-a", "wa-1"),
      ).toBe(T0);
    });
  },
);
