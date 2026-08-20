# Re-derivation recipes — dr-w9 verifier `v4-p95-what-is-actually-slow` (2026-08-07 ~03:00Z)

Box: guerrilla 157.180.90.121. Active slot at time of writing: **green**, port **4001**
(`systemctl is-active barkpark-slot@blue.service barkpark-slot@green.service` → `inactive` / `active`).
Health token is **not** `BARKPARK_HEALTH_TOKEN` in `/opt/barkpark/.env` (that key does not exist);
it is `/etc/barkpark/agent.health.token`, passed by the systemd drop-in
`/etc/systemd/system/barkpark-agent.service.d/health-token.conf`.

## R1 — read the live request-stats ring

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'T=$(cat /etc/barkpark/agent.health.token); curl -s -H "Authorization: Bearer $T" localhost:4001/v1/instance/request-stats'
```

## R2 — MUTATION: do socket-path requests land in the ring? (they do NOT)

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'T=$(cat /etc/barkpark/agent.health.token); H="Authorization: Bearer $T"
curl -s -H "$H" localhost:4001/v1/instance/request-stats; echo
for i in $(seq 1 300); do curl -s -o /dev/null -m 5 "localhost:4001/live/websocket?vsn=2.0.0"; done
curl -s -H "$H" localhost:4001/v1/instance/request-stats'
```
Control (same shape, routed path — req_per_s MUST jump by ~300/60 = 5.0):
replace `/live/websocket?vsn=2.0.0` with `/v1/capabilities`.

## R3 — MUTATION: do long-lived SSE streams land as their lifetime? (they do NOT)

```
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "T=\$(cat /etc/barkpark/agent.health.token); H=\"Authorization: Bearer \$T\"
curl -s -H \"\$H\" localhost:4001/v1/instance/request-stats; echo
for i in \$(seq 1 12); do curl -s -o /dev/null -m 25 -H 'Accept: */*' -H 'Authorization: Bearer $TOK' 'localhost:4001/v1/data/listen/production' & done
sleep 10; curl -s -H \"\$H\" localhost:4001/v1/instance/request-stats; echo; wait
curl -s -H \"\$H\" localhost:4001/v1/instance/request-stats"
```

## R4 — long-window latency percentiles from the request log (same telemetry event)

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'journalctl -u barkpark-slot@blue.service --since 2026-08-07T01:00:00 --until 2026-08-07T02:24:00 --no-pager | grep -oE "Sent [0-9]{3} in [0-9]+ms" > /tmp/sent.txt
awk "{gsub(/ms/,\"\",\$4); print \$4+0}" /tmp/sent.txt | sort -n > /tmp/d.txt
n=$(wc -l < /tmp/d.txt); for p in 50 90 95 99 100; do i=$(( (p*n+99)/100 )); echo "p$p=$(sed -n ${i}p /tmp/d.txt)ms"; done'
```

## R5 — the slow routes, named

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'T=$(cat /etc/barkpark/agent.health.token); curl -s -H "Authorization: Bearer $T" localhost:4001/v1/instance/metrics | grep -E "^phoenix_router_dispatch_stop_duration_(sum|count)" | sort'
```
and the >10 s cohort by route (join on request_id):
```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'J="journalctl -u barkpark-slot@blue.service --since 2026-08-07T01:00:00 --until 2026-08-07T02:24:00 --no-pager"
$J | grep -oE "request_id=[A-Za-z0-9_-]+ .*Sent [0-9]{3} in [0-9]{5,}ms" | grep -oE "request_id=[A-Za-z0-9_-]+" | sort -u > /tmp/slowids.txt
$J | grep -F -f /tmp/slowids.txt | grep -oE "(GET|POST) /[^ ]*" | sed -E "s#/(w/[^/]+/p/[^/]+)#/w/:ws/p/:pr#" | sort | uniq -c | sort -rn'
```

## R6 — DBConnection error attribution (who owns the timing-out checkout)

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'journalctl -u barkpark-slot@blue.service --since 2026-08-06 --until 2026-08-07T02:24:00 --no-pager | grep -oE "DBConnection.ConnectionError\) client #PID<[0-9.]+> \(\{?[A-Za-z_.:]+" | grep -oE "\(\{?[A-Za-z_.:]+$" | sort | uniq -c | sort -rn'
```

## R7 — code anchors (origin/main only; the primary checkout is 528 commits behind)

```
git show origin/main:api/lib/barkpark_web/endpoint.ex | sed -n '75p'          # plug Plug.Telemetry
grep -n "plug :socket_dispatch" api/deps/phoenix/lib/phoenix/endpoint.ex      # line 506, inside __using__
grep -n "register_before_send\|duration =" api/deps/plug/lib/plug/telemetry.ex # lines 74-76
git show origin/main:api/lib/barkpark_web/router.ex | grep -n '"/graph"'      # 1846 TasksController :graph_corpus
```
