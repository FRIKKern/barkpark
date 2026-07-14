import { createMemoryState } from "@chat-adapter/state-memory";
import { Chat } from "chat";
import pg, { type Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { createConnectorRegistry } from "../src/connector/registry.js";
import type { ConnectorInstall, InstallsLookup } from "../src/connector/types.js";
import {
  createTeamsConnector,
  teamsTenantId,
  TEAMS_PROVIDER,
} from "../src/connectors/teams.js";
import { createCredentialCipher } from "../src/crypto/credential-cipher.js";
import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import {
  createInMemoryInstallsLookup,
  createInstallsLookup,
} from "../src/tenant/installs.js";
import { resolveTenantForEvent } from "../src/tenant/resolve.js";

/** The real credential cipher (D35/D37): every sealed column here goes through it. */
const CREDENTIAL_KEY = Buffer.alloc(32, 11).toString("base64");
const cipher = createCredentialCipher({ key: CREDENTIAL_KEY });

/**
 * Teams (charter D42). What is actually being proven here:
 *
 *   1. ONE operator Azure app, NO per-workspace credential (`credential_ref` NULL),
 *      and no Slack-style OAuth surface.
 *   2. ONE tenant derivation, shared by webhook routing and event routing — because two
 *      derivations with different precedence is a confused-deputy vector.
 *   3. Cross-tenant routing fails CLOSED (unknown tenant -> drop, never a fallback).
 *   4. The fail-closed 401 on a missing Bot Framework JWT — observed through
 *      `chat.webhooks.teams`, offline, in milliseconds. This is exactly why a
 *      SUCCESSFUL Teams turn is unprovable without the Azure human gate: the adapter
 *      rejects every activity we can synthesise.
 */

const TENANT_A = "11111111-aaaa-4aaa-8aaa-111111111111";
const TENANT_B = "22222222-bbbb-4bbb-8bbb-222222222222";

/** A Teams install: install_key = the Microsoft tenant id, credential_ref = NULL. */
const installA: ConnectorInstall = {
  provider: TEAMS_PROVIDER,
  installKey: TENANT_A,
  workspaceId: "ws-alpha",
  credentialRef: null,
};
const installB: ConnectorInstall = {
  provider: TEAMS_PROVIDER,
  installKey: TENANT_B,
  workspaceId: "ws-beta",
  credentialRef: null,
};

const installs = createInMemoryInstallsLookup([installA, installB]);
const ctx = { installs };

/** A Bot Framework activity as Teams delivers it. */
function activity(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    type: "message",
    id: "activity-1",
    text: "hello agent",
    serviceUrl: "https://smba.trafficmanager.net/emea/",
    from: { id: "29:user", name: "Pelle" },
    recipient: { id: "28:bot" },
    conversation: { id: "19:conv@thread.tacv2", tenantId: TENANT_A },
    channelData: { tenant: { id: TENANT_A } },
    ...overrides,
  };
}

describe("teams connector — registration shape (D42)", () => {
  it("declares payload-team-id routing and NO oauth credential surface", () => {
    const connector = createTeamsConnector({ appId: "op", appPassword: "pw" });

    expect(connector.id).toBe("teams");
    expect(connector.direction).toBe("channel");
    // The tenant id is IN the payload (unlike Telegram) — the same strategy Slack uses.
    expect(connector.tenantResolution).toBe("payload-team-id");
    // NOT "oauth": one operator Azure app serves every org, so there is no
    // per-workspace token to obtain, and therefore no OAuth machinery to copy.
    expect(connector.auth).toBe("token");
    // Webhook-only: the transport IS the HTTP request. No poll loop, no socket.
    expect(connector.listen).toBeUndefined();
    expect(connector.webhook.allowedMethods).toEqual(["POST"]);
  });

  it("registers as one ordinary channel entry", () => {
    const registry = createConnectorRegistry();
    registry.register(createTeamsConnector());

    expect(registry.channels().map((c) => c.id)).toEqual([TEAMS_PROVIDER]);
  });

  it("mounts an adapter for an install with credential_ref NULL", () => {
    const connector = createTeamsConnector({ appId: "op", appPassword: "pw" });

    // The whole D42 ruling in one assertion: two DIFFERENT workspaces, neither carrying
    // a provider credential, both mount. If Teams needed a per-workspace credential this
    // would throw — as Telegram's adapterFactory does for exactly this input.
    expect(() => connector.adapterFactory(installA)).not.toThrow();
    expect(() => connector.adapterFactory(installB)).not.toThrow();
    expect(installA.credentialRef).toBeNull();
  });
});

describe("teams tenant derivation — ONE function, no confused deputy", () => {
  it("uses conversation.tenantId in preference to channelData.tenant.id", () => {
    // A payload carrying BOTH with DIFFERENT values is the confused-deputy shape: if the
    // webhook router preferred one field and the tenant resolver the other, the HTTP
    // request would be verified for one tenant and the Session opened for another.
    const desynced = activity({
      conversation: { id: "19:conv", tenantId: TENANT_A },
      channelData: { tenant: { id: TENANT_B } },
    });

    expect(teamsTenantId(desynced)).toBe(TENANT_A);
  });

  it("falls back to channelData.tenant.id when the conversation carries none", () => {
    const fallback = activity({
      conversation: { id: "19:conv" },
      channelData: { tenant: { id: TENANT_B } },
    });

    expect(teamsTenantId(fallback)).toBe(TENANT_B);
  });

  it("reads the activity through the SDK Message's `raw` — zero core change", () => {
    // The dispatch loop hands `resolveTenant` the SDK Message, not the raw body.
    // parseTeamsMessage sets `raw: activity`, so the SAME extractor works on both.
    const message = { text: "hello agent", raw: activity() };

    expect(teamsTenantId(message)).toBe(TENANT_A);
  });

  it("returns null for every unreadable shape rather than guessing", () => {
    expect(teamsTenantId(undefined)).toBeNull();
    expect(teamsTenantId(null)).toBeNull();
    expect(teamsTenantId("not-an-object")).toBeNull();
    expect(teamsTenantId({})).toBeNull();
    expect(
      teamsTenantId(activity({ conversation: {}, channelData: {} })),
    ).toBeNull();
    // A blank tenant id must never become an install key.
    expect(
      teamsTenantId(
        activity({
          conversation: { tenantId: "   " },
          channelData: { tenant: { id: "" } },
        }),
      ),
    ).toBeNull();
  });

  it("backs webhook.extractInstallKey and resolveTenant with the SAME function", async () => {
    const connector = createTeamsConnector();

    // Identity, not equivalence: they are the same function object, so they CANNOT
    // drift apart in a later edit.
    expect(connector.webhook.extractInstallKey).toBe(teamsTenantId);
    expect(connector.webhook.keySource).toBe("payload");

    // And end-to-end: the desynced payload routes to A's workspace by BOTH paths.
    const desynced = activity({
      conversation: { id: "19:conv", tenantId: TENANT_A },
      channelData: { tenant: { id: TENANT_B } },
    });
    expect(connector.webhook.extractInstallKey(desynced)).toBe(TENANT_A);

    const workspaceId = await connector.resolveTenant(
      {
        provider: TEAMS_PROVIDER,
        threadId: "teams:x:y",
        text: "hi",
        payload: desynced,
      },
      ctx,
    );
    expect(workspaceId).toBe("ws-alpha");
  });
});

describe("teams tenant routing — fail closed", () => {
  const registry = createConnectorRegistry();
  registry.register(createTeamsConnector());

  const event = (payload: unknown) => ({
    provider: TEAMS_PROVIDER,
    threadId: "teams:conv:svc",
    text: "hello",
    payload,
  });

  it("routes each Microsoft tenant to ITS OWN workspace", async () => {
    await expect(
      resolveTenantForEvent(event(activity()), ctx, registry),
    ).resolves.toBe("ws-alpha");

    await expect(
      resolveTenantForEvent(
        event(
          activity({
            conversation: { id: "19:c", tenantId: TENANT_B },
            channelData: { tenant: { id: TENANT_B } },
          }),
        ),
        ctx,
        registry,
      ),
    ).resolves.toBe("ws-beta");
  });

  it("drops an activity from an org that has not installed the app", async () => {
    const stranger = activity({
      conversation: {
        id: "19:c",
        tenantId: "99999999-cccc-4ccc-8ccc-999999999999",
      },
      channelData: { tenant: { id: "99999999-cccc-4ccc-8ccc-999999999999" } },
    });

    // No install row -> NO workspace. Never "the only workspace", never workspace A.
    await expect(
      resolveTenantForEvent(event(stranger), ctx, registry),
    ).resolves.toBeNull();
  });

  it("drops an activity with no tenant id at all", async () => {
    await expect(
      resolveTenantForEvent(
        event(activity({ conversation: { id: "19:c" }, channelData: {} })),
        ctx,
        registry,
      ),
    ).resolves.toBeNull();
    await expect(
      resolveTenantForEvent(event(undefined), ctx, registry),
    ).resolves.toBeNull();
  });
});

describe("teams webhook — fail-closed 401 (the honest human gate)", () => {
  it("rejects an activity with no Bot Framework JWT, before any handler runs", async () => {
    const connector = createTeamsConnector({
      appId: "operator-app-id",
      appPassword: "operator-secret",
    });
    const adapter = connector.adapterFactory(installA);
    const chat = new Chat({
      userName: "barkpark",
      adapters: { [TEAMS_PROVIDER]: adapter },
      state: createMemoryState(),
    });

    let handlerRan = false;
    chat.onDirectMessage(async () => {
      handlerRan = true;
    });

    // Drive chat.webhooks[provider] — NEVER adapter.handleWebhook, which on an
    // uninitialised adapter answers 500 "No handler registered".
    const response = await chat.webhooks.teams(
      new Request("https://bridge.example/connectors/webhooks/teams", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(activity()),
      }),
    );

    // 401, not 200 — and no handler ran, so nothing was posted, no Session was minted.
    // We cannot synthesise a valid Bot Framework JWT; Microsoft signs it. THAT is why a
    // successful Teams turn is UNPROVABLE without the Azure gate, and why this 401 is
    // the shipped behaviour rather than a defect.
    expect(response.status).toBe(401);
    expect(handlerRan).toBe(false);

    await chat.shutdown();
  });
});

/**
 * The proof the fakes CANNOT give — and the one that would actually have bitten.
 *
 * Every test above routes through `createInMemoryInstallsLookup`, which stores the
 * ConnectorInstall object as-is. The SQL lookup does NOT: it maps a ROW through
 * `toInstall()`. Before D42 that function fail-closed-dropped any row whose
 * `credential_ref` was NULL — which is EXACTLY what a Teams install is. Teams would have
 * registered, resolved a tenant, and then been invisible to `listInstalls()`, so the
 * bridge would have booted with zero Teams channels and warned "no connector installs".
 * Green fakes, dead product.
 *
 * So: build the table with the REAL production wiring and read a NULL-credential Teams
 * install back through the REAL SQL. And prove in the same breath that the fail-closed
 * rule that DOES matter — a row with no `workspace_id` — is still enforced.
 */
const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";
const TEAMS_TEST_DB = `connectors_teams_test_${process.pid}_${Date.now()}`;

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
  "teams installs against a REAL Postgres — credential_ref NULL (D42)",
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
      await admin.query(`CREATE DATABASE ${TEAMS_TEST_DB}`);

      const url = new URL(ADMIN_URL);
      url.pathname = `/${TEAMS_TEST_DB}`;
      pool = createBridgePool({ connectionString: url.toString() });
      await ensureBridgeSchema(pool);

      await pool.query(
        `INSERT INTO connector_installs (provider, install_key, workspace_id, credential_ref)
         VALUES ($1,$2,$3,NULL), ($4,$5,$6,NULL), ($7,$8,$9,$10)`,
        [
          TEAMS_PROVIDER,
          TENANT_A,
          "ws-alpha",
          TEAMS_PROVIDER,
          TENANT_B,
          "ws-beta",
          // A credential-bound neighbour, to prove the relaxation is not a blanket
          // one. SEALED, like every credential in the real table (D35/D37) — a
          // plaintext row here would exercise a path production does not have.
          "telegram",
          "bot-a",
          "ws-alpha",
          cipher.seal("secret://ws-a/telegram", {
            provider: "telegram",
            installKey: "bot-a",
            workspaceId: "ws-alpha",
          }),
        ],
      );

      lookup = createInstallsLookup(pool, cipher);
    }, 30_000);

    afterAll(async () => {
      await pool?.end();
      await admin?.query(`DROP DATABASE IF EXISTS ${TEAMS_TEST_DB} WITH (FORCE)`);
      await admin?.end();
    });

    it("reads a NULL-credential Teams install back through the REAL SQL", async () => {
      const install = await lookup.lookupInstall(TEAMS_PROVIDER, TENANT_A);

      expect(install).not.toBeNull();
      expect(install?.workspaceId).toBe("ws-alpha");
      // NULL, not "" — one spelling of "no credential".
      expect(install?.credentialRef).toBeNull();
    });

    it("LISTS Teams installs at boot — the mount path that would otherwise be empty", async () => {
      const installs = await lookup.listInstalls(TEAMS_PROVIDER);

      expect(installs.map((i) => i.installKey).sort()).toEqual(
        [TENANT_A, TENANT_B].sort(),
      );
      expect(installs.every((i) => i.credentialRef === null)).toBe(true);

      // And each one mounts, from ONE operator app.
      const connector = createTeamsConnector({ appId: "op", appPassword: "pw" });
      for (const install of installs) {
        expect(() => connector.adapterFactory(install)).not.toThrow();
      }
    });

    it("still routes each tenant to its own workspace, and drops a stranger", async () => {
      await expect(lookup.resolveWorkspace(TEAMS_PROVIDER, TENANT_A)).resolves.toBe(
        "ws-alpha",
      );
      await expect(lookup.resolveWorkspace(TEAMS_PROVIDER, TENANT_B)).resolves.toBe(
        "ws-beta",
      );
      await expect(
        lookup.resolveWorkspace(TEAMS_PROVIDER, "not-installed"),
      ).resolves.toBeNull();
      await expect(
        lookup.resolveWorkspace(TEAMS_PROVIDER, null),
      ).resolves.toBeNull();
    });

    it("STILL fails closed on a row with no workspace — the rule that actually protects tenants", async () => {
      // workspace_id is NOT NULL in the DDL, so the only way to express "no workspace"
      // through the real table is the empty string. It must not become a tenant.
      await pool.query(
        `INSERT INTO connector_installs (provider, install_key, workspace_id, credential_ref)
         VALUES ($1,$2,'',NULL)`,
        [TEAMS_PROVIDER, "orphan-tenant"],
      );

      await expect(
        lookup.lookupInstall(TEAMS_PROVIDER, "orphan-tenant"),
      ).resolves.toBeNull();
      await expect(
        lookup.resolveWorkspace(TEAMS_PROVIDER, "orphan-tenant"),
      ).resolves.toBeNull();
      // And it never appears in the boot mount list.
      const installs = await lookup.listInstalls(TEAMS_PROVIDER);
      expect(installs.map((i) => i.installKey)).not.toContain("orphan-tenant");
    });
  },
);
