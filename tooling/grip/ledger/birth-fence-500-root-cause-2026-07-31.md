# Re-derivation recipes — birth-fence-500 root cause (PDS wave 29 verify, 2026-07-31)

VERDICT: the 500 is **not** the birth fence and **not** `disposition`. It is
`DBConnection.ConnectionError` — pool starvation on guerrilla (POOL_SIZE
defaults to 10, 2 vCPU, many concurrent agent waves). Every `POST
…/v1/data/mutate/…` that exceeds ~15s of pool contention 500s, adjudicated or
bare. Admin token below is the operator's own config value, quoted so the
recipe runs; rotate if this file ever leaves the repo.

```
TOKEN=$(python3 -c 'import json;print(json.load(open("'"$HOME"'/.config/barkpark/config.json"))["token"])')
```

## R1 — the 500 is latency-correlated, NOT disposition-correlated

```bash
for i in 1 2 3 4 5 6 7 8; do
  if [ $((i % 2)) -eq 0 ]; then EXTRA='"disposition":"open",'; TAG=WITHDISP; else EXTRA=''; TAG=NODISP; fi
  T="pdsv29 probe $TAG run $i quokka lantern $RANDOM"
  curl -s -o /tmp/p$i.json -w "$TAG %{http_code} %{time_total}\n" \
    -X POST https://guerrilla.barkpark.cloud/v1/data/mutate/production \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"mutations\":[{\"create\":{\"_type\":\"task\",\"title\":\"$T\",\"description\":\"probe\",\"kind\":\"task\",\"lifecycle_status\":\"open\",$EXTRA\"_probe\":true}}]}"
done
```
Observed 2026-07-31: 500s at 24.5s and 19.6s, **both on bare (NODISP) births**;
all four disposition-carrying births returned 200 in 6.6–13.6s. Every success
was ≤14.7s; every failure >19s.

## R2 — the raw cause, from the server's own log, by request_id

```bash
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
 "journalctl -u barkpark-slot@blue --since '40 min ago' --no-pager > /tmp/bl.txt; \
  L=\$(grep -n '<REQUEST_ID>.*DBConnection' /tmp/bl.txt | head -1 | cut -d: -f1); \
  sed -n \"\$L,\$((L+10))p\" /tmp/bl.txt"
```
Stack: `Ecto.Repo.Queryable.one/3` → `Barkpark.Tenancy.get_default_project/0`
(tenancy.ex:282) → `Content.WriteScope.read_default_project_id/1`
(write_scope.ex:270) → `resolve_read_dataset_id/2` (:232). A trivial tenancy
lookup that could not check out a connection.

## R3 — the fence PASSED the request that 500'd

Same log, same request_id, 24s BEFORE the 500:
`[warning] pds birth fence: unadjudicated task birth "drafts.task-…" — no
content.disposition (allowed; …)`. The fence returned `:ok`; the failure is
downstream.

## R4 — pool exhaustion is server-wide, not task-create-specific

```bash
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
 "grep -c 'DBConnection.ConnectionError' /tmp/bl.txt; \
  grep -c 'Sent 500 in' /tmp/bl.txt; \
  grep -o 'timed out because it queued and checked out the connection for longer' /tmp/bl.txt | wc -l; nproc"
git grep -n 'pool_size' origin/main -- api/config/runtime.exs
```
40-min window: 62 ConnectionErrors, 15 `Sent 500`, all 15 on
`POST …/v1/data/mutate/…` (13 workspace-scoped, 2 bare).
`POOL_SIZE` unset → `"10"` (runtime.exs:717) on a 2-vCPU host;
`Barkpark.EdgeProjector.ProjectorWorker` is a named connection hog.

## R5 — all three fence branches are LIVE-PROVEN against prod (L1)

```bash
post(){ curl -s -w ' <- %{http_code}\n' -X POST https://guerrilla.barkpark.cloud/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$1" | head -c 300; }
post '{"mutations":[{"create":{"_type":"task","title":"probe wontfix '"$RANDOM"'","kind":"task","lifecycle_status":"open","disposition":"wontfix"}}]}'   # 422 disposition
post '{"mutations":[{"create":{"_type":"task","title":"probe hollow '"$RANDOM"'","kind":"task","lifecycle_status":"open","disposition":"parked"}}]}'     # 422 reopen_trigger
post '{"mutations":[{"create":{"_type":"task","title":"probe Parked '"$RANDOM"'","kind":"task","lifecycle_status":"open","disposition":"Parked"}}]}'     # 422 disposition (mis-cased)
```
Happy path, same door, 200 with the term persisted:
`"disposition":"parked","reopen_trigger":"when wave 29 seals"` echoed in the
create result document.

## R6 — the task schema does not declare `disposition`

```bash
bp schema get task -o json | python3 -c 'import sys,json;s=json.load(sys.stdin);print("disposition" in json.dumps(s))'
```
`False`. 30 declared fields; `disposition`/`reopen_trigger` are undeclared
content keys that persist anyway. Nothing schema-side validates them — the
birth fence in `writer.ex` is the ONLY validator.
