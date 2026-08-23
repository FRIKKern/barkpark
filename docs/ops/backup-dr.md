<!-- doc-tier: agent | canonical-for: backup-disaster-recovery | budget: 1400tok -->

# Backup & Disaster Recovery Runbook

> Backups that have never been restored are not backups. This runbook is paired
> with a **rehearsed restore drill** (record at the bottom) — re-run the drill on
> every schema-major change and quarterly.

## What is backed up

| Asset | Mechanism | Where | RPO |
|---|---|---|---|
| **Postgres** (all app + auth + audit data) | `bp cloud hetzner backup create` — `pg_dump -Fc` → gzip → S3 (Object Storage). Plus Hetzner **volume snapshots** as the infra-level base. | S3 bucket + Hetzner snapshots | on operator run — **no scheduler**; see **Backup — routine** |
| **Media / object storage** | Object Storage bucket versioning + operator-run snapshot | same region + off-region copy | on operator run — no scheduler |
| **Key material** (KEK, SSO client secrets, run-secrets) | Encrypted at rest; the **KEK is backed up out-of-band** (operator secret manager), NOT in the DB dump. Everything else is ciphertext in the DB backup and useless without the KEK. | operator secret store | on rotation |

**Nothing in this repo schedules any of the above.** There is no cron row, no
systemd timer and no Oban worker for backups — the cloud crontab's `BackupWorker`
mention is a comment naming a module that does not exist — so every logical
backup happens when an operator runs the CLI verb. Hetzner **volume snapshots**
are the only unattended layer, and this repo does not arm them either; they run
only if enabled on the Hetzner side.

The audit chain is inside Postgres, so it rides the DB backup; its hash chain lets
you *prove* a restored copy is un-tampered (`Audit.verify_chain/1`).

## Targets

- **RPO** (max data loss): **since the last operator-run backup** — there is no
  scheduler, so 1h holds only while someone (or a future scheduler) runs hourly.
- **RTO** (max time to restore): **≤ 30 min** for the reference dataset — provision a
  DB + `bp cloud hetzner backup restore` + app redeploy.

## Backup — routine

```bash
bp cloud hetzner backup create --database-url "$DATABASE_URL"   # pg_dump → gzip → S3
bp cloud hetzner backup list                                    # verify the new key + manifest
bp cloud hetzner backup prune --keep 168                        # retention (e.g. 7d hourly)
```

Verify a backup is **usable**, not just present — a listed backup is not a proven one. That is what the drill below does.

## Restore — procedure (followed in the drill)

1. **Provision** a fresh Postgres (new Hetzner volume or a clean DB): `createdb <target>`.
2. **Restore** from the latest good backup:
   ```bash
   bp cloud hetzner backup restore --database-url "$TARGET_URL"   # S3 → gunzip → psql (ON_ERROR_STOP)
   ```
   (Logical equivalent for a local dump: `pg_restore -d <target> <dump>`.)
3. **Verify integrity**: table count + `schema_migrations` count match the source; run `mix ecto.migrate` (no-op if current); confirm `Audit.verify_chain/1` returns `:ok` for a sampled workspace.
4. **Restore key material**: load the KEK from the operator secret store into the app env (without it, encrypted fields/secrets stay ciphertext — by design).
5. **Cut over**: point the app at the restored DB, redeploy (blue/green), smoke-test `curl /status.json` + a query.
6. **Record** the drill (below): backup size, backup time, restore time, verification result.

## Restore-drill record

| Date | Scope | Backup | Restore | Verify | RTO (logical) |
|---|---|---|---|---|---|
| 2026-07-05 | Full schema, logical `pg_dump -Fc` → `pg_restore`, verify | 0.3s → 36K dump | 0.4s | 14/14 tables, 16/16 `schema_migrations` rows **MATCH** | < 1s + provisioning (reference dataset) |

The 2026-07-05 drill exercised the **logical** path end-to-end (dump → fresh DB →
restore → row-count verification) against the real Barkpark schema, proving the
procedure and tooling. For production-scale data, RTO is dominated by dump/restore
throughput + volume provisioning — re-time the drill against a prod-sized copy and
update the target if it exceeds 30 min.

## Failure playbook

- **Corrupt/partial dump** → `psql ON_ERROR_STOP` fails the restore loudly (never half-applies); fall back to the previous backup or a Hetzner volume snapshot.
- **Lost KEK** → encrypted fields/secrets are unrecoverable by design; this is why the KEK lives in a separate secret store with its own backup. Guard it accordingly.
- **Region loss** → restore from the off-region copy; repoint DNS (`bp cloud hetzner` DNS commands).
