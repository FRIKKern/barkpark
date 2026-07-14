import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { readFileSync } from "node:fs";
import type { Adapter } from "chat";
import pg from "pg";
import type { Pool } from "pg";

import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import { createConnectorRegistry } from "../src/connector/registry.js";
import type {
  Connector,
  InboundEvent,
  InstallsLookup,
  TenantContext,
} from "../src/connector/types.js";
import {
  createInstallsLookup,
  createInMemoryInstallsLookup,
  type Queryable,
} from "../src/tenant/installs.js";
import {
  resolveCredentialBound,
  createPayloadTeamIdResolver,
  resolveTenantForEvent,
} from "../src/tenant/resolve.js";

// Two tenants. Every assertion below is really asking one question: can workspace A's
// traffic ever reach workspace B?
const WS_A = "11111111-1111-4111-8111-111111111111";
const WS_B = "22222222-2222-4222-8222-222222222222";

const stubAdapter = (): Adapter => ({}) as Adapter;

/**
 * The installs table both tenants share. Telegram is BYO-bot (credential-bound): the
 * install key is the bot binding. Slack is payload-team-id: the install key is the
 * Slack team id.
 */
const installs: InstallsLookup = createInMemoryInstallsLookup([
  {
    provider: "telegram",
    installKey: "bot-a",
    workspaceId: WS_A,
    credentialRef: "secret-WS_A",
  },
  {
    provider: "telegram",
    installKey: "bot-b",
    workspaceId: WS_B,
    credentialRef: "secret-WS_B",
  },
  {
    provider: "slack",
    installKey: "T_AAA",
    workspaceId: WS_A,
    credentialRef: "secret-WS_A",
  },
  {
    provider: "slack",
    installKey: "T_BBB",
    workspaceId: WS_B,
    credentialRef: "secret-WS_B",
  },
  {
    provider: "discord",
    installKey: "guild-a",
    workspaceId: WS_A,
    credentialRef: "secret-WS_A",
  },
]);

const ctx: TenantContext = { installs };

/** A credential-bound connector — the Telegram shape (charter D29). */
const telegramConnector: Connector = {
  id: "telegram",
  direction: "channel",
  auth: "token",
  tenantResolution: "credential-bound",
  adapterFactory: () => stubAdapter(),
  resolveTenant: resolveCredentialBound,
};

/** A payload-team-id connector — the Slack shape (charter D29). */
interface SlackEnvelope {
  team_id?: string;
}

const slackConnector: Connector<SlackEnvelope> = {
  id: "slack",
  direction: "channel",
  auth: "oauth",
  tenantResolution: "payload-team-id",
  adapterFactory: () => stubAdapter(),
  resolveTenant: createPayloadTeamIdResolver<SlackEnvelope>(
    (payload) => payload?.team_id ?? null,
  ),
};

function freshRegistry() {
  const registry = createConnectorRegistry();
  registry.register(telegramConnector);
  registry.register(slackConnector);
  return registry;
}

describe("tenant routing — credential-bound (Telegram)", () => {
  it("routes an inbound event to the workspace that owns the bot", async () => {
    const registry = freshRegistry();
    const event: InboundEvent = {
      provider: "telegram",
      installKey: "bot-a",
      threadId: "thread-1",
      text: "hello",
      payload: { message: { text: "hi" } },
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBe(WS_A);
  });

  it("routes the other workspace's bot to the OTHER workspace (no cross-tenant bleed)", async () => {
    const registry = freshRegistry();
    const event: InboundEvent = {
      provider: "telegram",
      installKey: "bot-b",
      // Identical payload to workspace A's message — only the credential binding differs.
      threadId: "thread-1",
      text: "hello",
      payload: { message: { text: "hi" } },
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBe(WS_B);
  });

  it("resolves the tenant WITHOUT inspecting the payload (a Telegram Update has no team id)", async () => {
    const registry = freshRegistry();
    // The payload is deliberately garbage. credential-bound must not care.
    const event: InboundEvent = {
      provider: "telegram",
      installKey: "bot-a",
      threadId: "thread-1",
      text: "hello",
      payload: null,
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBe(WS_A);
  });
});

describe("tenant routing — payload-team-id (Slack)", () => {
  it("extracts team_id from the envelope and routes to that workspace", async () => {
    const registry = freshRegistry();
    const event: InboundEvent = {
      provider: "slack",
      threadId: "thread-1",
      text: "hello",
      payload: { team_id: "T_BBB" },
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBe(WS_B);
  });

  it("routes a different team_id to a different workspace", async () => {
    const registry = freshRegistry();
    const event: InboundEvent = {
      provider: "slack",
      threadId: "thread-1",
      text: "hello",
      payload: { team_id: "T_AAA" },
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBe(WS_A);
  });

  it("fails closed on an unknown team_id", async () => {
    const registry = freshRegistry();
    const event: InboundEvent = {
      provider: "slack",
      threadId: "thread-1",
      text: "hello",
      payload: { team_id: "T_NOPE" },
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBeNull();
  });

  it("fails closed on a payload with no team_id at all", async () => {
    const registry = freshRegistry();
    const event: InboundEvent = {
      provider: "slack",
      threadId: "thread-1",
      text: "hello",
      payload: {},
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBeNull();
  });

  it("treats a throwing extractor (malformed/hostile payload) as a miss, not a crash", async () => {
    const registry = createConnectorRegistry();
    registry.register({
      id: "slack",
      direction: "channel",
      auth: "oauth",
      tenantResolution: "payload-team-id",
      adapterFactory: () => stubAdapter(),
      resolveTenant: createPayloadTeamIdResolver(() => {
        throw new Error("truncated webhook body");
      }),
    });

    const event: InboundEvent = {
      provider: "slack",
      threadId: "thread-1",
      text: "hello",
      payload: "<<garbage>>",
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBeNull();
  });
});

describe("tenant routing — fail-closed (no cross-tenant fallback anywhere)", () => {
  it("resolves an unknown install_key to null", async () => {
    const registry = freshRegistry();
    const event: InboundEvent = {
      provider: "telegram",
      installKey: "bot-does-not-exist",
      threadId: "thread-1",
      text: "hello",
      payload: {},
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBeNull();
  });

  it("resolves a null install_key to null", async () => {
    const registry = freshRegistry();
    const event: InboundEvent = {
      provider: "telegram",
      installKey: null,
      threadId: "thread-1",
      text: "hello",
      payload: {},
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBeNull();
  });

  it("resolves a missing (undefined) install_key to null", async () => {
    const registry = freshRegistry();
    const event: InboundEvent = {
      provider: "telegram",
      threadId: "thread-1",
      text: "hello",
      payload: {},
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBeNull();
  });

  it("resolves a blank/whitespace install_key to null", async () => {
    const registry = freshRegistry();

    for (const installKey of ["", "   "]) {
      const event: InboundEvent = {
        provider: "telegram",
        threadId: "thread-1",
        text: "hello",
        installKey,
        payload: {},
      };
      await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBeNull();
    }
  });

  it("resolves an unregistered provider to null", async () => {
    const registry = freshRegistry();
    // 'discord' HAS an install row, but no connector is registered for it. The install
    // row alone must not be enough to route — fail closed.
    const event: InboundEvent = {
      provider: "discord",
      installKey: "guild-a",
      threadId: "thread-1",
      text: "hello",
      payload: {},
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBeNull();
  });

  it("normalises a blank workspace id from a sloppy connector to null", async () => {
    const registry = createConnectorRegistry();
    registry.register({
      id: "sloppy",
      direction: "channel",
      auth: "token",
      tenantResolution: "credential-bound",
      adapterFactory: () => stubAdapter(),
      // Smuggling an empty-string "tenant" past the core must not work.
      resolveTenant: async () => "   ",
    });

    const event: InboundEvent = {
      provider: "sloppy",
      installKey: "k",
      threadId: "thread-1",
      text: "hello",
      payload: {},
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBeNull();
  });

  it("never routes one provider's install key under another provider", async () => {
    const registry = freshRegistry();
    // 'T_AAA' is a real key — but for slack, not telegram. Providers are namespaced.
    const event: InboundEvent = {
      provider: "telegram",
      installKey: "T_AAA",
      threadId: "thread-1",
      text: "hello",
      payload: {},
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBeNull();
  });
});

/**
 * The acceptance bar for this slice: a P3 channel lands as ONE registry entry, with no
 * edit to the core router or the registry. Proven two ways — behaviourally (a third
 * connector, declared entirely in this test file, routes correctly through the untouched
 * core) and structurally (the core source carries no provider-specific branching, so a
 * future special-case would trip this test).
 */
describe("zero-core-change: a THIRD connector lands with no core edit (charter D30)", () => {
  interface DiscordEnvelope {
    guild_id?: string;
  }

  // Declared HERE, in the test — not in src/. The core has never heard of it.
  const discordConnector: Connector<DiscordEnvelope> = {
    id: "discord",
    direction: "channel",
    auth: "token",
    tenantResolution: "payload-team-id",
    adapterFactory: () => stubAdapter(),
    resolveTenant: createPayloadTeamIdResolver<DiscordEnvelope>(
      (payload) => payload?.guild_id ?? null,
    ),
  };

  it("routes the third connector to the right workspace after a single register() call", async () => {
    const registry = freshRegistry();

    // THE ENTIRE INTEGRATION. One line. No src/ file was modified to make this work.
    registry.register(discordConnector);

    const event: InboundEvent = {
      provider: "discord",
      threadId: "thread-1",
      text: "hello",
      payload: { guild_id: "guild-a" },
    };

    await expect(resolveTenantForEvent(event, ctx, registry)).resolves.toBe(WS_A);
  });

  it("the third connector inherits fail-closed semantics for free", async () => {
    const registry = freshRegistry();
    registry.register(discordConnector);

    const unknown: InboundEvent = {
      provider: "discord",
      threadId: "thread-1",
      text: "hello",
      payload: { guild_id: "guild-nope" },
    };

    await expect(resolveTenantForEvent(unknown, ctx, registry)).resolves.toBeNull();
  });

  it("the core carries NO provider-specific branching (tripwire for a future special-case)", () => {
    // Strip comments — the core's docs legitimately name Telegram and Slack when
    // explaining the strategies; only executable code is under test here.
    const stripComments = (src: string) =>
      src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1");

    const coreFiles = ["../src/tenant/resolve.ts", "../src/connector/registry.ts"];

    for (const relative of coreFiles) {
      const source = readFileSync(new URL(relative, import.meta.url), "utf8");
      const code = stripComments(source).toLowerCase();

      for (const provider of [
        "telegram",
        "slack",
        "discord",
        "teams",
        "whatsapp",
        "imessage",
      ]) {
        expect(
          code.includes(provider),
          `${relative} mentions "${provider}" in executable code — the core must stay ` +
            "provider-agnostic so P3 channels land with zero core change",
        ).toBe(false);
      }
    }
  });
});

describe("connector_installs reads (chat_bridge.connector_installs, charter D29)", () => {
  /** A fake Queryable that records what SQL and params it was handed. */
  function fakeDb(rows: Array<{ workspace_id: string | null }>) {
    const calls: Array<{ text: string; values: unknown[] | undefined }> = [];
    const db: Queryable = {
      async query<R extends object>(text: string, values?: unknown[]) {
        calls.push({ text, values });
        return { rows: rows as unknown as R[] };
      },
    };
    return { db, calls };
  }

  it("looks up (provider, install_key) and returns the workspace_id", async () => {
    const { db, calls } = fakeDb([{ workspace_id: WS_A }]);
    const lookup = createInstallsLookup(db);

    await expect(lookup.resolveWorkspace("telegram", "bot-a")).resolves.toBe(WS_A);

    expect(calls).toHaveLength(1);
    expect(calls[0]!.text).toContain("chat_bridge.connector_installs");
    // Parameterised — the install key never reaches SQL as a literal.
    expect(calls[0]!.values).toEqual(["telegram", "bot-a"]);
  });

  it("returns null when no row matches (unknown install)", async () => {
    const { db } = fakeDb([]);
    const lookup = createInstallsLookup(db);

    await expect(
      lookup.resolveWorkspace("telegram", "bot-unknown"),
    ).resolves.toBeNull();
  });

  it("returns null when the row has a null workspace_id", async () => {
    const { db } = fakeDb([{ workspace_id: null }]);
    const lookup = createInstallsLookup(db);

    await expect(lookup.resolveWorkspace("telegram", "bot-a")).resolves.toBeNull();
  });

  it("never touches the database for a blank/null install key", async () => {
    const { db, calls } = fakeDb([{ workspace_id: WS_A }]);
    const lookup = createInstallsLookup(db);

    await expect(lookup.resolveWorkspace("telegram", null)).resolves.toBeNull();
    await expect(
      lookup.resolveWorkspace("telegram", undefined),
    ).resolves.toBeNull();
    await expect(lookup.resolveWorkspace("telegram", "")).resolves.toBeNull();
    await expect(lookup.resolveWorkspace("telegram", "   ")).resolves.toBeNull();
    await expect(lookup.resolveWorkspace("", "bot-a")).resolves.toBeNull();

    // A blank key that reached SQL could match a malformed row. It must not get there.
    expect(calls).toEqual([]);
  });

  it("composite install keys cannot collide across a separator (no forged tenant)", async () => {
    // If the (provider, install_key) pair were joined on a separator character, a
    // crafted install key could impersonate another provider's entry. JSON-encoding
    // the pair makes these two rows distinct, so neither can answer for the other.
    const lookup = createInMemoryInstallsLookup([
      {
        provider: "a",
        installKey: "b:c",
        workspaceId: WS_A,
        credentialRef: "secret-WS_A",
      },
      {
        provider: "a:b",
        installKey: "c",
        workspaceId: WS_B,
        credentialRef: "secret-WS_B",
      },
    ]);

    await expect(lookup.resolveWorkspace("a", "b:c")).resolves.toBe(WS_A);
    await expect(lookup.resolveWorkspace("a:b", "c")).resolves.toBe(WS_B);
    // And a pair that was never installed stays a miss.
    await expect(lookup.resolveWorkspace("a", "b")).resolves.toBeNull();
  });

  it("pg.Pool satisfies Queryable, so W3-1's pool drops in unchanged (compile-time)", () => {
    // If pg.Pool ever stops being assignable to Queryable, this fails at `tsc --noEmit`,
    // not at runtime — which is the point.
    type PoolIsQueryable = Pool extends Queryable ? true : false;
    const proof: PoolIsQueryable = true;

    expect(proof).toBe(true);
  });

  it("W3-1's createBridgePool() output feeds createInstallsLookup directly (compile-time)", () => {
    // The real cross-slice seam: the schema-isolated pool W3-1 builds (search_path pinned
    // to chat_bridge) is exactly what this slice's installs lookup consumes. Asserting it
    // by TYPE means a future change to either side breaks `tsc --noEmit` rather than
    // silently sending connector_installs reads at the wrong schema.
    type BridgePoolIsQueryable =
      ReturnType<typeof createBridgePool> extends Queryable ? true : false;
    const proof: BridgePoolIsQueryable = true;

    // And it type-checks as an actual call, not just a type relation.
    const feed = (pool: ReturnType<typeof createBridgePool>) =>
      createInstallsLookup(pool);

    expect(proof).toBe(true);
    expect(typeof feed).toBe("function");
  });
});

/**
 * The proof that the fakes cannot give: run the REAL SQL against a REAL Postgres.
 *
 * Everything above tests routing logic against an injected fake. That leaves one
 * unproven assumption, and it is a cross-slice one: this slice reads
 * `chat_bridge.connector_installs` schema-QUALIFIED, while W3-1's DDL creates the
 * table UNQUALIFIED and relies on the pool's pinned `search_path`. If the schema or
 * a column name ever drifts between the two slices, every fake-backed test above
 * would still pass and the bridge would fail in production. So: build the table with
 * W3-1's real production wiring (createBridgePool + ensureBridgeSchema), then run
 * this slice's real lookup against it.
 *
 * Mirrors W3-1's harness: a throwaway database, skipped when no Postgres is reachable
 * (CONNECTORS_REQUIRE_DB=1 makes that a hard failure instead of a skip).
 */
const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";
const TENANT_TEST_DB = `connectors_tenant_test_${process.pid}_${Date.now()}`;

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

const pgReachable = await postgresReachable();

describe.skipIf(!pgReachable && !REQUIRE_DB)(
  "tenant routing against a REAL Postgres (chat_bridge.connector_installs)",
  () => {
    let admin: pg.Client;
    let pool: Pool;
    let lookup: InstallsLookup;

    beforeAll(async () => {
      if (!pgReachable && REQUIRE_DB) {
        throw new Error(
          `CONNECTORS_REQUIRE_DB=1 but no Postgres reachable at ${ADMIN_URL}`,
        );
      }
      admin = new pg.Client({ connectionString: ADMIN_URL });
      await admin.connect();
      await admin.query(`CREATE DATABASE ${TENANT_TEST_DB}`);

      const url = new URL(ADMIN_URL);
      url.pathname = `/${TENANT_TEST_DB}`;

      // W3-1's REAL production wiring — search_path pinned to chat_bridge, real DDL.
      pool = createBridgePool({ connectionString: url.toString() });
      await ensureBridgeSchema(pool);

      // Two tenants install the same provider. This is the cross-tenant scenario.
      await pool.query(
        `INSERT INTO connector_installs (provider, install_key, workspace_id, credential_ref)
         VALUES ($1,$2,$3,$4), ($5,$6,$7,$8), ($9,$10,$11,$12)`,
        [
          "telegram",
          "bot-a",
          WS_A,
          "secret://ws-a/telegram",
          "telegram",
          "bot-b",
          WS_B,
          "secret://ws-b/telegram",
          "slack",
          "T_AAA",
          WS_A,
          "secret://ws-a/slack",
        ],
      );

      lookup = createInstallsLookup(pool);
    }, 30_000);

    afterAll(async () => {
      await pool?.end();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${TENANT_TEST_DB} WITH (FORCE)`);
        await admin.end();
      }
    });

    it("executes this slice's real SQL against the table W3-1's DDL actually creates", async () => {
      // If the schema name, table name, or a column name had drifted between the two
      // slices, this throws instead of resolving.
      await expect(lookup.resolveWorkspace("telegram", "bot-a")).resolves.toBe(
        WS_A,
      );
    });

    it("routes two workspaces that installed the SAME provider to different tenants", async () => {
      await expect(lookup.resolveWorkspace("telegram", "bot-a")).resolves.toBe(
        WS_A,
      );
      await expect(lookup.resolveWorkspace("telegram", "bot-b")).resolves.toBe(
        WS_B,
      );
    });

    it("fails closed on a real unknown install_key (no row, no fallback)", async () => {
      await expect(
        lookup.resolveWorkspace("telegram", "bot-nope"),
      ).resolves.toBeNull();
    });

    it("never resolves one provider's key under another provider, against real rows", async () => {
      await expect(
        lookup.resolveWorkspace("telegram", "T_AAA"),
      ).resolves.toBeNull();
      await expect(lookup.resolveWorkspace("slack", "bot-a")).resolves.toBeNull();
    });

    it("routes a full inbound event end-to-end: event -> registry -> real DB -> workspace", async () => {
      const registry = createConnectorRegistry();
      registry.register(telegramConnector);
      registry.register(slackConnector);

      const dbCtx: TenantContext = { installs: lookup };

      // credential-bound, through the real table.
      await expect(
        resolveTenantForEvent(
          {
            provider: "telegram",
            installKey: "bot-b",
            threadId: "thread-1",
            text: "hello",
            payload: { message: { text: "hi" } },
          },
          dbCtx,
          registry,
        ),
      ).resolves.toBe(WS_B);

      // payload-team-id, through the real table.
      await expect(
        resolveTenantForEvent(
          {
            provider: "slack",
            threadId: "thread-1",
            text: "hello",
            payload: { team_id: "T_AAA" },
          },
          dbCtx,
          registry,
        ),
      ).resolves.toBe(WS_A);

      // and an unknown install still drops.
      await expect(
        resolveTenantForEvent(
          {
            provider: "telegram",
            installKey: "bot-zzz",
            threadId: "thread-1",
            text: "hello",
            payload: {},
          },
          dbCtx,
          registry,
        ),
      ).resolves.toBeNull();
    });
  },
);
