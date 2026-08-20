/**
 * Runnable rewrap sweep — re-seal every connector install under the CURRENT
 * per-workspace credential key, then retire the previous key.
 *
 *     npm run rewrap        # (tsx scripts/rewrap.ts)
 *
 * Reads the SAME environment the bridge boots on (`loadConfig`): a rotation is
 * expressed as `CONNECTORS_CREDENTIAL_KEY=<new>` +
 * `CONNECTORS_CREDENTIAL_KEY_PREVIOUS=<old>`. This script opens each row under
 * whichever key still opens it and writes it back under the new one. When it
 * reports `raced: 0` and no `unopenable`, every row is sealed under the new key
 * and `CONNECTORS_CREDENTIAL_KEY_PREVIOUS` can be deleted from
 * `/opt/barkpark/.env` (see docs/ops/connectors-deploy.md § Rotating the key).
 *
 * Safe to run against a LIVE bridge: the sweep pins the old bytes of each row it
 * updates, so a connect/re-auth landing mid-sweep is kept, never rolled back —
 * re-run to finish any row it skipped. Idempotent: a second run is a no-op.
 *
 * Fail-closed like the bridge: a missing or malformed CONNECTORS_CREDENTIAL_KEY
 * is a boot failure here too, taken before a single row is read.
 */
import { pathToFileURL } from "node:url";

import { loadConfig } from "../src/config.js";
import { createCredentialCipher } from "../src/crypto/credential-cipher.js";
import { createBridgePool, ensureBridgeSchema } from "../src/db/pool.js";
import { rewrapAllInstalls } from "../src/tenant/rewrap.js";

async function main(): Promise<void> {
  const config = loadConfig();

  // Boot-fatal if the key is missing or malformed — the same failure the real
  // bridge takes, taken here before anything is read or written.
  const cipher = createCredentialCipher({
    key: config.credentialKey,
    previousKeys: config.previousCredentialKeys,
  });

  const pool = createBridgePool({ connectionString: config.databaseUrl });
  try {
    // Fails CLOSED if the pool is not pinned to chat_bridge (D28).
    await ensureBridgeSchema(pool);
    console.log(
      "[rewrap] chat_bridge schema ready — sweeping connector_installs under the current per-workspace key",
    );

    const result = await rewrapAllInstalls(pool, cipher);

    console.log(
      `[rewrap] done: scanned=${result.scanned} rewrapped=${result.rewrapped} ` +
        `alreadyCurrent=${result.alreadyCurrent} noWorkspace=${result.noWorkspace} ` +
        `unopenable=${result.unopenable} raced=${result.raced}`,
    );

    if (result.unopenable > 0) {
      console.warn(
        `[rewrap] ${result.unopenable} row(s) did not open under ANY configured key. ` +
          "Their credential is sealed under a key that is no longer in " +
          "CONNECTORS_CREDENTIAL_KEY or CONNECTORS_CREDENTIAL_KEY_PREVIOUS — do NOT " +
          "drop the previous key until this is resolved (re-connect those installs).",
      );
      process.exitCode = 1;
    } else if (result.raced > 0) {
      console.warn(
        `[rewrap] ${result.raced} row(s) were changed by a concurrent write mid-sweep ` +
          "and were left as-is (the newer write was kept). Re-run to finish them.",
      );
      process.exitCode = 1;
    } else {
      console.log(
        "[rewrap] every row is now sealed under the current key — you may delete " +
          "CONNECTORS_CREDENTIAL_KEY_PREVIOUS from /opt/barkpark/.env.",
      );
    }
  } finally {
    await pool.end();
  }
}

// Only run when executed directly, never on import (tests import ../src/tenant/rewrap).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error("[rewrap] fatal:", err);
    process.exit(1);
  });
}
