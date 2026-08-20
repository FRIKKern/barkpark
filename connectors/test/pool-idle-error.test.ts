/**
 * The bridge must SURVIVE a terminated idle backend.
 *
 * A pg Pool emits 'error' on an idle client whose backend the server killed —
 * a Postgres restart, a failover, an admin `pg_terminate_backend`, an
 * idle-session timeout. That event carries no query to reject into, so with no
 * listener attached Node treats it as an unhandled 'error' event and kills the
 * process. For a long-lived bridge that is the difference between riding out a
 * database restart and dying on one.
 *
 * This is not a hypothetical: it is the bug behind the connectors CI flake. The
 * suites drop their throwaway database `WITH (FORCE)`, Postgres terminates the
 * still-connected backends, and every one of those 57P01s surfaced as an
 * "Unhandled Error" that reddened a run in which all 329 tests passed.
 *
 * Revert the `pool.on("error", …)` listener in createBridgePool and the first
 * test here fails: the error escapes as an unhandled 'error' event.
 */

import pg from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";

const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";

const TEST_DB = `connectors_pool_error_test_${process.pid}_${Date.now()}`;

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

describe.skipIf(!reachable && !REQUIRE_DB)(
  "bridge pool survives a terminated idle backend (real Postgres)",
  () => {
    let admin: pg.Client;
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
    }, 30_000);

    afterAll(async () => {
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)`);
        await admin.end();
      }
    }, 30_000);

    it("reports the killed backend instead of crashing the process", async () => {
      const seen: Error[] = [];
      const pool = createBridgePool({
        connectionString: testUrl,
        onIdleClientError: (err) => seen.push(err),
      });
      await ensureBridgeSchema(pool);

      // Check a connection out and back so the pool holds exactly one IDLE
      // client — the state a server-side termination actually catches.
      await pool.query("SELECT 1");

      // Kill it from the server, exactly as `DROP DATABASE … WITH (FORCE)` and
      // a Postgres restart do. Not from the client: a client-side end() is the
      // graceful path and would prove nothing.
      await admin.query(
        `SELECT pg_terminate_backend(pid) FROM pg_stat_activity
           WHERE datname = $1 AND pid <> pg_backend_pid()`,
        [TEST_DB],
      );

      // The 'error' event is delivered on a later tick than the kill.
      await new Promise((resolve) => setTimeout(resolve, 250));

      expect(seen.length).toBeGreaterThan(0);
      expect(seen.some((e) => /terminat/i.test(e.message))).toBe(true);

      // And the pool is still USABLE: it discards the dead client and opens a
      // fresh one. Survival, not just silence.
      const result = await pool.query("SELECT 1 AS ok");
      expect((result.rows[0] as { ok: number }).ok).toBe(1);

      await pool.end();
    }, 30_000);

    it("attaches the listener even when no callback is supplied", async () => {
      // The listener is what keeps the process alive; the callback only decides
      // whether the event is also recorded. A pool built WITHOUT a callback must
      // still survive — this is the shape every test-suite pool uses, and the
      // one that was crashing CI.
      const pool = createBridgePool({ connectionString: testUrl });
      await pool.query("SELECT 1");

      expect(pool.listenerCount("error")).toBe(1);

      await admin.query(
        `SELECT pg_terminate_backend(pid) FROM pg_stat_activity
           WHERE datname = $1 AND pid <> pg_backend_pid()`,
        [TEST_DB],
      );
      await new Promise((resolve) => setTimeout(resolve, 250));

      const result = await pool.query("SELECT 1 AS ok");
      expect((result.rows[0] as { ok: number }).ok).toBe(1);

      await pool.end();
    }, 30_000);
  },
);
