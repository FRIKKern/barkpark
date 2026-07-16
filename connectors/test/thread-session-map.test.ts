/**
 * Proofs for the bridge's state layer (charter D28).
 *
 * The schema-isolation proof runs against a REAL, EPHEMERAL Postgres database
 * (created and dropped by this file) — never Barkpark's own database, and
 * deliberately NOT against pg-mem: pg-mem accepts `SET search_path` as a no-op
 * and reports every table in `public`, so it is structurally incapable of
 * proving the one thing that matters here (that the SDK's unqualified DDL lands
 * in `chat_bridge`). A green from pg-mem would be a fabricated green. It also
 * diverges from Postgres on `ON CONFLICT DO NOTHING ... RETURNING` (it returns
 * the conflicting row; Postgres returns no rows), which is exactly the branch
 * resolveOrMint relies on.
 *
 * When no Postgres is reachable these tests SKIP loudly rather than pretend.
 * Set CONNECTORS_REQUIRE_DB=1 (CI) to turn an unreachable database into a hard
 * failure instead of a skip.
 */

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import pg from "pg";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createBridgePool,
  ensureBridgeSchema,
  SchemaIsolationError,
} from "../src/db/pool.js";
import { createBridgeState } from "../src/state/state-adapter.js";
import {
  createPgLockedThreadSessionMap,
  createPgThreadSessionStore,
  createThreadSessionMap,
} from "../src/state/thread-session-map.js";
import { CHAT_BRIDGE_SCHEMA } from "../src/db/schema.js";
import type {
  ChatClient,
  ChatEvent,
  ChatSession,
  PostMessageResult,
} from "../src/chat-client/types.js";

/** Admin connection used only to CREATE/DROP the throwaway test database. */
const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";

const TEST_DB = `connectors_bridge_test_${process.pid}_${Date.now()}`;

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

/**
 * A faithful stand-in for the /v1/chat transport: it mints a fresh Session UUID
 * on every call (exactly as POST /v1/chat/sessions does — there is no
 * find-or-create server-side) and counts the mints, so a test can prove the map
 * itself is what makes resume idempotent.
 */
class SpyChatClient implements ChatClient {
  createSessionCalls = 0;
  private next = 0;

  private session(id: string): ChatSession {
    return {
      id,
      title: null,
      status: "idle",
      mode: "plan",
      model: null,
      cwd: "/tmp",
      message_count: 0,
    };
  }

  async createSession(): Promise<ChatSession> {
    this.createSessionCalls += 1;
    this.next += 1;
    return this.session(
      `00000000-0000-4000-8000-${String(this.next).padStart(12, "0")}`,
    );
  }

  async getSession(id: string): Promise<ChatSession> {
    return this.session(id);
  }

  async postMessage(): Promise<PostMessageResult> {
    return { accepted: true };
  }

  async openEventStream(): Promise<AsyncIterable<ChatEvent>> {
    return {
      // eslint-disable-next-line require-yield
      async *[Symbol.asyncIterator]() {
        return;
      },
    };
  }
}

const reachable = await postgresReachable();
if (!reachable && !REQUIRE_DB) {
  console.warn(
    `\n[connectors] SKIPPING the state-layer proofs: no Postgres reachable at ${ADMIN_URL}.\n` +
      `[connectors] These tests prove schema isolation and session-mint idempotency against a REAL\n` +
      `[connectors] ephemeral database. Start Postgres (or set CONNECTORS_TEST_DATABASE_URL) to run them.\n` +
      `[connectors] Set CONNECTORS_REQUIRE_DB=1 to make an unreachable database a hard failure.\n`,
  );
}

describe.skipIf(!reachable && !REQUIRE_DB)(
  "bridge state layer (real Postgres)",
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

    it("pins search_path on EVERY connection the pool opens, not just the first", async () => {
      // Deliberately concurrent: node-postgres reuses an idle connection, so a
      // single query would happily read back a leftover session `SET` from setup
      // and prove nothing. Forcing several connections open at once means these
      // are fresh backends whose search_path can only come from the startup
      // options — which is what state-pg's unqualified DDL actually depends on.
      const CONNECTIONS = 5;
      const clients = await Promise.all(
        Array.from({ length: CONNECTIONS }, () => pool.connect()),
      );
      try {
        const paths = await Promise.all(
          clients.map(async (c) => {
            const { rows } = await c.query<{ search_path: string }>(
              "SHOW search_path",
            );
            return rows[0]?.search_path;
          }),
        );
        expect(paths).toEqual(Array(CONNECTIONS).fill(CHAT_BRIDGE_SCHEMA));
      } finally {
        clients.forEach((c) => c.release());
      }
    });

    it("fails closed when handed a pool that is NOT pinned to chat_bridge", async () => {
      // The pin is the only thing keeping state-pg's five unqualified tables out
      // of Barkpark's `public` schema. If it is ever lost, the bridge must refuse
      // to boot rather than quietly pollute Ecto's schema.
      const unpinned = new pg.Pool({ connectionString: testUrl });
      try {
        await expect(ensureBridgeSchema(unpinned)).rejects.toThrow(
          SchemaIsolationError,
        );
        // And it created nothing in public on the way out.
        const { rows } = await unpinned.query(
          `SELECT table_name FROM information_schema.tables
          WHERE table_schema = 'public'
            AND table_name IN ('thread_session_map', 'connector_installs')`,
        );
        expect(rows).toEqual([]);
      } finally {
        await unpinned.end();
      }
    });

    it("creates thread_session_map and connector_installs in chat_bridge, not public", async () => {
      const { rows } = await pool.query<{
        table_schema: string;
        table_name: string;
      }>(
        `SELECT table_schema, table_name
         FROM information_schema.tables
        WHERE table_name IN ('thread_session_map', 'connector_installs')
        ORDER BY table_name`,
      );

      expect(rows).toEqual([
        { table_schema: "chat_bridge", table_name: "connector_installs" },
        { table_schema: "chat_bridge", table_name: "thread_session_map" },
      ]);
      // And nothing of ours leaked into public.
      expect(rows.filter((r) => r.table_schema === "public")).toEqual([]);
    });

    it("lands @chat-adapter/state-pg's five tables in chat_bridge, never public", async () => {
      // The whole point of D28: state-pg issues UNQUALIFIED `CREATE TABLE IF NOT
      // EXISTS` and exposes no schema option, so the pool's search_path is the
      // only thing keeping its tables off Barkpark's Ecto-owned public schema.
      const state = createBridgeState(pool);
      await state.connect();

      const { rows } = await pool.query<{
        table_schema: string;
        table_name: string;
      }>(
        `SELECT table_schema, table_name
         FROM information_schema.tables
        WHERE table_name LIKE 'chat_state_%'
        ORDER BY table_name`,
      );

      expect(rows.map((r) => r.table_name)).toEqual([
        "chat_state_cache",
        "chat_state_lists",
        "chat_state_locks",
        "chat_state_queues",
        "chat_state_subscriptions",
      ]);
      for (const row of rows) {
        expect(row.table_schema).toBe(CHAT_BRIDGE_SCHEMA);
      }

      const leaked = await pool.query(
        `SELECT table_name FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name LIKE 'chat_state_%'`,
      );
      expect(leaked.rows).toEqual([]);

      await state.disconnect();
    }, 30_000);

    it("is idempotent: ensureBridgeSchema can run again on every boot", async () => {
      await expect(ensureBridgeSchema(pool)).resolves.toBeUndefined();
    });

    describe("resolveOrMint", () => {
      it("mints exactly ONE session on first message and resumes it thereafter", async () => {
        const chat = new SpyChatClient();
        const map = createThreadSessionMap(createPgThreadSessionStore(pool));
        const mint = async () => (await chat.createSession()).id;

        const first = await map.resolveOrMint("ws-alpha", "tg-chat-1", mint);
        expect(chat.createSessionCalls).toBe(1);
        expect(first.minted).toBe(true);

        const second = await map.resolveOrMint("ws-alpha", "tg-chat-1", mint);
        const third = await map.resolveOrMint("ws-alpha", "tg-chat-1", mint);

        // Resume, not re-mint: /v1/chat would hand out a NEW uuid every call, so
        // the map is what makes the conversation continuous.
        expect(second.sessionUuid).toBe(first.sessionUuid);
        expect(third.sessionUuid).toBe(first.sessionUuid);
        expect(second.minted).toBe(false);
        expect(third.minted).toBe(false);
        expect(chat.createSessionCalls).toBe(1);

        const { rows } = await pool.query(
          "SELECT session_uuid FROM chat_bridge.thread_session_map WHERE workspace_id = $1 AND thread_id = $2",
          ["ws-alpha", "tg-chat-1"],
        );
        expect(rows).toEqual([{ session_uuid: first.sessionUuid }]);
      });

      it("never calls mint on a resume — the SDK/API is not asked for a second Session", async () => {
        const chat = new SpyChatClient();
        const map = createThreadSessionMap(createPgThreadSessionStore(pool));
        let mintCalls = 0;
        const mint = async () => {
          mintCalls += 1;
          return (await chat.createSession()).id;
        };

        await map.resolveOrMint("ws-mintonce", "thread-1", mint);
        await map.resolveOrMint("ws-mintonce", "thread-1", mint);
        await map.resolveOrMint("ws-mintonce", "thread-1", mint);

        // The callback is the ONLY way a Barkpark Session gets created. If the map
        // ever invoked it on a hit, every message would start a fresh, amnesiac
        // Session — the exact failure this table exists to prevent.
        expect(mintCalls).toBe(1);
      });

      it("gives distinct threads distinct sessions", async () => {
        const chat = new SpyChatClient();
        const map = createThreadSessionMap(createPgThreadSessionStore(pool));
        const mint = async () => (await chat.createSession()).id;

        const a = await map.resolveOrMint("ws-beta", "thread-a", mint);
        const b = await map.resolveOrMint("ws-beta", "thread-b", mint);

        expect(a.sessionUuid).not.toBe(b.sessionUuid);
        expect(chat.createSessionCalls).toBe(2);
      });

      it("isolates tenants: the same raw thread id in two workspaces never shares a Session", async () => {
        const chat = new SpyChatClient();
        const map = createThreadSessionMap(createPgThreadSessionStore(pool));
        const mint = async () => (await chat.createSession()).id;

        // Telegram chat ids are only unique per bot — without the workspace in
        // the key, two tenants could land in each other's conversation.
        const one = await map.resolveOrMint("ws-one", "collide-42", mint);
        const two = await map.resolveOrMint("ws-two", "collide-42", mint);

        expect(one.sessionUuid).not.toBe(two.sessionUuid);
        expect(
          (await map.resolveOrMint("ws-one", "collide-42", mint)).sessionUuid,
        ).toBe(one.sessionUuid);
        expect(
          (await map.resolveOrMint("ws-two", "collide-42", mint)).sessionUuid,
        ).toBe(two.sessionUuid);
        expect(chat.createSessionCalls).toBe(2);
      });

      it("survives a concurrent first message without splitting the thread", async () => {
        const chat = new SpyChatClient();
        const map = createThreadSessionMap(createPgThreadSessionStore(pool));
        const mint = async () => (await chat.createSession()).id;

        // Two inbound events for the same brand-new thread at once: exactly one
        // binding must win, and both callers must see the winner.
        const [x, y] = await Promise.all([
          map.resolveOrMint("ws-race", "thread-race", mint),
          map.resolveOrMint("ws-race", "thread-race", mint),
        ]);

        expect(x.sessionUuid).toBe(y.sessionUuid);
        // Exactly one of the two racers reports having minted the thread's Session.
        expect([x.minted, y.minted].filter(Boolean)).toHaveLength(1);

        const { rows } = await pool.query(
          "SELECT session_uuid FROM chat_bridge.thread_session_map WHERE workspace_id = $1 AND thread_id = $2",
          ["ws-race", "thread-race"],
        );
        expect(rows).toEqual([{ session_uuid: x.sessionUuid }]);
      });

      it("mints EXACTLY ONE session under a concurrent first message — no orphan (D159)", async () => {
        // The regression the reserve-first factory closes
        // (connectors-orphan-session-on-mint-race). The mint-before-insert path
        // has BOTH racers call mint() and only one wins the insert, so the
        // loser's Barkpark Session is bound to nothing — a leaked chat_sessions
        // row. The :341 race test above proves CONVERGENCE + a single row (which
        // the leaky path already satisfies) but never counts the mints, so it is
        // structurally blind to the orphan. This one pins createSessionCalls.
        const chat = new SpyChatClient();
        const map = createPgLockedThreadSessionMap(pool);
        const mint = async () => (await chat.createSession()).id;

        const [x, y] = await Promise.all([
          map.resolveOrMint("ws-lock-race", "thread-lock-race", mint),
          map.resolveOrMint("ws-lock-race", "thread-lock-race", mint),
        ]);

        // The heart of the fix: only ONE Barkpark Session is ever minted, so no
        // orphan can exist. On origin/main this reads 2 ("expected 2 to be 1").
        expect(chat.createSessionCalls).toBe(1);
        // Both racers still converge on the single winner…
        expect(x.sessionUuid).toBe(y.sessionUuid);
        // …exactly one of them reports having minted it…
        expect([x.minted, y.minted].filter(Boolean)).toHaveLength(1);
        // …and the winner's uuid is the one that was actually minted.
        expect(x.sessionUuid).toBe("00000000-0000-4000-8000-000000000001");

        const { rows } = await pool.query(
          "SELECT session_uuid FROM chat_bridge.thread_session_map WHERE workspace_id = $1 AND thread_id = $2",
          ["ws-lock-race", "thread-lock-race"],
        );
        expect(rows).toEqual([{ session_uuid: x.sessionUuid }]);
      });

      it("resumes a locked-factory thread without minting or taking the lock again", async () => {
        // The fast path: once bound, resolveOrMint reads lock-free and never
        // mints — the reserve-first factory must not regress resume-cheapness.
        const chat = new SpyChatClient();
        const map = createPgLockedThreadSessionMap(pool);
        const mint = async () => (await chat.createSession()).id;

        const first = await map.resolveOrMint("ws-lock-resume", "t-1", mint);
        expect(first.minted).toBe(true);
        expect(chat.createSessionCalls).toBe(1);

        const second = await map.resolveOrMint("ws-lock-resume", "t-1", mint);
        const third = await map.resolveOrMint("ws-lock-resume", "t-1", mint);
        expect(second.sessionUuid).toBe(first.sessionUuid);
        expect(third.sessionUuid).toBe(first.sessionUuid);
        expect(second.minted).toBe(false);
        expect(third.minted).toBe(false);
        expect(chat.createSessionCalls).toBe(1);

        expect(await map.get("ws-lock-resume", "t-1")).toBe(first.sessionUuid);
      });
    });
  },
);

/**
 * Source-level invariant, provable with no database: the Session binding must
 * never ride the Chat SDK's thread state, which hardcodes a 30-day TTL
 * (THREAD_STATE_TTL_MS = 30 * 24 * 60 * 60 * 1e3) and would silently drop the
 * Session of any conversation that goes quiet for a month.
 */
describe("D28 invariant", () => {
  it("never persists the thread->session binding via thread.setState", () => {
    const srcDir = fileURLToPath(new URL("../src", import.meta.url));

    const walk = (dir: string): string[] =>
      readdirSync(dir).flatMap((entry) => {
        const full = join(dir, entry);
        return statSync(full).isDirectory() ? walk(full) : [full];
      });

    // Strip comments first: the modules that explain WHY setState is forbidden
    // name it in prose, and a guard that cannot tell code from a comment would
    // fire on its own documentation.
    const stripComments = (source: string): string =>
      source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1");

    const offenders = walk(srcDir)
      .filter((file) => file.endsWith(".ts"))
      .filter((file) =>
        /\bsetState\b/.test(stripComments(readFileSync(file, "utf8"))),
      );

    expect(offenders).toEqual([]);
  });
});
