# Re-derivation recipes — w27 verifier `digest-delivery-and-freeze-date` (2026-08-09)

Host note: `barkpark.cloud` and `178.105.92.191` are the SAME machine
(`dig +short barkpark.cloud` -> `178.105.92.191`). The two SSH targets in the
assignment are one host; do not treat them as two.

## R1 — Has the fleet digest ever reached a human? (LOG PATH — returns a FALSE NEGATIVE)

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
      'docker logs $(docker ps -q --filter ancestor=cloud-control_plane:latest | head -1) 2>&1 | grep -i "fleet_digest" | tail -40'

Returns ZERO lines. So does the same grep run over EVERY container on the box:

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      'for c in $(docker ps -aq); do echo "$(docker inspect -f "{{.Name}}" $c) $(docker logs $c 2>&1 | grep -c fleet_digest)"; done'

The zero is NOT absence of delivery. The container that ran the 06:00 digest was
destroyed by the 07:31/07:33 blue/green recreation:

    ssh ... 'docker ps -a --format "{{.Names}}\t{{.CreatedAt}}"'

The affordance `notifications.ex:406` documents — `journalctl -u barkpark-cloud |
grep fleet_digest` — does not exist on this host at all:

    ssh ... 'systemctl list-units --all --no-pager | grep -c barkpark-cloud'   # -> 0
    ssh ... 'journalctl -u barkpark-cloud --no-pager -n 3'                      # -> "-- No entries --"

## R2 — Has the fleet digest ever reached a human? (DURABLE PATH — the real answer: YES, once, today)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -P pager=off \
      -c "SELECT event, count(*), min(inserted_at), max(inserted_at) FROM notification_deliveries GROUP BY 1 ORDER BY 2 DESC;" \
      -c "SELECT id, team_id, recipient, status, inserted_at FROM notification_deliveries WHERE event = $$fleet_digest$$ ORDER BY inserted_at;" \
      -c "SELECT worker, state, count(*), min(inserted_at), max(inserted_at) FROM oban_jobs WHERE worker ILIKE $$%Digest%$$ GROUP BY 1,2;"'

4 rows, all `status=sent`, all `2026-08-09 06:00:00.69 .. 06:00:01.10`, against
4 completed DailyDigestWorker jobs spanning 2026-08-04 .. 2026-08-09. Jobs 1-3
(08-04, 08-05, 08-07) wrote ZERO rows.

## R3 — SMTP-side delivery evidence is structurally unavailable

    ssh ... 'docker logs cloud-postfix-1 2>&1 | wc -l'                 # -> 7 (banner + DKIM key only)
    ssh ... 'docker exec cloud-postfix-1 postconf maillog_file'        # -> maillog_file =   (EMPTY)
    ssh ... 'docker exec cloud-postfix-1 sh -c "ps aux | grep -c [r]syslog"'  # -> 0 (no ps, no rsyslog)
    ssh ... 'docker exec cloud-postfix-1 mailq'                        # -> Mail queue is empty

`status=sent` in the table means `Mailer.deliver/1` returned `{:ok, _}` — handed
to the relay. There is no per-message postfix log on any collected sink, so
relay ACCEPTANCE and remote 250s are unrecoverable. Do not upgrade `sent` to
"reached an inbox".

## R4 — Honest freeze point of the failure numerator

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -P pager=off \
      -c "SELECT max(inserted_at) FROM deployments WHERE status=$$failed$$;" \
      -c "SELECT status, count(*) FROM deployments GROUP BY 1;" \
      -c "SELECT date(inserted_at) d, count(*) total, count(*) FILTER (WHERE status=$$failed$$) failed FROM deployments WHERE inserted_at >= $$2026-08-06$$ GROUP BY 1 ORDER BY 1;" \
      -c "select now();"'

TRUE freeze: `2026-08-08 14:55:28.776961` (timestamp WITHOUT time zone; the DB
runs UTC — `now()` printed `2026-08-09 08:05:53.944777+00`). TRUE numerator:
18,640 failed. Per-day: 08-06 = 2205/866, 08-07 = 2008/18, 08-08 = 758/18,
08-09 = 335/0.

Charter D375 (`.claude/workflows/bp-deploy-reliability-charter.md:6054,6061`, on
origin/main at da47f61aa) prints "FROZEN at 18,622 since 2026-08-07T10:02:55Z"
and "2026-08-08 carries 259 rows and 0 failed". Both false; the delta is exactly
the 18 rows of 2026-08-08. Re-derive before re-printing:

    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | sed -n '6050,6064p'

## R5 — The alert rail is NOT the reason the numerator froze

`deployment_failed` deliveries max at `2026-08-08 14:55:43.954614`, 15s after the
last failed row, 2313 sent / 4 failed lifetime. The alert rail tracked the
failures to the end; the freeze is in the WRITER, not the reporter.

## R6 — Digest read routes are live (auth-gated, not missing)

    curl -s -o /dev/null -w "%{http_code}\n" https://barkpark.cloud/v1/operator/deliveries                      # 401
    curl -s -o /dev/null -w "%{http_code}\n" 'https://barkpark.cloud/v1/notifications/deliveries?event=fleet_digest'  # 401
