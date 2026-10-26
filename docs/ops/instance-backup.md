<!-- doc-tier: agent | canonical-for: instance-backup-restore | budget: 450tok -->

# Self-hosted instance backup and restore

For an instance on any Postgres and a media directory, such as Azure Database
for PostgreSQL with media on an Azure Files mount, no SSH or `/opt/barkpark`
layout is needed. Use the Postgres client tools for the server's major version.

```bash
bp instance backup --database-url "$DATABASE_URL" --media-dir "$BARKPARK_MEDIA_DIR" --out <dir>
bp instance restore <dir> --database-url "$TARGET_URL" --media-dir <empty-dir>
```

`<dir>` holds `db.dump` (`pg_dump --format=custom`), `media.tar.gz` and
`manifest.json`. The manifest records the Postgres major, document counts per
type and the sha256 of both members and every media file. The counts and the
dump come from one snapshot, so the instance can stay up. Add
`?sslmode=require` to the URL for TLS. Keys are never in the backup: the
manifest lists the ones the target must load from the secret store.

Restore refuses a different Postgres major, a database with tables and a
non-empty media directory. It checks both member checksums first, and after
`pg_restore` compares every media file and per-type count with the manifest.
Any difference exits 1. Extensions the dump creates must be allowed on a
managed server first (Azure: `azure.extensions`). The round trip is covered by
`TestInstanceBackupRoundTripPostgres` in `internal/cli/instance_backup_cmd_test.go`,
which runs when `BARKPARK_TEST_PG_URL` names a server it may create databases on.

The Hetzner object-storage backups and the restore drill are in [backup-dr.md](backup-dr.md).
