# `bp task stage` write cost + round pacing — re-derivation recipes

Wave: PDS wave 25 (the round). Verifier lane `stage-write-cost-and-pacing`.
Measured live against `guerrilla.barkpark.cloud`, 2026-07-30T17:32Z–17:55Z, code read at `origin/main`.

Preamble for every recipe:

```bash
T=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
```

## 1. The bucket is capacity 60 / refill 1.0 per second, per TOKEN, per METHOD-CLASS, per DATASET-SCOPE

```bash
git show origin/main:api/lib/barkpark_web/plugs/rate_limit.ex | sed -n '46,100p'
#   default_per_minute(_, :write) -> 60 ; (_, :read) -> 300
#   bucket_opts(n) -> [capacity: n, refill_per_sec: n / 60.0]
#   bucket_key -> "token:#{hash}:#{class}:#{dataset || "global"}"
seq 1 80 | xargs -P 20 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST https://guerrilla.barkpark.cloud/v1/data/mutate/production \
  -H "Authorization: Bearer $T" -H 'content-type: application/json' \
  -d '{"mutations":[{"createOrReplace":{"_id":"w25-pace-probe","_type":"wavemeasure"}}]}' | sort | uniq -c
#   -> 56 200 / 8 422 / 16 429  (64 admitted in a ~5s window = 60 capacity + ~4 refill)
```

## 2. `/v1/tasks/:id/stage` bills a DIFFERENT bucket than `/v1/data/mutate/production`

```bash
( seq 1 150 | xargs -P 40 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
    -X POST https://guerrilla.barkpark.cloud/v1/data/mutate/production \
    -H "Authorization: Bearer $T" -H 'content-type: application/json' \
    -d '{"mutations":[{"createOrReplace":{"_id":"w25-pace-probe","_type":"wavemeasure"}}]}' \
  | sort | uniq -c ) &
sleep 1
for i in 1 2 3 4 5; do curl -s -o /dev/null -w "DURING-BURST stage: %{http_code}\n" \
  -X POST https://guerrilla.barkpark.cloud/v1/tasks/task-does-not-exist-w25/stage \
  -H "Authorization: Bearer $T" -H 'content-type: application/json' -d '{"state":"open"}'; done; wait
#   -> prod-burst: 15 200 / 135 429   while all five stage calls return 404 (routed, never 429)
```

## 3. ONE `bp task stage --disposition --reopen-trigger` = TWO HTTP requests (1 read + 1 write), ONE with the manifest pinned

Counting proxy (`countproxy.py` in the wave scratchpad) forwards 127.0.0.1:8899 → guerrilla and logs every request.

```bash
bp -s http://127.0.0.1:8899 --token "$T" task stage <id> open \
  --disposition parked --note "…" --reopen-trigger "…" --worker w25 --yes -o json
#   GET  /v1/capabilities?views=1&chat=1 -> 304   (READ class, scope "global")
#   POST /v1/tasks/<id>/stage?disposition=…&note=…&reopen-trigger=… -> 200   (WRITE, scope "global")

BARKPARK_MANIFEST=/tmp/w25-manifest.json bp -s http://127.0.0.1:8899 --token "$T" task stage … --yes
#   POST /v1/tasks/<id>/stage… -> 200      <- the ONLY request; zero read tokens
```

The whole adjudication triple rides as QUERY PARAMS on one POST. There is no read-modify-write at
the HTTP layer: the cost is 1 write token, never 2 and never 4.

## 4. Measured serial throughput — unpinned 0.46 w/s, pinned 3.23 w/s

```bash
for i in $(seq 1 20); do bp task stage <id> open --disposition parked \
  --note "pace probe $i" --reopen-trigger probe --yes -o json >/dev/null; done
#   TOTAL 43.8s  ok=20 err=0  rate=0.46 writes/s   (per-call 1.03s–3.34s)
for i in 1 2 3 4 5; do BARKPARK_MANIFEST=/tmp/w25-manifest.json bp task stage … --yes >/dev/null; done
#   pinned: 0.31s/call -> 3.23 writes/s
```

## 5. The 429 failure signature builders will see

```bash
( seq 1 1500 | xargs -P 150 -I{} curl -s -o /dev/null \
    "https://guerrilla.barkpark.cloud/v1/capabilities?views=1&chat=1" -H "Authorization: Bearer $T" ) &
sleep 2; bp task get task-2ac1f95237c4a8e5 -o json; echo "exit=$?"
#   bp: acquire manifest from https://guerrilla.barkpark.cloud/v1/capabilities: fetch manifest:
#   unexpected status 429 — {"error":{"code":"rate_limited",…}} (hint: set BARKPARK_MANIFEST=<file>
#   or pass --manifest <file> to run before /v1/capabilities is deployed)     exit=1
# Also seen under load: "context deadline exceeded (Client.Timeout exceeded while awaiting headers)"
```

Raw envelope + header on a write 429:

```
HTTP/2 429 ; retry-after: 1
{"error":{"code":"rate_limited","message":"too many requests","hint":"Back off and retry after the
Retry-After header's value; reduce request rate.","details":{"retry_after":1},"request_id":"…"}}
```

## 6. Per-shard tokens: READ-only can be minted, WRITE cannot

```bash
curl -s -X POST "https://guerrilla.barkpark.cloud/w/default/p/default/v1/tokens" \
  -H "Authorization: Bearer $T" -H 'content-type: application/json' \
  -d '{"label":"probe","permissions":["write"],"dataset":"production"}'
#   {"error":{"code":"unprocessable","message":"permissions [\"write\"] not allowed — this endpoint
#    mints read-only tokens only (public-read, read)"}}
#   permissions:["read"] -> 200 with a raw token; that token reads /v1/tasks/:id fine (200)

# and the per-token bucket separation, proven live:
( seq 1 2000 | xargs -P 200 -I{} curl -s -o /dev/null \
    https://guerrilla.barkpark.cloud/v1/capabilities -H "Authorization: Bearer $T" ) &
sleep 3; curl -s -o /dev/null -w 'admin: %{http_code}\n'  … -H "Authorization: Bearer $T"
         curl -s -o /dev/null -w 'minted: %{http_code}\n' … -H "Authorization: Bearer $RT"
#   admin: 429 / minted: 200
```

There is no revoke verb for `/v1/tokens` in the manifest (only `token.create`).

## 7. `--note` longer than ~9.5 KB dies as an opaque HTTP/2 stream error

```bash
for n in 9000 10000 11000 16000; do N=$(python3 -c "print('x'*$n)")
  curl -s -o /dev/null -w "note_bytes=$n -> %{http_code}\n" -G -X POST \
    "https://guerrilla.barkpark.cloud/v1/tasks/<id>/stage" --data-urlencode "state=open" \
    --data-urlencode "note=$N" --data-urlencode "disposition=parked" \
    --data-urlencode "reopen-trigger=probe" -H "Authorization: Bearer $T"; done
#   9000 -> 200 ; 10000 -> 414 ; 11000 -> 000 ; 16000 -> 414
bp task stage <id> open --disposition parked --note "$(python3 -c "print('x'*12000)")" … --yes
#   bp: request failed: stream error: stream ID 3; INTERNAL_ERROR; received from peer
```

The ceiling is a bp-CLI artifact (it puts every flag in the query string), NOT a server limit — a
JSON body carries an arbitrarily long note:

```bash
python3 -c "import json;print(json.dumps({'state':'open','disposition':'parked','note':'B'*20000,'reopen-trigger':'probe'}))" > /tmp/bigbody.json
curl -s -w 'HTTP %{http_code}\n' -X POST "https://guerrilla.barkpark.cloud/v1/tasks/<id>/stage" \
  -H "Authorization: Bearer $T" -H 'content-type: application/json' --data-binary @/tmp/bigbody.json
#   HTTP 200 ; read back: disposition=parked reason_len=20000 trigger=probe
```

## 8. Pacing arithmetic for the round (165 rows x 1 write)

Floor is set by the bucket, not the shards: `(165 - 60) / 1.0 = 105 s` of wall clock, whatever the
shard count. Per-shard aggregate must stay <= 1.0 w/s, so with `S` shards the per-row period must be
`>= S` seconds, i.e. `sleep = max(0, S - per_call_seconds)` where per_call is 2.19 s unpinned and
0.31 s pinned. Unpinned, S=3 is the last safe count (1.38 w/s finishes in 120 s before the 60-token
reserve, good for 158 s, runs out); S=4 429s at ~t=71 s. Pinned, even S=1 (3.23 w/s) drains the
reserve in 27 s and MUST sleep.

