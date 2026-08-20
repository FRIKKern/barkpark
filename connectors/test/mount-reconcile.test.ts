/**
 * THE REPLICA-REDISCOVERY RECONCILE (charter D83) — against a REAL Postgres,
 * because the whole point is that ONE process converges its in-memory mount
 * index against a row ANOTHER process wrote, and a fake table cannot model "two
 * connections, one truth".
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE BUG THIS FILE EXISTS TO PIN
 * ─────────────────────────────────────────────────────────────────────────────
 * `WebhookMountIndex` is a per-process in-memory `Map` (`http/mounts.ts`). Boot
 * mounts every row THIS process can see, and `Bridge.addInstall` mounts anything a
 * connect/OAuth request handled HERE lands — but a horizontally-scaled bridge has
 * more than one process. Replica A handles the "Add to Slack" callback, writes the
 * `connector_installs` row, and mounts it in ITS OWN index. Replica B never saw the
 * request: its index is stale and it answers the opaque 404 of an unknown route for
 * that tenant's webhook until it is restarted.
 *
 * The test models exactly that split brain with NO second deploy: two independently
 * constructed mount-index+reconcile instances in ONE vitest process over ONE
 * Postgres. Replica A mounts an install through its `addInstall`; a row is written
 * through a SECOND pg connection (how "another replica wrote it" looks on the wire);
 * replica B is pinned STALE (handlerFor undefined) and then made routable by ONE
 * `reconcileOnce()` — and the DELETE side unmounts symmetrically.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * WHAT THIS TEST DELIBERATELY DOES NOT PROVE (honest scope)
 * ─────────────────────────────────────────────────────────────────────────────
 * It proves the WEBHOOK mount index rediscovers rows. It does NOT prove poll/socket
 * replica-safety (Telegram getUpdates, Discord gateway) — converging those through
 * this loop is the SEPARATE hazard `connectors-replica-socket-poll-safety`, and the
 * reconcile enumerates ONLY webhook connectors precisely so it never touches them.
 * The "poll/socket connectors are never reconciled" case below pins that boundary.
 */
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { randomBytes } from "node:crypto";
import pg from "pg";

import {
  createMountReconcile,
  type MountReconcile,
} from "../src/http/mount-reconcile.js";
import {
  createWebhookMountIndex,
  type WebhookCapableChat,
  type WebhookHandler,
  type WebhookMountIndex,
} from "../src/http/mounts.js";
import { createConnectorRegistry } from "../src/connector/registry.js";
import { createCredentialCipher } from "../src/crypto/credential-cipher.js";
import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import {
  createInstallsLookup,
  deleteInstall,
  upsertInstall,
} from "../src/tenant/installs.js";
import type { Adapter } from "chat";
import type {
  Connector,
  ConnectorInstall,
  MutableInstallsLookup,
} from "../src/connector/types.js";

const cipher = createCredentialCipher({ key: randomBytes(32).toString("base64") });

const WS_A = "11111111-1111-4111-8111-111111111111";
const WS_B = "22222222-2222-4222-8222-222222222222";

const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";
const TEST_DB = `connectors_mount_reconcile_test_${process.pid}_${Date.now()}`;

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

// ---------------------------------------------------------------------------
// A webhook channel connector is ONE registry entry + a `webhook` block. A
// poll/socket connector is the same shape WITHOUT `webhook`. The reconcile keys
// entirely off that member, so both live in one registry for the boundary test.
// ---------------------------------------------------------------------------
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

function pollConnector(id: string): Connector {
  return {
    id,
    direction: "channel",
    auth: "token",
    tenantResolution: "credential-bound",
    adapterFactory: () => ({}) as Adapter,
    async resolveTenant() {
      return null;
    },
    // No `webhook`: transport is a poll loop / gateway socket, started in listen().
    async listen() {},
  };
}

// A TOOL connector (charter D69) — the OUTBOUND direction. It is DOUBLE-excluded
// from the reconcile: `registry.channels()` drops it on `direction: "tool"`, and it
// declares no `webhook`. Either exclusion alone would keep its rows untouched; the
// boundary test below proves the whole (register a tool, plant a tool row, reconcile,
// and it is left entirely alone — never listed, never mounted).
function toolConnector(id: string): Connector {
  return {
    id,
    direction: "tool",
    auth: "token",
    tenantResolution: "credential-bound",
    toolDescriptor: { type: "http", url: "http://mcp.invalid/" },
    adapterFactory: () => ({}) as Adapter,
    async resolveTenant() {
      return null;
    },
  };
}

// The seam only ever touches `.webhooks[provider]`; a fake Chat is that map.
function fakeChat(provider: string): WebhookCapableChat {
  const handler: WebhookHandler = async () =>
    new Response(JSON.stringify({ ok: true }), { status: 200 });
  return { webhooks: { [provider]: handler } };
}

/**
 * One bridge REPLICA: an isolated mount index, and the `addInstall`/`removeInstall`
 * a connect/OAuth request on THIS process would run — mounting a fake Chat rather
 * than building a real one, because the index, not the Chat, is under test. Mirrors
 * the production `addInstall`'s replace-then-mount semantics.
 */
function makeReplica(registry: ReturnType<typeof createConnectorRegistry>): {
  mounts: WebhookMountIndex;
  addInstall: (install: ConnectorInstall) => Promise<unknown>;
  removeInstall: (provider: string, installKey: string) => Promise<boolean>;
} {
  const mounts = createWebhookMountIndex();
  const removeInstall = async (provider: string, installKey: string) =>
    mounts.unmount(provider, installKey);
  const addInstall = async (install: ConnectorInstall) => {
    const connector = registry.get(install.provider);
    if (!connector) {
      throw new Error(`no connector for provider "${install.provider}"`);
    }
    // Replace, exactly like Bridge.addInstall: a re-point must not leave the old
    // mount behind.
    await removeInstall(install.provider, install.installKey);
    mounts.mount({ connector, install, chat: fakeChat(install.provider) });
    return { connector, install };
  };
  return { mounts, addInstall, removeInstall };
}

describe.skipIf(!reachable && !REQUIRE_DB)(
  "webhook mount reconcile — a replica rediscovers installs written by another process (D83, real Postgres)",
  () => {
    const SLACK = "slack";
    const GITHUB = "github";
    const KEY = "T_TEAM_A";

    let admin: pg.Client;
    let readerPool: pg.Pool;
    let writerPool: pg.Pool;
    let readerInstalls: MutableInstallsLookup;
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

      const url = new URL(ADMIN_URL);
      url.pathname = `/${TEST_DB}`;
      // TWO independent pools to the SAME database — the reconcile reads through
      // `readerPool`, the "other replica" writes through `writerPool`. Distinct
      // connections are the whole point: one process cannot see the other's
      // in-memory state, only the shared table.
      readerPool = createBridgePool({ connectionString: url.toString() });
      writerPool = createBridgePool({ connectionString: url.toString() });
      await ensureBridgeSchema(readerPool);
      readerInstalls = createInstallsLookup(readerPool, cipher);

      registry = createConnectorRegistry();
      registry.register(webhookConnector(SLACK));
      registry.register(pollConnector("telegram"));
      registry.register(toolConnector(GITHUB));
    }, 30_000);

    afterAll(async () => {
      await readerPool?.end();
      await writerPool?.end();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)`);
        await admin.end();
      }
    }, 30_000);

    afterEach(async () => {
      await readerPool.query("DELETE FROM chat_bridge.connector_installs");
    });

    const slackInstall = (workspaceId: string): ConnectorInstall => ({
      provider: SLACK,
      installKey: KEY,
      workspaceId,
      credentialRef: "slack-signing-secret",
      chatToken: "bp_chat_ws_token",
    });

    const reconcileFor = (
      replica: ReturnType<typeof makeReplica>,
    ): MountReconcile =>
      createMountReconcile(
        {
          registry,
          installs: readerInstalls,
          mounts: replica.mounts,
          addInstall: replica.addInstall,
          removeInstall: replica.removeInstall,
        },
        // intervalMs 0: no timer arms — we drive reconcileOnce() deterministically.
        { intervalMs: 0 },
      );

    // ───────────────────────────────────────────────────────────────────────
    // THE HEADLINE: split brain, then convergence.
    // ───────────────────────────────────────────────────────────────────────
    it("rediscovers a row a SECOND connection wrote: stale before reconcile, routable after", async () => {
      const install = slackInstall(WS_A);

      // Replica A handled the connect: it mounted the install in ITS OWN index.
      const replicaA = makeReplica(registry);
      await replicaA.addInstall(install);
      expect(replicaA.mounts.handlerFor(install)).toBeDefined();

      // The row lands in the shared table through a DIFFERENT connection — this is
      // what "another replica wrote it" looks like on the wire.
      await upsertInstall(writerPool, cipher, install);

      // Replica B never saw the request. STALE: its index has no mount, so the
      // fail-closed keystone hands back undefined — the opaque-404 path.
      const replicaB = makeReplica(registry);
      const reconcileB = reconcileFor(replicaB);
      expect(replicaB.mounts.handlerFor(install)).toBeUndefined();

      // ONE reconcile pass re-reads the table and converges through addInstall.
      const summary = await reconcileB.reconcileOnce();
      expect(summary).toEqual({ added: 1, removed: 0, failures: 0 });

      // Now routable HERE, no restart — and it is the SAME tenant's row.
      const handler = replicaB.mounts.handlerFor(install);
      expect(handler).toBeDefined();
      expect(replicaB.mounts.mountFor(install)?.install.workspaceId).toBe(WS_A);
    });

    it("idempotent: a second pass with nothing changed mounts nothing", async () => {
      const install = slackInstall(WS_A);
      await upsertInstall(writerPool, cipher, install);

      const replica = makeReplica(registry);
      const reconcile = reconcileFor(replica);

      const first = await reconcile.reconcileOnce();
      expect(first).toEqual({ added: 1, removed: 0, failures: 0 });

      const second = await reconcile.reconcileOnce();
      expect(second).toEqual({ added: 0, removed: 0, failures: 0 });
      expect(replica.mounts.handlerFor(install)).toBeDefined();
    });

    // ───────────────────────────────────────────────────────────────────────
    // THE DELETE SIDE: a disconnect on another replica unmounts here.
    // ───────────────────────────────────────────────────────────────────────
    it("unmounts symmetrically when the row disappears (a disconnect on another replica)", async () => {
      const install = slackInstall(WS_A);
      await upsertInstall(writerPool, cipher, install);

      const replica = makeReplica(registry);
      const reconcile = reconcileFor(replica);
      await reconcile.reconcileOnce();
      expect(replica.mounts.handlerFor(install)).toBeDefined();

      // Another replica handled DISCONNECT: the row is gone from the shared table.
      await deleteInstall(writerPool, SLACK, KEY);
      expect(replica.mounts.handlerFor(install)).toBeDefined(); // still stale-mounted

      const summary = await reconcile.reconcileOnce();
      expect(summary).toEqual({ added: 0, removed: 1, failures: 0 });
      expect(replica.mounts.handlerFor(install)).toBeUndefined();
    });

    // ───────────────────────────────────────────────────────────────────────
    // A RE-POINT: the row moved to another workspace on another replica.
    // ───────────────────────────────────────────────────────────────────────
    it("re-points a mount when the row's workspace changed underneath it", async () => {
      const installA = slackInstall(WS_A);

      const replica = makeReplica(registry);
      const reconcile = reconcileFor(replica);
      await upsertInstall(writerPool, cipher, installA);
      await reconcile.reconcileOnce();
      expect(replica.mounts.mountFor(installA)?.install.workspaceId).toBe(WS_A);

      // The install moved to workspace B (deleted + re-created under a new tenant —
      // the write path NULLs the identity-bound secrets on a move, so re-paste).
      await deleteInstall(writerPool, SLACK, KEY);
      const installB = slackInstall(WS_B);
      await upsertInstall(writerPool, cipher, installB);

      // mountFor(installB) is undefined — the mounted row is A's, the workspace
      // check fails closed — so the reconcile re-points via addInstall's replace.
      expect(replica.mounts.mountFor(installB)).toBeUndefined();
      const summary = await reconcile.reconcileOnce();
      expect(summary.added).toBe(1);
      expect(summary.removed).toBe(0);
      expect(replica.mounts.mountFor(installB)?.install.workspaceId).toBe(WS_B);
      // The stale A-mount is gone: addInstall's takeDown replaced it, so the index
      // does not carry two rows for one (provider, installKey).
      expect(replica.mounts.list()).toHaveLength(1);
    });

    // ───────────────────────────────────────────────────────────────────────
    // THE BOUNDARY: poll/socket connectors are NEVER reconciled (D83 scope).
    // ───────────────────────────────────────────────────────────────────────
    it("never touches a poll/socket connector's rows — that is a separate hazard", async () => {
      // A telegram row exists in the shared table…
      await upsertInstall(writerPool, cipher, {
        provider: "telegram",
        installKey: "bot-123",
        workspaceId: WS_A,
        credentialRef: "telegram-bot-token",
        chatToken: "bp_chat_ws_token",
      });

      const replica = makeReplica(registry);
      const reconcile = reconcileFor(replica);
      const summary = await reconcile.reconcileOnce();

      // …and the reconcile leaves it entirely alone: mounting it here would start a
      // SECOND getUpdates loop against the same bot (a 409-Conflict). That safety
      // belongs to connectors-replica-socket-poll-safety, not this loop.
      expect(summary).toEqual({ added: 0, removed: 0, failures: 0 });
      expect(replica.mounts.size()).toBe(0);
    });

    // ───────────────────────────────────────────────────────────────────────
    // THE BOUNDARY, OTHER DIRECTION: TOOL connectors are NEVER reconciled (D69).
    // ───────────────────────────────────────────────────────────────────────
    it("never touches a TOOL-direction connector's rows — it has no channel mount at all", async () => {
      // A tool (GitHub) install exists in the shared table — a sealed PAT, no chat
      // token, exactly what the tool connect loop writes.
      await upsertInstall(writerPool, cipher, {
        provider: GITHUB,
        installKey: "gh-install-1",
        workspaceId: WS_A,
        credentialRef: "ghp_a_personal_access_token",
        chatToken: null,
      });

      const replica = makeReplica(registry);
      const reconcile = reconcileFor(replica);
      const summary = await reconcile.reconcileOnce();

      // The reconcile enumerates ONLY webhook CHANNELS — `registry.channels()` drops
      // the tool on direction, and it has no `webhook` either. So the row is never
      // listed and never mounted: mounting a tool as a Chat is a category error (it
      // has no inbound transport; the agent reaches it over MCP, not this bridge).
      expect(summary).toEqual({ added: 0, removed: 0, failures: 0 });
      expect(replica.mounts.size()).toBe(0);
    });

    // ───────────────────────────────────────────────────────────────────────
    // CONTAINMENT: one poisoned mount does not stall the tick (loud, not fatal).
    // ───────────────────────────────────────────────────────────────────────
    it("reports a per-install failure and keeps going — a poisoned row cannot stall the tick", async () => {
      const good = slackInstall(WS_A);
      const bad: ConnectorInstall = {
        provider: SLACK,
        installKey: "T_TEAM_BAD",
        workspaceId: WS_B,
        credentialRef: "x",
        chatToken: "y",
      };
      await upsertInstall(writerPool, cipher, good);
      await upsertInstall(writerPool, cipher, bad);

      const replica = makeReplica(registry);
      // addInstall throws for exactly the bad key (a revoked-credential mount), the
      // way the real bringUp throws on chat.initialize().
      const rawAdd = replica.addInstall;
      const failures: string[] = [];
      const failingReplica = {
        ...replica,
        addInstall: async (install: ConnectorInstall) => {
          if (install.installKey === "T_TEAM_BAD") {
            throw new Error("credential revoked");
          }
          return rawAdd(install);
        },
      };
      const reconcile = createMountReconcile(
        {
          registry,
          installs: readerInstalls,
          mounts: failingReplica.mounts,
          addInstall: failingReplica.addInstall,
          removeInstall: failingReplica.removeInstall,
        },
        {
          intervalMs: 0,
          onError: (context) => failures.push(context),
        },
      );

      const summary = await reconcile.reconcileOnce();
      // The healthy install mounted; the poisoned one was counted and reported.
      expect(summary.added).toBe(1);
      expect(summary.failures).toBe(1);
      expect(replica.mounts.handlerFor(good)).toBeDefined();
      expect(failures.some((c) => c.includes("T_TEAM_BAD"))).toBe(true);
    });
  },
);
