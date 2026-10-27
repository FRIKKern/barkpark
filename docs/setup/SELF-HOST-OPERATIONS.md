<!-- doc-tier: human | canonical-for: self-host-operations | budget: 2500tok -->
# Operate a Barkpark instance

This page comes after setup in [SELF-HOST.md](SELF-HOST.md). It covers backups, moves, key rotation and Container Apps cost. The command reference for backups is [instance-backup.md](../ops/instance-backup.md).

## Scheduled backups and the restore drill

Barkpark schedules no backup. On a single VM, run `bp instance backup` from a daily cron job and copy the directory off the host. The database is local and media is in `/opt/barkpark/api/uploads` unless `BARKPARK_MEDIA_DIR` is set:

```bash
bp instance backup --database-url "postgresql://barkpark:<password from .env>@localhost/barkpark_prod" \
  --media-dir /opt/barkpark/api/uploads --out /var/backups/barkpark/$(date +%F)
```

The backup holds no key. Keep a copy of the keys in `/opt/barkpark/.env` in a password manager, apart from the backups.

On Azure, the platform does it:

- Flexible Server automated backups give point-in-time restore within the retention period, 7 to 35 days, set with `az postgres flexible-server update --backup-retention`.
- Azure Backup takes scheduled snapshots of the Azure Files share that holds media.
- Key Vault keeps the keys. Turn on soft delete and purge protection.

Once a month, restore a `bp instance backup` of the live instance into a scratch PostgreSQL of the same major with the extensions allowed. The drill passes when `bp instance restore` exits 0, because that run has matched every per-type count and media checksum to the manifest. Point a scratch app with the live keys at it and check `/readyz`. Record the date, backup and restore times and the result against the RTO, then delete the scratch server.

## Moving an instance

The backup holds the database and media but no key. The keys move once, by hand, into the target's Key Vault. The steps below move an instance, such as a single VM, onto Container Apps. Run `scripts/instance-move-rehearsal.sh` to rehearse the steps below on one machine. It restores into a Postgres that only accepts verified TLS, boots the prod build, and passes when `/readyz` answers 200 and an encrypted field and a TOTP user read back.

1. On Flexible Server, allow the extensions the dump creates before the restore. Create an empty database for Barkpark.

   ```bash
   az postgres flexible-server parameter set -g "$RG" -s "$PG" --name azure.extensions --value citext,pg_trgm,pgcrypto
   ```

2. Freeze writes. Barkpark has no read-only switch, so stop every writer, such as editors and integrations with write tokens, or stop the source app. Writes after the backup starts are not in it.
3. Back up the source with `bp instance backup`, using client tools for the source's Postgres major. The target must run the same major.
4. Copy each key that `manifest.json` lists under `secrets.keys` from the source's environment, on a VM `/opt/barkpark/.env`, into Key Vault: `SECRET_KEY_BASE`, `BARKPARK_CLOAK_KEY`, `PREVIEW_JWT_SECRET`, `BARKPARK_INGEST_TOKEN`, `BARKPARK_KEK`, and `BARKPARK_KEK_PREVIOUS` if the source sets it. Reference them from the Container App as [the key rotation section](#rotate-keys) shows, and set `BARKPARK_KEK_VERSION` to the source's value. A new key makes encrypted fields and TOTP sign-in unreadable.
5. Restore into the empty database over TLS. The restore checks every per-type count and media checksum against the manifest and exits 1 on any difference.

   ```bash
   bp instance restore <dir> --media-dir <empty Azure Files mount> \
     --database-url "postgresql://$USER@$PG.postgres.database.azure.com/barkpark?sslmode=verify-full"
   ```

6. Start the app with `DATABASE_SSL=verify-full`. Wait for `/readyz` to answer 200, then sign in once with TOTP and open a document with an encrypted field.
7. Repoint DNS to the Container App and change the clients' Barkpark URL. API tokens move with the database. Keep `PHX_HOST` on the same host name, or registered passkeys stop working.

## Rotate keys

`api/config/runtime.exs` reads the keys below. On a single VM they live in `/opt/barkpark/.env`. Where the steps below add a Key Vault version and restart, change the value in that file and run `sudo systemctl restart barkpark`. On Container Apps, keep each in Key Vault behind a Container Apps secret reference, and use a versioned secret URI. A versionless URI restarts the replica on its own within 30 minutes of a new version, which breaks the KEK order below. A versioned URI changes only when you point it at a new version and restart:

```bash
az containerapp secret set -g "$RG" -n "$APP" \
  --secrets "barkpark-kek=keyvaultref:$KV_URL/secrets/barkpark-kek/$VERSION,identityref:system"
az containerapp revision restart -g "$RG" -n "$APP" --revision "$REVISION"
```

| Variable | What it protects | What a rotation ends | Re-key command |
|---|---|---|---|
| `BARKPARK_KEK` with `BARKPARK_KEK_PREVIOUS` and `BARKPARK_KEK_VERSION` | Wraps the per-workspace data keys in the `data_keys` table. Those data keys encrypt workspace secrets and fields marked `encrypted: true`. | Nothing, when you follow the steps below | `Barkpark.Crypto.DataKeys.rewrap_all()` |
| `BARKPARK_CLOAK_KEY` | Cloak fields: TOTP secrets, SSO and social sign-in client secrets, plugin settings, instance-wide secrets, login tickets, token sign-in sessions and started SSO sign-ins | Every value above. Rows sealed under the old key no longer load. | None. See below. |
| `SECRET_KEY_BASE` | Session cookies, LiveView and `Phoenix.Token` signatures, and media signed URLs unless `MEDIA_SIGNING_SECRET` is set | Every browser session, so editors sign in again. A passkey ceremony in progress fails. Signed media URLs stop working. | None needed |
| `PREVIEW_JWT_SECRET` | Draft preview tokens (JWTs), not the stored `/preview-links` | Preview tokens issued before the change. They last `PREVIEW_JWT_TTL_SECONDS`, 600 seconds by default. | None needed |

To rotate `SECRET_KEY_BASE` or `PREVIEW_JWT_SECRET`, add a Key Vault version, point the reference at it and restart. Give `MEDIA_SIGNING_SECRET` its own Key Vault secret if signed media URLs must survive a `SECRET_KEY_BASE` rotation. API tokens are stored as SHA-256 hashes and survive every rotation. Passkeys depend on `PHX_HOST`, not on a key. A passkey registered under one host stops working when `PHX_HOST` changes to another domain.

### Rotate the KEK

The KEK wraps the data keys, not the content, so a rotation re-wraps those keys and re-encrypts no content. Run the steps in order, so every restart can still read every data key.

1. Store the current KEK value as a new Key Vault secret `barkpark-kek-previous`. Set `BARKPARK_KEK_PREVIOUS` to reference it and restart. `/status.json` must show the `kek_previous` component as `operational`. A malformed entry shows as `degraded`.
2. Add a new version of `barkpark-kek` with the value from `openssl rand -base64 32`. Point the reference at that version, raise `BARKPARK_KEK_VERSION` by one, and restart. Old data keys still unwrap with the previous key.
3. Re-wrap every data key from a shell in the running replica:

   ```bash
   az containerapp exec -g "$RG" -n "$APP" --command /bin/bash
   bin/barkpark rpc 'IO.inspect(Barkpark.Crypto.DataKeys.rewrap_all())'
   ```

   On a single VM, run `sudo /opt/barkpark/api/start.sh mix run -e 'IO.inspect(Barkpark.Crypto.DataKeys.rewrap_all())'`.

   `{:ok, n}` means all `n` data keys use the new KEK. `{:error, {:unwrap_failed, id}}` rolls back the run and names a key neither KEK opens. Stop there and keep both keys.
4. Remove `BARKPARK_KEK_PREVIOUS` and restart. Disable the old Key Vault version. Purge it only after a backup taken after step 3 has been restored once.

### Cloak key

`Barkpark.Vault` configures one AES-GCM cipher and no retired cipher, and no command re-encrypts Cloak fields. Keep `BARKPARK_CLOAK_KEY` unchanged. After a change, every row sealed under the old key fails to load, including the user row of anyone with TOTP. Recovering from a leaked Cloak key therefore means clearing each Cloak column and entering the secrets again, and no tool does that today.

## Container Apps cost

Monthly cost in Norway East at the sizes in `deploy/azure/main.bicep`, as of 2026-10-27, is about USD 46 to 100:

| Item | USD per month |
|---|---|
| Container App, 1 vCPU and 2 GiB | 24 idle to 73 busy |
| PostgreSQL Flexible Server, Standard_B1ms | 16 |
| Storage account | 5 |
| Azure Files share | 2 |
| Log Analytics | 0 to 3 |
| Key Vault | under 0.10 |

A consumption-only environment has no environment management charge.
