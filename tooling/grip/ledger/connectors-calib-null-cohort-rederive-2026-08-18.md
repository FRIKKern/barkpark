<!-- doc-tier: cold | canonical-for: connectors-calib-null-cohort-rederivation | budget: 1200tok -->
# Connectors NULL/reconcile calibration cohort — re-derivation recipe (2026-08-18)

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Verifier lane **calib-null-cohort** on the Connectors false-done audit wave.
7 NULL/reconcile calibration rows mutate-checked against `origin/main` = `e21bf409893d9de66542a31b06716e3c33d8f102`.
VERDICT: **7/7 TRUE-DONE, zero false-done, zero reopens.** Each named capability is PRESENT on origin/main and does what its criterion claims.

Re-derive the whole cohort:

```bash
cd /Volumes/SATECHI/github/barkpark
# 1+7  encrypt-install-credentials + per-workspace-dek  (both live in ONE file; path is crypto/, NOT tenant/)
git show origin/main:connectors/src/crypto/credential-cipher.ts | grep -nE "aes-256-gcm|deriveWorkspaceDek|hkdfSync|setAAD|bpc1|bpc2|CredentialOpenError"
#   -> ALGORITHM aes-256-gcm; AAD = "bpc1|/bpc2|" + JSON([provider,installKey,workspaceId]); HKDF-SHA256 per-workspace DEK; fail-closed throw, no plaintext fallback
git show origin/main:connectors/src/tenant/rewrap.ts | grep -nE "rewrapAllInstalls|IS NOT DISTINCT FROM|credential_ref|chat_token_ref"
cd connectors && node_modules/.bin/vitest run test/credential-cipher.test.ts   # 27/27 incl "workspace A's DEK cannot open a blob sealed for workspace B" + "REFUSES to open when ONLY workspace_id is flipped"

# 2  p2-scaffold-state
git show origin/main:connectors/src/db/pool.ts    | grep -nE "search_path|createBridgePool|SchemaIsolationError"   # options=-c search_path=chat_bridge, fail-closed
git show origin/main:connectors/src/db/schema.ts  | grep -nE "thread_session_map|connector_installs|CHAT_BRIDGE_SCHEMA"

# 3  telegram-token-shape-guard
git show origin/main:connectors/src/connectors/telegram.ts | grep -nE "telegramBotIdFromToken|\^\(\\\\d\+\)"   # regex /^(\d+):.+$/ throws on "not-a-token"/"abc:secret"

# 4  catalog-connectable-drift  (RUN it)
bash scripts/connectors-catalog-drift-check.sh && bash scripts/connectors-catalog-drift-check.sh --selftest   # both exit 0

# 5  chat-bridge-ddl-drift-gate  (RUN it)
bash scripts/connectors-ddl-drift-check.sh && bash scripts/connectors-ddl-drift-check.sh --selftest           # both exit 0

# 6  w14-user-turn-persistence
git show origin/main:api/lib/barkpark_web/controllers/chat_controller.ex | grep -nA12 "defp persist_user_turn"  # StudioChat.append_message role:"user", called from create_message after ensure_and_send
```

## Notes for Decide

- **credential-cipher.ts path is `connectors/src/crypto/`, not `connectors/src/tenant/`** (brief said tenant/). Content is correct; only the path hint in the assignment was stale. Not a defect.
- The `@canonical capability:connector-credential-sealing` marker sits above `createCredentialCipher` on origin/main — one true owner, no decoy.
- Landing confirmation is by CONTENT PRESENCE on origin/main (the capability IS in the origin/main tree ⇒ it is an ancestor); the bare-commit citation (6f3439528) for encrypt-install-credentials did not need SHA resolution once content was proven present.
- catalog gate now also covers tool providers (github/linear) added by later waves — a SUPERSET of the criterion's channel-only claim; still green. Superseded-but-landed → STAYS done.
- No reopens issued. Measured in both directions.
