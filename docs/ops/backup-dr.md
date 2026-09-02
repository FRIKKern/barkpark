<!-- doc-tier: agent | canonical-for: backup-disaster-recovery | budget: 1400tok -->

# Backup & Disaster Recovery Runbook

> Backups that have never been restored are not backups. This runbook is paired
> with a **rehearsed restore drill** (record at the bottom) — re-run it on every
> schema-major change and quarterly.

## What is backed up

| Asset | Mechanism | Where | RPO |
|---|---|---|---|
| **Postgres** (app + auth + audit data) | `bp cloud hetzner backup create` — `pg_dump` **plain SQL** (`--no-owner --no-privileges`) → gzip → S3, + a JSON manifest. Hetzner **volume snapshots** are the infra-level base. | S3 bucket + Hetzner snapshots | on operator run — **no scheduler**; see **Backup — routine** |
| **Media / object storage** | bucket versioning + operator-run snapshot | same region + off-region copy | on operator run — no scheduler |
| **Key material** (KEK, SSO client secrets, run-secrets) | **KEK backed up out-of-band** (operator secret manager), NOT in the DB dump; everything else is ciphertext there and useless without it. | operator secret store | on rotation |

**Nothing in this repo schedules any of the above.** No cron row, no systemd timer,
no Oban worker — the cloud crontab's `BackupWorker` mention is a comment naming a
module that does not exist. Every logical backup happens when an operator runs the
verb; Hetzner **volume snapshots** are the only unattended layer, and this repo
does not arm those either.

The audit chain lives in Postgres, so it rides the DB backup; its hash chain
*proves* a restored copy un-tampered (`Audit.verify_chain/1`).

## Targets

- **RPO**: **since the last operator-run backup** — no scheduler, so 1h holds only
  while someone runs it hourly.
- **RTO**: **≤ 30 min** for the reference dataset — provision a DB +
  `bp cloud hetzner backup restore` + app redeploy.

## Credentials — do this first

Every `backup` verb talks **S3, not the Hetzner API token**, and exits **3**
(`auth`) without them. They are minted once in the Hetzner Console under Object
Storage — no API can. `create`/`restore` also need `pg_dump`/`psql` on PATH.

```bash
export HETZNER_S3_ACCESS_KEY=… HETZNER_S3_SECRET_KEY=…  # or --s3-access-key/--s3-secret-key
# --location fsn1|nbg1|hel1 (default fsn1)
```

## Backup — routine

`--bucket` is **required on every verb**: omit it and the command exits **2** with
a usage error, having done nothing.

```bash
bp cloud hetzner backup create --database-url "$DATABASE_URL" \
    --bucket <your-bucket> --prefix <your-prefix>          # pg_dump → gzip → S3
bp cloud hetzner backup list --bucket <your-bucket> --prefix <your-prefix>
bp cloud hetzner backup prune --bucket <your-bucket> --prefix <your-prefix> \
    --keep 168 --yes                                       # retention (e.g. 7d hourly)
```

`prune` wants exactly one rule — `--keep <n>` **or** `--older-than <30d>`; `--yes`
skips its destructive confirm.

## Restore — procedure (followed in the drill)

1. **Provision** a fresh Postgres (new Hetzner volume or a clean DB): `createdb <target>`.
2. **Pick the key** — `restore` requires `--key` and has no "latest" shorthand:
   ```bash
   bp cloud hetzner backup list --bucket <your-bucket> --prefix <your-prefix>
   ```
3. **Restore** it (`--bucket`, `--key`, `--database-url` all required):
   ```bash
   bp cloud hetzner backup restore --bucket <your-bucket> \
       --key <key-from-step-2> --database-url "$TARGET_URL"   # S3 → gunzip → psql
   ```
   The object is gzipped **plain SQL** — `pg_restore` cannot read it; by hand it is
   `gunzip -c <dump>.sql.gz | psql -v ON_ERROR_STOP=1 -d <target>`. The receipt says
   `confirmation: unavailable` (this verb holds S3, not database, credentials), so
   **step 4 is what proves the restore**.
4. **Verify integrity**: table count + `schema_migrations` count match the source — that is a VERSION-ROW match, never evidence the schema OBJECTS match (an amended-in-place migration keeps its row and its stale object; PDS-D311), so also read one object back (`pg_get_functiondef`); run `mix ecto.migrate` (no-op if current); confirm `Audit.verify_chain/1` returns `:ok` for a sampled workspace.
5. **Restore key material**: load the KEK from the operator secret store into the app env (without it, encrypted fields stay ciphertext — by design).
6. **Cut over**: point the app at the restored DB, redeploy (blue/green), smoke-test `curl -fsS /status.json` + a query.
7. **Record** the drill (below): backup size, backup + restore time, verification result.

## Restore-drill record

| Date | Scope | Backup | Restore | Verify | RTO (logical) |
|---|---|---|---|---|---|
| 2026-07-05 | Full schema, logical `pg_dump -Fc` → `pg_restore`, verify | 0.3s → 36K dump | 0.4s | 14/14 tables, 16/16 `schema_migrations` rows **MATCH** | < 1s + provisioning (reference dataset) |

That drill exercised the **logical** path end-to-end against the real schema — but
with the manual `-Fc`/`pg_restore` pair, **not** the CLI's plain-SQL → `psql`
pipeline, so `bp cloud hetzner backup restore` is itself still unrehearsed; the
next drill must run the verbs above verbatim. At production scale, re-time against
a prod-sized copy and raise the RTO target if it exceeds 30 min.

## Failure playbook

- **Corrupt/partial dump** → `psql ON_ERROR_STOP` fails the restore loudly (never half-applies); fall back to the previous backup or a Hetzner volume snapshot.
- **Lost KEK** → encrypted fields/secrets are unrecoverable by design — which is why the KEK lives in a separate secret store with its own backup.
- **Region loss** → restore from the off-region copy; repoint DNS with `bp cloud hetzner dns record update` (see its `-h`).
