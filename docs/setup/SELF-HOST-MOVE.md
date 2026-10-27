<!-- doc-tier: human | canonical-for: self-host-move | budget: 1500tok -->
# Move an instance from a VM to Container Apps

These steps move a VM from `deploy.sh` onto `deploy/azure/main.bicep`. The backup holds the database and media but no key, so the keys move by hand. A rehearsal on 2026-10-27 with 333 documents and 12 media files was down 123 seconds: stop 6, backup 1, restore 11, update 20 and ready 85. `scripts/instance-move-rehearsal.sh` rehearses backup, restore and boot on one machine.

1. Run the same Barkpark version on both sides. A boot seeds its version's content types, and the restore's counts cannot see rows added after it.
2. Deploy the target with the source's keys. Export `SECRET_KEY_BASE`, `PREVIEW_JWT_SECRET`, `BARKPARK_CLOAK_KEY`, `BARKPARK_KEK` and `BARKPARK_RELEASE_CAPTURE_HMAC_SECRET` from `/opt/barkpark/.env` under the names `main.example.bicepparam` reads. It adds `BARKPARK_` to the first two. A new cloak key or KEK makes TOTP, SSO secrets and encrypted fields unreadable. Add `BARKPARK_INGEST_TOKEN` and `BARKPARK_KEK_PREVIOUS`, if the source sets them, as [Key Vault references](SELF-HOST-OPERATIONS.md#rotate-keys).
3. The first boot migrates the target database, and the restore needs an empty one. Stop the app and recreate the database:

   ```bash
   az containerapp revision deactivate -g "$RG" -n barkpark --revision "$REVISION"
   az postgres flexible-server db delete -g "$RG" -s "$PG" -n barkpark --yes
   az postgres flexible-server db create -g "$RG" -s "$PG" -n barkpark --charset UTF8 --collation en_US.utf8
   ```

4. The template's firewall admits only Azure addresses, so run the restore on the VM. Install `bp` there with `install-cli.sh`. Install `cifs-utils` and the client tools for the target's major: on Ubuntu, run `/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh` and install `postgresql-client-17`. Mount the `media` share at `/mnt/media` with `mount -t cifs` and the key from `az storage account keys list`.
5. Freeze writes with `sudo systemctl stop barkpark`. Barkpark has no read-only switch.
6. Back up to `/var/tmp/move` as [the backup section](SELF-HOST-OPERATIONS.md#scheduled-backups-and-the-restore-drill) shows. `.env` writes the URL as `ecto://`, and bp needs `postgresql://`.
7. Restore. `sslrootcert=system` checks the server against the system's CA roots. Without it, `verify-full` looks for `~/.postgresql/root.crt` and fails. The restore checks every per-type count and media checksum and exits 1 on any difference.

   ```bash
   sudo PATH="/usr/lib/postgresql/17/bin:$PATH" bp instance restore /var/tmp/move --media-dir /mnt/media \
     --database-url "postgresql://barkpark:$PASSWORD@$PG.postgres.database.azure.com/barkpark?sslmode=verify-full&sslrootcert=system"
   ```

   Ubuntu's PostgreSQL is 14 on 22.04 and 16 on 24.04, and the template runs 17. bp 1.26.1 and newer restore into the same or a newer major. bp 1.26.0 and older refuse any major but the backup's.
8. Start the app: `az containerapp update -g "$RG" -n barkpark --set-env-vars ...` with the [Pensum settings](SELF-HOST.md#pensum-settings), `BARKPARK_KEK_VERSION` and `BARKPARK_OPERATOR_TOKEN_IDS` from `.env` makes a new revision. API tokens move with the database, so the VM's admin token still works and the target skips its seed token.
9. Wait for `/readyz` to answer 200. `/v1/auth/oidc/<org>/start` answers 302 only when the cloak key opens the SSO secret. Open a document with an encrypted field, and compare `bp schema ls` with the source.
10. Repoint DNS. Keep `PHX_HOST`, or passkeys and the Entra redirect URI stop working. Container Apps takes a custom domain only after a TXT record `asuid.<host>`, so a VM on a `cloudapp.azure.com` name needs your own domain before the move.
