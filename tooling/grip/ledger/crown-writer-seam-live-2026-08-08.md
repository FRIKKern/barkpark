# Crown writer seam — proven live (dr wave 24, verifier worker-token-live) — 2026-08-08

Re-derivation recipes. Every line below was RUN, not read.

## 1. WORKER_TOKEN is present in the running control_plane container (value never printed)

```
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "c=\$(docker ps -q --filter name=control_plane | head -1); docker exec \$c sh -c 'test -n \"\$WORKER_TOKEN\" && echo WORKER_TOKEN_PRESENT || echo WORKER_TOKEN_MISSING'"
# CONTAINER=d8060c2f1caf ; WORKER_TOKEN_PRESENT
```

## 2. The port question, settled — and dissolved

```
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "grep -n 'localhost:41' /etc/caddy/Caddyfile; docker ps --format '{{.Names}} {{.Ports}}' | grep -i control"
# 2:  reverse_proxy localhost:4101
# cloud-control_plane_green-1  127.0.0.1:4101->4100/tcp
```

Slot ports are bound to 127.0.0.1 only. Caddy holds the live slot. The recorder
should NOT discover a port: from the box, `curl https://barkpark.cloud/...`
works and is slot-agnostic (proof 5). The internal route is also publicly
reachable (401, not 404, unauthenticated from outside), but reaching it from a
runner would require WORKER_TOKEN as a NEW GitHub secret — the SSH-then-curl
path keeps the zero-new-credentials property.

## 3. First-ever crown row, replay, and both refusals (run on the box)

```
cd /opt/barkpark; set -a; . cloud/.env; set +a
BODY='{"deliveries":[{"sha":"2e38228b0048901b166d915d222cfc47f6f470d6","delivering_run_id":31255918184,"first_seen_at":"2026-08-08T11:55:11.517221Z","merged_at":"2026-08-08T11:51:21Z","queued_seconds":14,"build_seconds":216,"serving_since":"2026-08-08T11:55:11.517221Z","target":"cp","carried":false}]}'
curl -s -X POST -H 'content-type: application/json' -H "Authorization: Bearer $WORKER_TOKEN" -d "$BODY" http://localhost:4101/v1/internal/platform-deliveries
# {"ok":true,"received":1,"recorded":1}   (replay: recorded:0)
curl -s -X POST -H 'content-type: application/json' -H "Authorization: Bearer $WORKER_TOKEN" -d '{"sha":"2e38..."}' http://localhost:4101/v1/internal/platform-deliveries
# 422 {"error":"deliveries_required",...}
# same POST with no Authorization header -> 401
```

## 4. Read back through a PAT (no admin session)

```
T=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")
curl -s -H "Authorization: Bearer $T" 'https://barkpark.cloud/v1/deliveries?sha=2e38228b0048901b166d915d222cfc47f6f470d6'
# count:1, the row, with recorded_at 2026-08-08T12:23:21.862544Z
curl -s -o /dev/null -w '%{http_code}\n' https://barkpark.cloud/v1/deliveries   # 401
```

Before the POST the same read returned `{"count":0,...,"deliveries":[]}` — the
crown table's emptiness is confirmed by the reader itself, not inferred.

## 5. DATA LOSS: `target` is not in the conflict key (D410's key, run live)

```
BODY='{"deliveries":[{"sha":"0000000000000000000000000000000000000000","delivering_run_id":"0","first_seen_at":"2026-01-01T00:00:00.000000Z","target":"cp"},{"sha":"0000000000000000000000000000000000000000","delivering_run_id":"0","first_seen_at":"2026-01-01T00:00:00.000000Z","target":"instance"}]}'
# -> {"ok":true,"received":2,"recorded":1}  HTTP 200
```

Two legs of one run, one timestamp, different `target`: the second row is
DROPPED under `on_conflict: :nothing`, the caller gets a 200, and `recorded`
under-counts by exactly the lost row. Re-key to
`(sha, delivering_run_id, first_seen_at, target)` — free while the table holds
2 rows.

## Probe residue left in the table

Two rows: one real (sha 2e38228b…, run 31255918184) and one sentinel
(sha all-zeros, run "0") written by proof 5. The sentinel is deliberately
un-mistakable; delete it in the slice-1 migration if a clean table is wanted.
