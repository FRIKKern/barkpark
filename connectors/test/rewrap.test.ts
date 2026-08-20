/**
 * THE REWRAP SWEEP — against a REAL Postgres, because the whole point is what
 * the SQL actually lands after a key rotation (charter D37 follow-through).
 *
 * Two proofs live here:
 *
 *  1. The sweep re-seals EVERY provider's rows under the current per-workspace
 *     DEK, is idempotent (a second run is a byte-for-byte no-op), resumable (an
 *     interrupted run leaves every row openable), and concurrency-safe (a
 *     concurrent install write is SKIPPED, never rolled back).
 *
 *  2. OLD-KEY-DROP: seal under key A, rotate to B (A as previous), sweep, then
 *     open with ONLY B in the chain — every install still mounts. This is the
 *     reason the sweep exists: without it, a BYO-token bot that just sits and
 *     works keeps its blob sealed under A forever, so A can never retire.
 *
 * A fake cannot execute `IS NOT DISTINCT FROM` or an `ON CONFLICT` race, so this
 * runs against a real database or (when CONNECTORS_REQUIRE_DB=1) hard-fails.
 */
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { randomBytes } from "node:crypto";
import pg from "pg";

import { createCredentialCipher } from "../src/crypto/credential-cipher.js";
import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import { createInstallsLookup, upsertInstall } from "../src/tenant/installs.js";
import { rewrapAllInstalls, type RewrapQueryable } from "../src/tenant/rewrap.js";
import type { ConnectorInstall } from "../src/connector/types.js";

const KEY_A = randomBytes(32).toString("base64");
const KEY_B = randomBytes(32).toString("base64");

const WS_A = "11111111-1111-4111-8111-111111111111";
const WS_B = "22222222-2222-4222-8222-222222222222";

const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";
const TEST_DB = `connectors_rewrap_test_${process.pid}_${Date.now()}`;

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

/** The seed corpus — every credential model, across three providers. */
const SEED: ReadonlyArray<ConnectorInstall> = [
  // credential-bound, both secrets present
  {
    provider: "telegram",
    installKey: "bot-a",
    workspaceId: WS_A,
    credentialRef: "tg-secret-a",
    chatToken: "tg-token-a",
  },
  {
    provider: "slack",
    installKey: "team-b",
    workspaceId: WS_B,
    credentialRef: "sl-secret-b",
    chatToken: "sl-token-b",
  },
  {
    provider: "discord",
    installKey: "app-c",
    workspaceId: WS_A,
    credentialRef: "dc-secret-c",
    chatToken: "dc-token-c",
  },
  // Teams model: NO per-workspace credential (D42), only a chat token.
  {
    provider: "teams",
    installKey: "org-d",
    workspaceId: WS_B,
    chatToken: "tm-token-d",
  },
  // Provisioned credential but chat token not yet minted.
  {
    provider: "telegram",
    installKey: "bot-e",
    workspaceId: WS_A,
    credentialRef: "tg-secret-e",
  },
];

describe.skipIf(!reachable && !REQUIRE_DB)(
  "rewrap sweep — old-key drop, idempotency, concurrency (D37, real Postgres)",
  () => {
    let admin: pg.Client;
    let pool: pg.Pool;

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
      pool = createBridgePool({ connectionString: url.toString() });
      await ensureBridgeSchema(pool);
    }, 30_000);

    afterAll(async () => {
      await pool?.end();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)`);
        await admin.end();
      }
    }, 30_000);

    afterEach(async () => {
      await pool.query("DELETE FROM chat_bridge.connector_installs");
    });

    const rawRow = async (provider: string, installKey: string) => {
      const { rows } = await pool.query<{
        credential_ref: string | null;
        chat_token_ref: string | null;
      }>(
        `SELECT credential_ref, chat_token_ref
           FROM chat_bridge.connector_installs
          WHERE provider = $1 AND install_key = $2`,
        [provider, installKey],
      );
      return rows[0] ?? null;
    };

    /** Seed the corpus sealed under `cipher`. */
    const seedUnder = async (cipher: ReturnType<typeof createCredentialCipher>) => {
      for (const install of SEED) {
        await upsertInstall(pool, cipher, install);
      }
    };

    // ───────────────────────────────────────────────────────────────────────
    // (4) OLD-KEY-DROP — the reason the sweep exists.
    // ───────────────────────────────────────────────────────────────────────
    it("re-seals every provider under B so A can retire — opened with ONLY B, every install mounts", async () => {
      const cipherA = createCredentialCipher({ key: KEY_A });
      await seedUnder(cipherA);

      // Sanity: with ONLY B in the chain, NOTHING opens yet (all sealed under A).
      const onlyB = createInstallsLookup(
        pool,
        createCredentialCipher({ key: KEY_B }),
      );
      expect(await onlyB.listInstalls("telegram")).toHaveLength(0);

      // Rotate: B current, A previous. Sweep.
      const cipherB = createCredentialCipher({
        key: KEY_B,
        previousKeys: [KEY_A],
      });
      const result = await rewrapAllInstalls(pool, cipherB);
      expect(result.scanned).toBe(SEED.length);
      expect(result.rewrapped).toBe(SEED.length);
      expect(result.unopenable).toBe(0);
      expect(result.raced).toBe(0);
      expect(result.noWorkspace).toBe(0);

      // NOW drop A entirely — only B configured — and every install still opens.
      const afterDrop = createInstallsLookup(
        pool,
        createCredentialCipher({ key: KEY_B }),
      );
      const tg = await afterDrop.listInstalls("telegram");
      expect(tg.map((i) => i.installKey).sort()).toEqual(["bot-a", "bot-e"]);
      expect(tg.find((i) => i.installKey === "bot-a")?.credentialRef).toBe(
        "tg-secret-a",
      );
      expect(tg.find((i) => i.installKey === "bot-a")?.chatToken).toBe(
        "tg-token-a",
      );
      // Not-yet-provisioned token stays null (the sweep invents nothing).
      expect(tg.find((i) => i.installKey === "bot-e")?.chatToken).toBeNull();

      expect((await afterDrop.listInstalls("slack"))[0]?.credentialRef).toBe(
        "sl-secret-b",
      );
      expect((await afterDrop.listInstalls("discord"))[0]?.chatToken).toBe(
        "dc-token-c",
      );
      // Teams: no credential, token opens.
      const teams = (await afterDrop.listInstalls("teams"))[0];
      expect(teams?.credentialRef).toBeNull();
      expect(teams?.chatToken).toBe("tm-token-d");
    });

    // ───────────────────────────────────────────────────────────────────────
    // (3) IDEMPOTENT + RESUMABLE.
    // ───────────────────────────────────────────────────────────────────────
    it("is a byte-for-byte no-op on the second run", async () => {
      await seedUnder(createCredentialCipher({ key: KEY_A }));
      const cipherB = createCredentialCipher({
        key: KEY_B,
        previousKeys: [KEY_A],
      });

      const first = await rewrapAllInstalls(pool, cipherB);
      expect(first.rewrapped).toBe(SEED.length);

      const snapshot = await Promise.all(
        SEED.map((s) => rawRow(s.provider, s.installKey)),
      );

      const second = await rewrapAllInstalls(pool, cipherB);
      expect(second.rewrapped).toBe(0);
      expect(second.alreadyCurrent).toBe(SEED.length);

      // The bytes did not move — a second sweep touches nothing.
      const after = await Promise.all(
        SEED.map((s) => rawRow(s.provider, s.installKey)),
      );
      expect(after).toEqual(snapshot);
    });

    it("resumes: rows already under B are recognised as done, the rest finish", async () => {
      const cipherB = createCredentialCipher({
        key: KEY_B,
        previousKeys: [KEY_A],
      });
      // Two rows already sealed under B (as if a prior interrupted run did them)…
      await upsertInstall(pool, cipherB, SEED[0]!);
      await upsertInstall(pool, cipherB, SEED[1]!);
      // …the rest still under A.
      const cipherA = createCredentialCipher({ key: KEY_A });
      for (const s of SEED.slice(2)) await upsertInstall(pool, cipherA, s);

      const result = await rewrapAllInstalls(pool, cipherB);
      expect(result.alreadyCurrent).toBe(2);
      expect(result.rewrapped).toBe(SEED.length - 2);

      // All open under ONLY B.
      const onlyB = createInstallsLookup(
        pool,
        createCredentialCipher({ key: KEY_B }),
      );
      expect(await onlyB.listInstalls("telegram")).toHaveLength(2);
      expect(await onlyB.listInstalls("discord")).toHaveLength(1);
    });

    // ───────────────────────────────────────────────────────────────────────
    // CONCURRENCY-SAFE — a pinned-bytes UPDATE skips, never rolls back.
    // ───────────────────────────────────────────────────────────────────────
    it("skips a row a concurrent install write changed mid-sweep, and keeps the newer write", async () => {
      const cipherA = createCredentialCipher({ key: KEY_A });
      await upsertInstall(pool, cipherA, {
        provider: "telegram",
        installKey: "bot-race",
        workspaceId: WS_A,
        credentialRef: "orig-secret",
        chatToken: "orig-token",
      });

      const cipherB = createCredentialCipher({
        key: KEY_B,
        previousKeys: [KEY_A],
      });

      // A db double that delegates to the real pool, but the FIRST time the sweep
      // issues its pinned-bytes UPDATE, a concurrent install write (a re-connect)
      // lands NEW bytes first — sealed under B, so it is a legitimate newer row.
      let raced = false;
      const racingDb: RewrapQueryable = {
        async query(text: string, values?: unknown[]) {
          if (!raced && text.includes("IS NOT DISTINCT FROM")) {
            raced = true;
            await upsertInstall(pool, cipherB, {
              provider: "telegram",
              installKey: "bot-race",
              workspaceId: WS_A,
              credentialRef: "concurrent-secret",
              chatToken: "concurrent-token",
            });
          }
          return pool.query(text, values) as Promise<{
            rows: never[];
            rowCount: number | null;
          }>;
        },
      };

      const result = await rewrapAllInstalls(racingDb, cipherB);
      expect(result.raced).toBe(1);
      expect(result.rewrapped).toBe(0);

      // The concurrent write SURVIVED — it was not rolled back to A's "orig".
      const lookup = createInstallsLookup(
        pool,
        createCredentialCipher({ key: KEY_B }),
      );
      const install = await lookup.lookupInstall("telegram", "bot-race");
      expect(install?.credentialRef).toBe("concurrent-secret");
      expect(install?.chatToken).toBe("concurrent-token");
    });

    it("leaves a row whose blob opens under NO configured key untouched, and reports it", async () => {
      // Sealed under A, but the sweep is handed a cipher that knows only B — the
      // blob opens for nobody, so the sweep must not relabel it.
      const cipherA = createCredentialCipher({ key: KEY_A });
      await upsertInstall(pool, cipherA, {
        provider: "telegram",
        installKey: "bot-orphan",
        workspaceId: WS_A,
        credentialRef: "orphan-secret",
        chatToken: "orphan-token",
      });
      const before = await rawRow("telegram", "bot-orphan");

      const cipherOnlyB = createCredentialCipher({ key: KEY_B });
      const result = await rewrapAllInstalls(pool, cipherOnlyB);
      expect(result.unopenable).toBe(1);
      expect(result.rewrapped).toBe(0);

      // Bytes untouched — still recoverable once A is re-added.
      expect(await rawRow("telegram", "bot-orphan")).toEqual(before);
    });
  },
);
