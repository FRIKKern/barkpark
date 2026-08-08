# ROUTE denominator + control-plane visibility — re-derivation recipes (wave 21 verify)

Taken 2026-08-08 ~03:05-03:10Z. Guerrilla = 157.180.90.121, Cloud CP = 178.105.92.191.

## R1 — engine mtime vs run birth (the 6/6-vs-6/7 question)

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'stat -c "%y %n" /opt/barkpark/deploy/site-deploy.sh /opt/barkpark/deploy/site-deploy-node.sh /opt/barkpark/deploy/lib/site-deploy-common.sh'
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cd /opt/barkpark/.bp-site-deploy-runs && for f in *.status; do echo "$(grep -c "name=ROUTE" $f)|$(stat -c %w $f)|$f"; done | sort -t"|" -k2 | awk -F"|" "\$2 >= \"2026-08-08 02:00\""'
```

Expected: step function at the engine mtime. Both engines mtime `2026-08-08 02:36:09`;
every run born < 02:36:09 has ROUTE=0, every completed run born > it has ROUTE=1.

## R2 — ROUTE is NOT in the log file (only the status fold)

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cd /opt/barkpark/.bp-site-deploy-runs && ls *.log | wc -l && grep -l "name=ROUTE" *.log | wc -l && grep -c "^BPSTAGE" search-37cf23399bde8804.log'
```

Expected `1226 / 0 / 0`. Mechanism: `deploy/lib/site-deploy-common.sh emit()` writes the
BPSTAGE line to stdout + `$BARKPARK_SITE_STATUS_FILE` only; `$BARKPARK_SITE_LOG_FILE`
(deploy_runner.ex:1071, :1605) is written by `log()`, which never emits BPSTAGE.
So `read_log_tail/1` (deploy_runner.ex:1350) can never surface ROUTE, and
`fold_status_file/2` (:1332) drops it via the `@stage_names` whitelist (:279).

## R3 — the CP has no log_tail column, and no console row carries ROUTE

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB -c \"\\d deployments\""'
```

Then, via a scp'd .sql file (psql -f — inline nesting through `docker exec sh -c` mangles quotes):

```sql
select count(*) from deployments d where exists (select 1 from unnest(d.console) c where c::text like '%ROUTE%');
select count(*) from deployments d where exists (select 1 from unnest(d.console) c where c::text like '%BPSTAGE%');
select count(*) from deployments d where array_length(d.console,1) > 0;
```

Expected `0 / 0 / 19327`.

## R4 — ROUTE incidence for dr-w19-bl-arm-route-incidence-then-fatal

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cd /opt/barkpark/.bp-site-deploy-runs; for s in $(ls *.status | sed -E "s/-[0-9a-f]{16}\.status$//" | sed "s/\.status$//" | sort -u); do m=$(grep -cE "BARKPARK_SITE_ROUTE:${s}([^a-z0-9-]|\$)" /etc/caddy/Caddyfile); code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 https://guerrilla.barkpark.cloud/sites/$s/); echo "$s marker=$m http=$code"; done'
```

10 live sites: marker=1 and 200 (three answer 308 -> 200 under `curl -L`, basePath
canonicalization). 6 `proof-20260718-*` slugs have marker=0 / 404 but their `.status`
files are ZERO BYTES — no deploy ever recorded, so they are not exit-0 incidents.

## R5 — ROUTE outcome histogram

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cd /opt/barkpark/.bp-site-deploy-runs && grep -h "name=ROUTE" *.status | grep -oE "status=[a-z]+" | sort | uniq -c && grep -h "name=ROUTE" *.status | grep -oE "detail=\"[0-9a-f]+ (already )?armed" | grep -oE "(already )?armed$" | sort | uniq -c'
```

At n=15 (all ROUTE emissions since the 02:36:09 engine landing): 15 `status=ok`,
14 `already armed`, 1 `armed`, 0 `status=failed`.
