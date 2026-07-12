# live-migrate-cutover-timing — probe transcript (2026-07-12)

Paper (deliverable): guerrilla `/papers/live-migrate-cutover-timing` (slug live-migrate-cutover-timing).
This dir is reproducibility evidence only — the paper on guerrilla is the deliverable. No product code.

## Scratch box lifecycle (created + torn down this run)
- create: `bp cloud instance create --name ppr-migrate-probe --provider hetzner` (BARKPARK_SSH_KEY=barkpark-indx)
  -> ipv4 178.105.59.193, fqdn ppr-migrate-probe.barkpark.cloud, ~19s
- box: Intel Xeon (Skylake), 2 vCPU, 3.7 GiB, Ubuntu 22.04.5, x86_64 (bare VM — create provisions VM only)
- delete: `bp cloud instance delete ppr-migrate-probe --provider hetzner --yes` -> ok; list grep -c => 0

## D9 zero-replication proof
grep -rniE 'wal_level|pg_basebackup|CREATE PUBLICATION|CREATE SUBSCRIPTION|primary_conninfo|standby|
streaming_replication|hot_standby|max_wal_senders' api/ deploy/ cloud/ internal/  (minus .md/test/node_modules)
=> single hit: api/priv/onix/onix-3.0/ONIX_XHTML_Subset.xsd:869 (ONIX XHTML attribute, not PG). Otherwise empty.

## Measured phases (source = barkpark_dev, 337.6 MB / 9,344 docs / 63,261 mutation_events / 136 migrations)
| Phase | Command | Measured |
|---|---|---|
| dump | pg_dump --format=custom (PG17) | 8.508 s -> 51.9 MB dump (6.5x) |
| transfer | scp dump -> Hetzner box (home WAN) | 3.352 s / 15.47 MB/s |
| restore (box) | DROP+CREATE + pg_restore -j2 (Hetzner 2vCPU, PG17) | 31.421 s, 0 errors, full fidelity |
| restore (laptop control) | pg_restore -j4 (Mac, PG17) | 13.754 s |
| migrate | mix ecto.migrate (version-matched, warm) | 0.743 s ("Migrations already up") |
| restart+health | phx cold boot -> /api/schemas 200 | 15.535 s (attempt 16) |
| cutover flip | deploy/instance-deploy.sh sed port swap + graceful caddy reload | <1 s (mechanism) |

Write-freeze total (hard fence, dump->serving): ~60 s (box restore) / ~42 s (laptop restore).

## Version-parity finding
pg_restore 14 (apt default) refuses a pg_dump-17 custom archive: "unsupported version (1.16) in file header".
A real graduation must pin Postgres major-version parity across source+target. PG17 installed on the box to match.

## Verdict
- REFUTED: shared-cells caveat 6 "live migration" — zero replication exists; nothing is live.
- SETTLED: dump/restore cutover, ~1-minute WRITE-freeze, domain intact (reads warm until sub-second flip).
