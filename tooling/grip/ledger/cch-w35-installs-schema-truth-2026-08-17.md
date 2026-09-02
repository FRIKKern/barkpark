<!-- doc-tier: cold | canonical-for: cch-w35-installs-schema-truth-recipe | budget: 800tok -->

# W35 installs-schema-truth — re-derivation recipe

> HISTORICAL RECORD (2026-08-17) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Settles the storage contradiction: census said `connector_installs` "does not exist" (it enumerated only the `public` schema). The table is bridge-owned in the `chat_bridge` schema of the guerrilla connectors DB (which is the SAME Postgres as the main Barkpark DB — connectors.env DATABASE_URL points at it).

## Re-derive everything (single SSH)

```
ssh -o ConnectTimeout=12 -i ~/.ssh/barkpark_indx root@157.180.90.121 \
 'DBU=$(grep ^DATABASE_URL= /etc/barkpark/connectors.env|cut -d= -f2-|tr -d "\""|sed "s#^ecto://#postgresql://#");
  psql "$DBU" -tAc "SELECT table_name FROM information_schema.tables WHERE table_schema='"'"'chat_bridge'"'"';";
  psql "$DBU" -tAc "SELECT count(*) FROM chat_bridge.connector_installs;";
  psql "$DBU" -c "SELECT column_name,data_type,is_nullable FROM information_schema.columns WHERE table_schema='"'"'chat_bridge'"'"' AND table_name='"'"'connector_installs'"'"' ORDER BY ordinal_position;";
  psql "$DBU" -c "SELECT id,slug,name FROM workspaces;";
  psql "$DBU" -c "SELECT id,name,workspace_id FROM secrets ORDER BY workspace_id,name;";
  psql "$DBU" -c "SELECT plugin_name,updated_at FROM plugin_settings;"'
```

## Established truths (2026-08-17)

- `chat_bridge` schema has 5 tables: `thread_session_map`, `connector_installs`, `pending_connect`, `whatsapp_window`, `connector_install_leases`.
- `chat_bridge.connector_installs` EXISTS. Columns: `provider text NOT NULL`, `install_key text NOT NULL`, `workspace_id text NOT NULL`, `credential_ref text NULL`, `chat_token_ref text NULL`, `created_at timestamptz NOT NULL`. **0 rows.** `workspace_id NOT NULL` = table is workspace-scoped by design; credential/chat token stored as REFs (nullable), not inline secrets.
- `connector_install_leases`: 0 rows.
- Honest-zero installs is TRUE — verified in the right schema, not a census tautology over `public`.
- Workspaces: `gyldendal` = e0d57bfb-6df6-4370-87f6-03345ca23972, `default` = 03e3d6d9-d123-4557-9c06-ae4382a20626.
- `secrets` (run-secrets store) columns: name,value,updated_at,updated_by,id,workspace_id. Only 2 rows: `ingest_token`, `jarl-admin-token` — BOTH workspace_id NULL (global). gyldendal-scoped secrets: **0**. default-scoped secrets: **0**. No connector/Anthropic credential in either workspace's scoped store → crown stays human-packet-conditional.
- `plugin_settings`: 1 row, `plugin_name='github'` (AES.GCM.V1 encrypted blob, the GitHub bridge plugin) — NOT connector-related. The census "plugin_settings 1 row" is not a connector install.
