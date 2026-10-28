<!-- doc-tier: human | canonical-for: self-host-move | budget: 1500tok -->
# Move an instance from a VM to Container Apps

These steps move a VM from `deploy.sh` onto `deploy/azure/main.bicep`. The backup holds the database and media but no key, so the keys move by hand. A rehearsal on 2026-10-27 with 333 documents and 12 media files was down 123 seconds: stop 6, backup 1, restore 11, update 20 and ready 85. That rehearsal restored from the VM before the template made Postgres private. A move between two private deployments on 2026-10-27 took 38 seconds for the restore job and 200 seconds from the second deployment to `/readyz`. `scripts/instance-move-rehearsal.sh` rehearses backup, restore and boot on one machine.

1. Run the same Barkpark version and the same `BARKPARK_PLUGINS` on both sides. Each boot registers the core `tag` schema and the schemas and codelists of every plugin on `BARKPARK_PLUGINS`, and an unset `BARKPARK_PLUGINS` means every bundled plugin. The rehearsal target had it unset and its first boot added 77 schema definitions and 167 codelists to a source with 9 and 3. `bp instance init` writes `BARKPARK_PLUGINS=media`. When both sides match, the first boot adds nothing. A newer image adds only the new schemas and codelists of those plugins. The restore's counts run before the boot, so compare `bp schema ls` afterwards.
2. Deploy the target in restore mode with the source's keys. Run `bp instance init --target containerapps`, then copy into `barkpark.env` the source's `SECRET_KEY_BASE`, `PREVIEW_JWT_SECRET`, `BARKPARK_CLOAK_KEY`, `BARKPARK_KEK` and `BARKPARK_RELEASE_CAPTURE_HMAC_SECRET` from `/opt/barkpark/.env`, and `BARKPARK_KEK_PREVIOUS`, `BARKPARK_INGEST_TOKEN`, `BARKPARK_KEK_VERSION`, `BARKPARK_OPERATOR_TOKEN_IDS` and `BARKPARK_PLUGINS` if the source sets them. `main.example.bicepparam` reads them under the same names. A new cloak key or KEK makes TOTP, SSO secrets and encrypted fields unreadable. Set `restoreMode = true`, and put the address of the machine that will copy the backup in `operatorIpRanges`. The template then creates everything but the app, so nothing migrates the empty database.
3. Freeze writes with `sudo systemctl stop barkpark`. Barkpark has no read-only switch.
4. Back up to `/var/tmp/move` as [the backup section](SELF-HOST-OPERATIONS.md#scheduled-backups-and-the-restore-drill) shows. `.env` writes the URL as `ecto://`, and bp needs `postgresql://`.
5. Postgres has no public endpoint, so the restore runs in the job `barkpark-ops` inside the network. Copy the backup to the `backups` share, restore it, and wait for the execution to show `Succeeded`. The restore checks every per-type count and media checksum and exits 1 on any difference. Its output is in Log Analytics.

   ```bash
   az storage file upload-batch --account-name <storage> -d backups --destination-path move -s /var/tmp/move
   az containerapp job update -g "$RG" -n barkpark-ops --args restore move
   az containerapp job start -g "$RG" -n barkpark-ops
   az containerapp job execution list -g "$RG" -n barkpark-ops -o table
   ```

   The job installs bp 1.26.10, the template's `bpCliVersion`, which restores into the same or a newer PostgreSQL major. The template runs 17. A VM from `deploy.sh` runs 17 too, and a VM built before 2026-10-28 keeps Ubuntu's 14 on 22.04 or 16 on 24.04.
6. Set `restoreMode = false`, remove that address from `operatorIpRanges` and deploy again. The app starts on the restored database. API tokens move with the database, so the VM's admin token still works and the target skips its seed token.
7. Wait for `/readyz` to answer 200. `/v1/auth/oidc/<org>/start` answers 302 only when the cloak key opens the SSO secret. Open a document with an encrypted field, and compare `bp schema ls` with the source.
8. Repoint DNS. Keep `PHX_HOST`, or passkeys and the Entra redirect URI stop working. Container Apps takes a custom domain only after a TXT record `asuid.<host>`, so a VM on a `cloudapp.azure.com` name needs your own domain before the move.

## Copy one dataset over the API

Use this when you cannot reach the source's database. It needs a token with read access on the source and write access on the target, and no server access.

```bash
bp -s <source> -w <ws> -d production export --out backup.ndjson --media media
bp -s <target> -w <ws> -d production import backup.ndjson --media media --dry-run
bp -s <target> -w <ws> -d production import backup.ndjson --media media
```

- `export --media <dir>` writes every media file to `<dir>/files/<id>` and lists ids and SHA-1s in `<dir>/media.json`. Run it again to resume. It skips files already there with the right SHA-1.
- `import --media <dir>` uploads each file with `mediaFileId`, so the target keeps the asset id, the SHA-1 and each `asset-<id>` document. Byte duplicates keep their own ids. The exported `mediaAsset` rows then replace the documents the uploads made, with `fileInfo.path` pointing at the target's copy. A `/media/files/<path>` URL stored in other content still names the source's path.
- The import writes each document as exported. The target adds no schema initial values and derives no title. A target older than this answers with a warning, and its creates still add them.
- A batch the target cannot finish in time is sent again at half its documents, down to one. The report names the size it ended with. A stopped import prints `--from-line N`. A re-run with `--media` uploads nothing twice.
- An older target ignores `mediaFileId` and stores a new id. The import then stops at the first file, before any document.
