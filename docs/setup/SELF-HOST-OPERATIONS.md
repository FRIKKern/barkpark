<!-- doc-tier: human | canonical-for: self-host-operations | budget: 2500tok -->
# Operate a container instance

This page continues [SELF-HOST.md](SELF-HOST.md) for an instance on Azure Container Apps with PostgreSQL Flexible Server, media on Azure Files and keys in Key Vault. The command reference for backups is [instance-backup.md](../ops/instance-backup.md).

## Moving an instance

The backup holds the database and media but no key. The keys move once, by hand, into the target's Key Vault. Run `scripts/instance-move-rehearsal.sh` to rehearse the steps below on one machine. It restores into a Postgres that only accepts verified TLS, boots the prod build, and passes when `/readyz` answers 200 and an encrypted field and a TOTP user read back.

1. On Flexible Server, allow the extensions the dump creates before the restore. Create an empty database for Barkpark.

   ```bash
   az postgres flexible-server parameter set -g "$RG" -s "$PG" --name azure.extensions --value citext,pg_trgm,pgcrypto
   ```

2. Freeze writes. Barkpark has no read-only switch, so stop every writer, such as editors and integrations with write tokens, or stop the source app. Writes after the backup starts are not in it.
3. Back up the source with `bp instance backup`, using client tools for the source's Postgres major. The target must run the same major.
4. Copy each key that `manifest.json` lists under `secrets.keys` from the source's environment into Key Vault: `SECRET_KEY_BASE`, `BARKPARK_CLOAK_KEY`, `PREVIEW_JWT_SECRET`, `BARKPARK_INGEST_TOKEN`, `BARKPARK_KEK`, and `BARKPARK_KEK_PREVIOUS` if the source sets it. Reference them from the Container App as [the key rotation section](#rotate-keys-held-in-azure-key-vault) shows, and set `BARKPARK_KEK_VERSION` to the source's value. A new key makes encrypted fields and TOTP sign-in unreadable.
5. Restore into the empty database over TLS. The restore checks every per-type count and media checksum against the manifest and exits 1 on any difference.

   ```bash
   bp instance restore <dir> --media-dir <empty Azure Files mount> \
     --database-url "postgresql://$USER@$PG.postgres.database.azure.com/barkpark?sslmode=verify-full"
   ```

6. Start the app with `DATABASE_SSL=verify-full`. Wait for `/readyz` to answer 200, then sign in once with TOTP and open a document with an encrypted field.
7. Repoint DNS to the Container App and change the clients' Barkpark URL. API tokens move with the database. Keep `PHX_HOST` on the same host name, or registered passkeys stop working.

## Scheduled backups and the restore drill

Barkpark schedules no backup. On Azure, the platform does:

- Flexible Server automated backups give point-in-time restore within the retention period, 7 to 35 days, set with `az postgres flexible-server update --backup-retention`.
- Azure Backup takes scheduled snapshots of the Azure Files share that holds media.
- Key Vault keeps the keys. Turn on soft delete and purge protection.

Once a month, restore a `bp instance backup` of the live instance into a scratch Flexible Server of the same major with the extensions allowed. The drill passes when `bp instance restore` exits 0, because that run has matched every per-type count and media checksum to the manifest. Point a scratch app with the live keys at it and check `/readyz`, as in step 6. Record the date, backup and restore times and the result against the RTO, then delete the scratch server.

## SSO with Entra ID

Set the instance up with the settings in [the next section](#recommended-settings-for-a-pensum-instance). Register an Entra app with the redirect URI `https://$PHX_HOST/v1/auth/oidc/<org>/callback` and a groups claim, then run these as an operator:

```bash
bp org create gyldendal Gyldendal
bp org attach-workspace gyldendal default
bp org oidc-create gyldendal "https://login.microsoftonline.com/$TENANT/v2.0" "$CLIENT_ID" "$CLIENT_SECRET" \
  --tenant_id "$TENANT" --strict_validation --trust_idp_mfa \
  --set group_role_mappings:='{"<owners group id>":"owner","<editors group id>":"member"}'
bp org domain-add gyldendal gyldendal.no      # publish the TXT record it prints
bp org domain-verify gyldendal gyldendal.no
bp org auth-methods gyldendal sso
```

`tenant_id` refuses tokens whose `tid` differs. `strict_validation` checks token times and links the Entra `oid`, so an account survives an email change. `trust_idp_mfa` counts Entra MFA as Barkpark MFA. The keys of the mapping are Entra group object ids. Each sign-in sets the role from the user's groups and can lower it, so map a group that holds the owner to `owner`, or the first sign-in demotes the owner. `bp org oidc-update` takes the same flags.

## Recommended settings for a Pensum instance

```bash
DATABASE_SSL=verify-full DATABASE_SSL_CA_FILE=<Flexible Server CA bundle>
BARKPARK_SELF_UPDATE_CHECK=off BARKPARK_RETIRE_SSE_ON_SIGTERM=1
BARKPARK_ALWAYS_ALLOWED_ORIGINS=<Pensum's browser origins, comma-separated>
BARKPARK_PLUGINS=media BARKPARK_TMUX_CONSOLE=off
BARKPARK_CAPABILITIES_OFF=studio_chat,cycle_fleet,epic_fleet
BARKPARK_BOOTSTRAP_OWNER_EMAIL=<owner>          # first boot only
BARKPARK_OPERATOR_EMAILS=<operators> BARKPARK_OPERATOR_FAIL_CLOSED=1
BARKPARK_SIGN_IN_POLICY_ALL_ROUTES=1 BARKPARK_CLOUD_HANDOFF=off
BARKPARK_BREAKGLASS_EMAILS=<break-glass account> BARKPARK_TOKEN_EXPIRY_WARNINGS=on
```

`BARKPARK_BOOTSTRAP_OWNER_EMAIL` seats that email as owner of the default workspace while the instance has no users. With `BARKPARK_OPERATOR_FAIL_CLOSED=1`, the operator routes refuse every caller while both `BARKPARK_OPERATOR_EMAILS` and `BARKPARK_OPERATOR_TOKEN_IDS` are empty. `BARKPARK_SIGN_IN_POLICY_ALL_ROUTES=1` also applies the org's sign-in policy to API token paste and the Cloud handoff. `BARKPARK_CLOUD_HANDOFF=off` turns off the Barkpark Cloud ticket and deprovisioning routes. A break-glass account signs in with a password and TOTP while SSO is down. Keep its password and TOTP secret in Key Vault.

A barkpark-studio deployment signs editors in through the same connection with `STUDIO_SIGN_IN=sso` and `STUDIO_SSO_ORG=<org>`. List its origin in `BARKPARK_STUDIO_SSO_ORIGINS` (comma-separated, for example `https://studio.example.com`), or the instance refuses to return a sign-in to it.

## Rotate keys held in Azure Key Vault

`api/config/runtime.exs` reads the keys below. Keep each in Key Vault behind a Container Apps secret reference, and use a versioned secret URI. A versionless URI restarts the replica on its own within 30 minutes of a new version, which breaks the KEK order below. A versioned URI changes only when you point it at a new version and restart:

```bash
az containerapp secret set -g "$RG" -n "$APP" \
  --secrets "barkpark-kek=keyvaultref:$KV_URL/secrets/barkpark-kek/$VERSION,identityref:system"
az containerapp revision restart -g "$RG" -n "$APP" --revision "$REVISION"
```

| Variable | What it protects | What a rotation ends | Re-key command |
|---|---|---|---|
| `BARKPARK_KEK` with `BARKPARK_KEK_PREVIOUS` and `BARKPARK_KEK_VERSION` | Wraps the per-workspace data keys in the `data_keys` table. Those data keys encrypt workspace secrets and fields marked `encrypted: true`. | Nothing, when you follow the steps below | `Barkpark.Crypto.DataKeys.rewrap_all()` |
| `BARKPARK_CLOAK_KEY` | Cloak fields: TOTP secrets, SSO and social sign-in client secrets, plugin settings, instance-wide secrets, login tickets and token sign-in sessions | Every value above. Rows sealed under the old key no longer load. | None. See below. |
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

   `{:ok, n}` means all `n` data keys use the new KEK. `{:error, {:unwrap_failed, id}}` rolls back the run and names a key neither KEK opens. Stop there and keep both keys.
4. Remove `BARKPARK_KEK_PREVIOUS` and restart. Disable the old Key Vault version. Purge it only after a backup taken after step 3 has been restored once.

### Cloak key

`Barkpark.Vault` configures one AES-GCM cipher and no retired cipher, and no command re-encrypts Cloak fields. Keep `BARKPARK_CLOAK_KEY` unchanged. After a change, every row sealed under the old key fails to load, including the user row of anyone with TOTP. Recovering from a leaked Cloak key therefore means clearing each Cloak column and entering the secrets again, and no tool does that today.
