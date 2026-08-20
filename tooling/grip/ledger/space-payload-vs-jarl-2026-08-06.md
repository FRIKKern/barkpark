# space payload vs jarl — re-derivation recipes (2026-08-06, wave 5 verifier)

Question: would `SpaceReport` as designed on origin/main NAME jarl's actual disk consumer?
Answer: NO. It names 984.6 MB of a 33.8 GiB used filesystem (2.9%); the 25 GB that is
actually there (docker/containerd images + barkpark-builder image tars) has no field.

## Recipes

Read the emitted struct:

    git show origin/main:internal/agent/report.go | sed -n '155,220p'
    git show origin/main:internal/agent/report.go | sed -n '738,806p'
    git show origin/main:cmd/barkpark-agent/main.go | sed -n '76,105p;177,195p'

jarl (91.98.139.58) host-consumer truth:

    ssh -i ~/.ssh/barkpark_indx root@91.98.139.58 'df -P -k /; du -x -sh /* 2>/dev/null | sort -rh | head -8; du -x -sh /var/lib/* 2>/dev/null | sort -rh | head -6; journalctl --disk-usage; docker system df; docker images -a --format "{{.ID}} {{.Repository}} {{.Size}}"; docker ps -a --format "{{.Names}} {{.Status}}"'

The sites axis is structurally empty on jarl:

    ssh -i ~/.ssh/barkpark_indx root@91.98.139.58 'find / -xdev -maxdepth 4 -type d -name sites; nice -n 19 ionice -c3 du -hx -d1 /opt/barkpark/sites; echo rc=$?'

Postgres axis on jarl:

    ssh -i ~/.ssh/barkpark_indx root@91.98.139.58 'su - postgres -c "psql -Atc \"select datname, pg_database_size(datname) from pg_database\""'

Cost of the proposed host-consumer widening (same argv shape as duSitesArgs):

    ssh -i ~/.ssh/barkpark_indx root@91.98.139.58 'time nice -n 19 ionice -c3 du -hx -d1 /var/lib >/dev/null; time nice -n 19 ionice -c3 du -hx -d1 / >/dev/null'

No eviction exists for either accumulator:

    git grep -ni "prune\|evict\|reclaim\|rmi" -- internal/runtime/*.go internal/builder/*.go | grep -v _test
    git grep -n "CacheDir" -- internal/runtime/runtime.go
