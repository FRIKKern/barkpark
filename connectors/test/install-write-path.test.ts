/**
 * THE INSTALL WRITE PATH (charter D52) — against a REAL Postgres, because the whole
 * bug lives in one `ON CONFLICT` clause and a fake cannot execute SQL.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE BUG THIS FILE EXISTS TO PIN
 * ─────────────────────────────────────────────────────────────────────────────
 * `upsertInstall`'s `DO UPDATE` used to set all three columns unconditionally, and
 * `isBlankSecret(undefined)` is true — so an absent secret sealed as NULL. The Slack
 * OAuth callback (`oauth/slack-oauth.ts`, the ONLY production caller) builds its
 * install with NO `chatToken` key. So EVERY Slack re-auth silently wiped
 * `chat_token_ref` to NULL: routing kept working, the agent went unreachable, and
 * nothing errored anywhere. The first test below drives the REAL
 * `handleSlackOAuthCallback` and reads the column afterwards — it went RED on
 * origin/main (chat_token_ref was NULL) and is green on the conditional preserve.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * WHY NOT `COALESCE`, THE OBVIOUS ONE-LINER — PROVEN HERE, NOT ASSERTED
 * ─────────────────────────────────────────────────────────────────────────────
 * Because the blobs are AAD-bound to `(provider, install_key, workspace_id)`, a
 * COALESCE that retained a blob across a WORKSPACE CHANGE would retain a ciphertext
 * that can never be opened again — `toInstall()` fails closed on it and the ENTIRE
 * install disappears from every read. An unrecoverable ciphertext replacing a
 * recoverable NULL. "a workspace move NULLs an un-supplied sibling" below is the
 * test that would go red if someone ever swapped the CASE for a COALESCE.
 *
 * And the other tempting fix — "re-seal both blobs under the new workspace" — would
 * hand tenant B a chat token that still AUTHENTICATES AS A. That is not tested here
 * because it is not expressible here: the write path has no decrypt, by design.
 */
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { randomBytes } from "node:crypto";
import pg from "pg";

import { signConnectTicket } from "../src/connect/ticket.js";
import {
  consumePendingConnect,
  stagePendingConnect,
} from "../src/connect/pending-connect.js";
import { SLACK_PROVIDER } from "../src/connectors/slack.js";
import { createCredentialCipher } from "../src/crypto/credential-cipher.js";
import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import { handleSlackOAuthCallback } from "../src/oauth/slack-oauth.js";
import {
  createInstallsLookup,
  deleteInstall,
  upsertInstall,
} from "../src/tenant/installs.js";
import type { MutableInstallsLookup } from "../src/connector/types.js";

const cipher = createCredentialCipher({ key: randomBytes(32).toString("base64") });

const WS_A = "11111111-1111-4111-8111-111111111111";
const WS_B = "22222222-2222-4222-8222-222222222222";

const ADMIN_URL =
  process.env.CONNECTORS_TEST_DATABASE_URL ?? "postgres://localhost:5432/postgres";
const REQUIRE_DB = process.env.CONNECTORS_REQUIRE_DB === "1";
const TEST_DB = `connectors_write_path_test_${process.pid}_${Date.now()}`;

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
  "install write path — sibling preservation, tenant moves, and DELETE (D52, real Postgres)",
  () => {
    let admin: pg.Client;
    let pool: pg.Pool;
    let lookup: MutableInstallsLookup;

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
      lookup = createInstallsLookup(pool, cipher);
    }, 30_000);

    afterAll(async () => {
      await pool?.end();
      if (admin) {
        await admin.query(`DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)`);
        await admin.end();
      }
    }, 30_000);

    // Every test owns the whole table — the rows are the unit under test.
    afterEach(async () => {
      await pool.query("DELETE FROM chat_bridge.connector_installs");
      await pool.query("DELETE FROM chat_bridge.pending_connect");
    });

    /** The raw columns, unopened. What the SQL actually landed. */
    const rawRow = async (provider: string, installKey: string) => {
      const { rows } = await pool.query<{
        workspace_id: string | null;
        credential_ref: string | null;
        chat_token_ref: string | null;
      }>(
        `SELECT workspace_id, credential_ref, chat_token_ref
           FROM chat_bridge.connector_installs
          WHERE provider = $1 AND install_key = $2`,
        [provider, installKey],
      );
      return rows[0] ?? null;
    };

    // ───────────────────────────────────────────────────────────────────────
    // THE SLACK OAUTH CALLBACK: ONE write, BOTH secrets, the pending row consumed.
    // ───────────────────────────────────────────────────────────────────────

    it("writes BOTH secrets in ONE write by joining the pending-connect row, and consumes it (D63) — driven through the REAL handleSlackOAuthCallback", async () => {
      const TEAM = "T_REAUTH";
      const CHAT_TOKEN = "bp_chat_ws_a_token";
      const STATE_SECRET = "slack-connect-secret";
      const NONCE = "nonce-oauth-both-secrets";

      // 1. Studio has minted a workspace-bound chat token and STAGED it over
      //    loopback into a pending row keyed by the ticket's nonce. The raw token
      //    never rides the OAuth `state`; it is sealed at rest here.
      await stagePendingConnect(pool, cipher, {
        nonce: NONCE,
        workspaceId: WS_A,
        provider: SLACK_PROVIDER,
        chatToken: CHAT_TOKEN,
      });

      // The pending row is really there — and its column holds a SEALED blob, not
      // the raw token.
      const pendingBefore = await pool.query<{ chat_token_ref: string }>(
        "SELECT chat_token_ref FROM chat_bridge.pending_connect WHERE nonce = $1",
        [NONCE],
      );
      expect(pendingBefore.rows[0]?.chat_token_ref).toBeDefined();
      expect(pendingBefore.rows[0]?.chat_token_ref).not.toContain(CHAT_TOKEN);

      // 2. Slack redirects the PUBLIC callback back with `code` + the signed state
      //    (a connect ticket carrying the SAME nonce). The callback exchanges the
      //    code, JOINS the pending row by nonce, and writes the install ONCE.
      const state = signConnectTicket(WS_A, SLACK_PROVIDER, STATE_SECRET, {
        nonce: NONCE,
      });
      const result = await handleSlackOAuthCallback(
        new Request(
          `https://example.test/connectors/oauth/slack/callback?code=CODE&state=${encodeURIComponent(state)}`,
        ),
        {
          clientId: "cid",
          clientSecret: "csec",
          redirectUri: "https://example.test/connectors/oauth/slack/callback",
          stateSecret: STATE_SECRET,
          consumePendingConnect: (nonce) =>
            consumePendingConnect(pool, cipher, nonce),
          resolveWorkspace: (provider, installKey) =>
            lookup.resolveWorkspace(provider, installKey),
          upsertInstall: (install) => upsertInstall(pool, cipher, install),
          mountInstall: async () => undefined,
          fetch: (async () =>
            new Response(
              JSON.stringify({
                ok: true,
                access_token: "xoxb-bot",
                team: { id: TEAM, name: "Acme" },
              }),
              { status: 200, headers: { "content-type": "application/json" } },
            )) as unknown as typeof fetch,
        },
      );
      expect(result.installed).toBe(true);

      // BOTH columns landed non-null in ONE write — the fresh-install-NULL gap
      // (D61) is closed and the sibling preserve never had to run.
      const raw = await rawRow(SLACK_PROVIDER, TEAM);
      expect(raw?.credential_ref).not.toBeNull();
      expect(raw?.chat_token_ref).not.toBeNull();

      // …and both open to the right plaintext for THIS row's identity.
      const install = await lookup.lookupInstall(SLACK_PROVIDER, TEAM);
      expect(install?.credentialRef).toBe("xoxb-bot");
      expect(install?.chatToken).toBe(CHAT_TOKEN);

      // 3. The pending row is GONE — single-use, replay-proof.
      const pendingAfter = await pool.query(
        "SELECT nonce FROM chat_bridge.pending_connect WHERE nonce = $1",
        [NONCE],
      );
      expect(pendingAfter.rows).toEqual([]);
    });

    it("a MISSING or expired pending row fails closed — no install written", async () => {
      const TEAM = "T_NOPENDING";
      const STATE_SECRET = "slack-connect-secret";
      const NONCE = "nonce-never-staged";

      // No pending row is staged for this nonce.
      const result = await handleSlackOAuthCallback(
        new Request(
          `https://example.test/connectors/oauth/slack/callback?code=CODE&state=${encodeURIComponent(
            signConnectTicket(WS_A, SLACK_PROVIDER, STATE_SECRET, { nonce: NONCE }),
          )}`,
        ),
        {
          clientId: "cid",
          clientSecret: "csec",
          redirectUri: "https://example.test/connectors/oauth/slack/callback",
          stateSecret: STATE_SECRET,
          consumePendingConnect: (nonce) =>
            consumePendingConnect(pool, cipher, nonce),
          resolveWorkspace: (provider, installKey) =>
            lookup.resolveWorkspace(provider, installKey),
          upsertInstall: (install) => upsertInstall(pool, cipher, install),
          mountInstall: async () => undefined,
          fetch: (async () =>
            new Response(
              JSON.stringify({
                ok: true,
                access_token: "xoxb-bot",
                team: { id: TEAM, name: "Acme" },
              }),
              { status: 200, headers: { "content-type": "application/json" } },
            )) as unknown as typeof fetch,
        },
      );

      expect(result.installed).toBe(false);
      expect(result.status).toBe(400);
      expect(await rawRow(SLACK_PROVIDER, TEAM)).toBeNull();
    });

    it("refuses a Slack team another workspace already owns — 409, and the incumbent row is untouched (D64)", async () => {
      const TEAM = "T_OWNED";
      const STATE_SECRET = "slack-connect-secret";
      const NONCE = "nonce-owned-elsewhere";

      // WS_A already owns this Slack team, with both secrets.
      await upsertInstall(pool, cipher, {
        provider: SLACK_PROVIDER,
        installKey: TEAM,
        workspaceId: WS_A,
        credentialRef: "xoxb-incumbent",
        chatToken: "bp_chat_incumbent",
      });

      // WS_B stages a pending row and re-auths the SAME team with a legit ticket
      // for its OWN workspace. Without the incumbent check, ON CONFLICT would
      // repoint WS_A's row to WS_B (a silent takedown).
      await stagePendingConnect(pool, cipher, {
        nonce: NONCE,
        workspaceId: WS_B,
        provider: SLACK_PROVIDER,
        chatToken: "bp_chat_attacker",
      });

      const result = await handleSlackOAuthCallback(
        new Request(
          `https://example.test/connectors/oauth/slack/callback?code=CODE&state=${encodeURIComponent(
            signConnectTicket(WS_B, SLACK_PROVIDER, STATE_SECRET, { nonce: NONCE }),
          )}`,
        ),
        {
          clientId: "cid",
          clientSecret: "csec",
          redirectUri: "https://example.test/connectors/oauth/slack/callback",
          stateSecret: STATE_SECRET,
          consumePendingConnect: (nonce) =>
            consumePendingConnect(pool, cipher, nonce),
          resolveWorkspace: (provider, installKey) =>
            lookup.resolveWorkspace(provider, installKey),
          upsertInstall: (install) => upsertInstall(pool, cipher, install),
          mountInstall: async () => undefined,
          fetch: (async () =>
            new Response(
              JSON.stringify({
                ok: true,
                access_token: "xoxb-attacker",
                team: { id: TEAM, name: "Acme" },
              }),
              { status: 200, headers: { "content-type": "application/json" } },
            )) as unknown as typeof fetch,
        },
      );

      expect(result.status).toBe(409);
      expect(result.installed).toBe(false);
      expect(result.error).toContain("install_owned_elsewhere");

      // The incumbent's row is untouched: still WS_A, still WS_A's secrets.
      const raw = await rawRow(SLACK_PROVIDER, TEAM);
      expect(raw?.workspace_id).toBe(WS_A);
      const install = await lookup.lookupInstall(SLACK_PROVIDER, TEAM);
      expect(install?.workspaceId).toBe(WS_A);
      expect(install?.credentialRef).toBe("xoxb-incumbent");
      expect(install?.chatToken).toBe("bp_chat_incumbent");

      // …and the pending row for the refused workspace is left in place (not
      // consumed), because the check runs BEFORE the join — so the attacker's own
      // staged token is never spent on a refusal it should learn about.
      const pending = await pool.query(
        "SELECT nonce FROM chat_bridge.pending_connect WHERE nonce = $1",
        [NONCE],
      );
      expect(pending.rows).toHaveLength(1);
    });

    it("is SYMMETRIC: supplying only the chat token preserves the credential", async () => {
      // The mirror image, and the one Studio's connect flow would hit if it ever
      // re-minted a token for an existing install: the credential must not vanish
      // just because this caller had nothing to say about it.
      await upsertInstall(pool, cipher, {
        provider: "telegram",
        installKey: "bot-sym",
        workspaceId: WS_A,
        credentialRef: "111:AA-bot-secret",
        chatToken: "bp_chat_first",
      });

      await upsertInstall(pool, cipher, {
        provider: "telegram",
        installKey: "bot-sym",
        workspaceId: WS_A,
        // credentialRef ABSENT — "do not touch it". Before D52 the TYPE would not
        // even let a caller say this: the key was required.
        chatToken: "bp_chat_rotated",
      });

      const install = await lookup.lookupInstall("telegram", "bot-sym");
      expect(install?.credentialRef).toBe("111:AA-bot-secret");
      expect(install?.chatToken).toBe("bp_chat_rotated");
    });

    // ───────────────────────────────────────────────────────────────────────
    // THE TENANT MOVE: preserve where it is SAFE, NULL where it is not.
    // ───────────────────────────────────────────────────────────────────────

    it("a WORKSPACE MOVE nulls an un-supplied sibling rather than carrying it (no dead ciphertext) or re-sealing it (no cross-tenant token)", async () => {
      await upsertInstall(pool, cipher, {
        provider: "telegram",
        installKey: "bot-moved",
        workspaceId: WS_A,
        credentialRef: "111:AA-a-secret",
        chatToken: "bp_chat_ws_A",
      });

      // The same install key re-appears bound to a DIFFERENT workspace, carrying a
      // fresh credential and no chat token. Both stored blobs are sealed against
      // WS_A's identity: neither can be carried over.
      await upsertInstall(pool, cipher, {
        provider: "telegram",
        installKey: "bot-moved",
        workspaceId: WS_B,
        credentialRef: "111:AA-b-secret",
      });

      const raw = await rawRow("telegram", "bot-moved");
      expect(raw?.workspace_id).toBe(WS_B);
      // NULL — not WS_A's ciphertext. A COALESCE would have kept that blob here,
      // and it would never open again: `toInstall()` fails closed on it, so the
      // WHOLE install would vanish from every read. An unrecoverable ciphertext is
      // strictly worse than a recoverable NULL.
      expect(raw?.chat_token_ref).toBeNull();

      // And the install is STILL USABLE — routable, credentialled, just tokenless
      // until the new workspace mints one. THAT is the difference the CASE buys.
      const install = await lookup.lookupInstall("telegram", "bot-moved");
      expect(install).not.toBeNull();
      expect(install?.workspaceId).toBe(WS_B);
      expect(install?.credentialRef).toBe("111:AA-b-secret");
      expect(install?.chatToken).toBeNull();
    });

    it("preserves BOTH siblings when the workspace is unchanged (the AAD still holds, so preserving is possible)", async () => {
      await upsertInstall(pool, cipher, {
        provider: "telegram",
        installKey: "bot-touch",
        workspaceId: WS_A,
        credentialRef: "111:AA-secret",
        chatToken: "bp_chat_keepme",
      });

      // A caller that supplies NEITHER secret — an install whose only change is,
      // say, a re-assertion of the same row. Nothing must be lost.
      await upsertInstall(pool, cipher, {
        provider: "telegram",
        installKey: "bot-touch",
        workspaceId: WS_A,
      });

      const install = await lookup.lookupInstall("telegram", "bot-touch");
      expect(install?.credentialRef).toBe("111:AA-secret");
      expect(install?.chatToken).toBe("bp_chat_keepme");
    });

    it("a FRESH INSERT still lands NULL for an absent secret (Teams has no credential — D42)", async () => {
      // The regression the preserve could easily have caused: on INSERT there is
      // nothing to preserve, and a Teams install genuinely has no per-workspace
      // provider secret. It must be routable, and its credential column must be NULL.
      await upsertInstall(pool, cipher, {
        provider: "teams",
        installKey: "tenant-x",
        workspaceId: WS_A,
        chatToken: "bp_chat_teams",
      });

      const raw = await rawRow("teams", "tenant-x");
      expect(raw?.credential_ref).toBeNull();
      expect(raw?.chat_token_ref).not.toBeNull();

      const install = await lookup.lookupInstall("teams", "tenant-x");
      expect(install?.credentialRef).toBeNull();
      expect(install?.chatToken).toBe("bp_chat_teams");
    });

    it("an install may precede its chat token: fresh insert with no token lands NULL, and minting it later fills it in", async () => {
      await upsertInstall(pool, cipher, {
        provider: "telegram",
        installKey: "bot-later",
        workspaceId: WS_A,
        credentialRef: "111:AA-secret",
      });
      expect((await rawRow("telegram", "bot-later"))?.chat_token_ref).toBeNull();

      await upsertInstall(pool, cipher, {
        provider: "telegram",
        installKey: "bot-later",
        workspaceId: WS_A,
        chatToken: "bp_chat_minted_later",
      });

      const install = await lookup.lookupInstall("telegram", "bot-later");
      expect(install?.credentialRef).toBe("111:AA-secret");
      expect(install?.chatToken).toBe("bp_chat_minted_later");
    });

    it("an EMPTY-STRING secret is the same nothing as an absent one (two spellings of nothing is one too many)", async () => {
      await upsertInstall(pool, cipher, {
        provider: "telegram",
        installKey: "bot-blank",
        workspaceId: WS_A,
        credentialRef: "111:AA-secret",
        chatToken: "bp_chat_keep",
      });

      await upsertInstall(pool, cipher, {
        provider: "telegram",
        installKey: "bot-blank",
        workspaceId: WS_A,
        credentialRef: "",
        chatToken: null,
      });

      // Both preserved. To REVOKE a secret you delete the row — that is what
      // disconnect does, and it is the only spelling of revocation there is.
      const install = await lookup.lookupInstall("telegram", "bot-blank");
      expect(install?.credentialRef).toBe("111:AA-secret");
      expect(install?.chatToken).toBe("bp_chat_keep");
    });

    // ───────────────────────────────────────────────────────────────────────
    // DELETE — the verb the bridge did not have.
    // ───────────────────────────────────────────────────────────────────────

    it("deleteInstall REMOVES THE ROW — so a disconnect survives a restart (removeInstall was in-memory only)", async () => {
      await upsertInstall(pool, cipher, {
        provider: "telegram",
        installKey: "bot-gone",
        workspaceId: WS_A,
        credentialRef: "111:AA-secret",
        chatToken: "bp_chat_gone",
      });
      expect(await rawRow("telegram", "bot-gone")).not.toBeNull();

      expect(await deleteInstall(pool, "telegram", "bot-gone")).toBe(true);

      // The row is GONE from SQL, not merely unmounted in memory. THAT is the whole
      // point: `Bridge.removeInstall` unmounts a Chat, and before this verb existed
      // the next `startBridge` re-read the row and mounted the "disconnected" bot
      // straight back. `listInstalls` is what boot reads — so assert on IT.
      expect(await rawRow("telegram", "bot-gone")).toBeNull();
      expect(await lookup.lookupInstall("telegram", "bot-gone")).toBeNull();
      expect(await lookup.listInstalls("telegram")).toEqual([]);
    });

    it("deleteInstall reports FALSE for a row that was not there, and refuses a blank key without touching SQL", async () => {
      expect(await deleteInstall(pool, "telegram", "never-existed")).toBe(false);
      expect(await deleteInstall(pool, "telegram", "")).toBe(false);
      expect(await deleteInstall(pool, "", "bot-a")).toBe(false);
    });

    it("deleteInstall deletes ONLY its own row — the sibling install of another tenant is untouched", async () => {
      await upsertInstall(pool, cipher, {
        provider: "telegram",
        installKey: "bot-a",
        workspaceId: WS_A,
        credentialRef: "111:AA-a",
        chatToken: "bp_chat_a",
      });
      await upsertInstall(pool, cipher, {
        provider: "telegram",
        installKey: "bot-b",
        workspaceId: WS_B,
        credentialRef: "222:AA-b",
        chatToken: "bp_chat_b",
      });

      expect(await lookup.deleteInstall("telegram", "bot-a")).toBe(true);

      expect(await lookup.lookupInstall("telegram", "bot-a")).toBeNull();
      const survivor = await lookup.lookupInstall("telegram", "bot-b");
      expect(survivor?.workspaceId).toBe(WS_B);
      expect(survivor?.chatToken).toBe("bp_chat_b");
    });

    it("exposes deleteInstall on the LOOKUP the bridge actually holds (not just as a free function)", async () => {
      await upsertInstall(pool, cipher, {
        provider: "telegram",
        installKey: "bot-lookup",
        workspaceId: WS_A,
        credentialRef: "111:AA-secret",
      });

      expect(await lookup.deleteInstall("telegram", "bot-lookup")).toBe(true);
      expect(await lookup.deleteInstall("telegram", "bot-lookup")).toBe(false);
    });
  },
);
