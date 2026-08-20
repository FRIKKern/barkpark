# Re-derivation recipes — claim.expired_at field truth (W43 verify, 2026-08-02)

Settles the wave-43 contradiction: does `claim.expired_at` exist on live task
rows? It does — 403 of 3193 claim-bearing rows carry it, never null. The
"absent" reading came from PDS-D323, which is a correct statement about a
DIFFERENT question (deriving LIVE claims from it returns zero, because the REAP
is what writes it).

## R1 — field census over a fresh full dump

```bash
bp task ls --all -o json > /tmp/t.json
python3 -c "
import json,collections
d=json.load(open('/tmp/t.json'))['docs']
wc=[x for x in d if x.get('claim')]
print('rows',len(d),'with claim',len(wc))
k=collections.Counter()
for x in wc:
  for kk in x['claim']: k[kk]+=1
print(k)
print('expired_at null-valued',sum(1 for x in wc if 'expired_at' in x['claim'] and x['claim']['expired_at'] is None))
"
```
2026-08-02 20:19 local: rows 4948; with claim 3193; `expired_at` 403,
`previous_worker` 403, `released_at`/`released_by` 47, `closed_at`/`closed_by`
2795, `now` 662, `resources` 61. Zero null-valued `expired_at`.

## R2 — the two lapse shapes are NOT the same key

```bash
python3 -c "
import json
d=json.load(open('/tmp/t.json'))['docs']
A=[x for x in d if x['lifecycle_status']=='open' and (x.get('claim') or {}).get('worker') is None
   and x['claim'].get('previous_worker') and x['claim'].get('expired_at')
   and not x['claim'].get('released_at') and not x['claim'].get('closed_at')]
B=[x for x in d if x['lifecycle_status']=='in_progress']
print('SHAPE A',len(A),'SHAPE B',len(B))
print('B claims carry expired_at:',[bool((x.get('claim') or {}).get('expired_at')) for x in B])
"
```
SHAPE A 196 (keyed on `expired_at` — FIRES). SHAPE B 2, and NEITHER carries
`expired_at` — by construction, since the lease is still held. A single check
keyed on `expired_at` is non-vacuous for A and **vacuous for B**.

Shape B's real key: `lifecycle_status == "in_progress"` AND
`now() - claim.ts_iso > task_lease_ttl_seconds` (2700 s default) — plus
`claim.now.text` as work evidence. The sweeper cron is `* * * * *`, so B is a
window of at most TTL + 60 s; the same row reappears as A afterwards.

## R3 — exactly what the sweeper writes and clears (source of truth)

```bash
git show origin/main:api/lib/barkpark/tasks/ttl_sweeper.ex | sed -n '365,392p'
git show origin/main:api/lib/barkpark/tasks/claim.ex      | sed -n '296,318p'
git show origin/main:api/lib/barkpark/tasks/close.ex      | sed -n '535,545p'
```
- REAP (`apply_reap/1`) MERGES onto the old claim: sets `worker => nil`,
  `epoch+1`, `ts_iso`, `expired_at` (same instant as `ts_iso`),
  `previous_worker` (= old worker); DELETES `resources`; sets
  `lifecycle_status => "open"`. It PRESERVES `now`, `work_digest`,
  `work_field_digests`, any `closed_by`/`closed_at`, and `content.assignee`.
- CLAIM (`claim.ex`) **REPLACES the whole claim map** — a re-claim therefore
  ERASES `expired_at`, `previous_worker` and `now`. Lapse history is not
  cumulative; only the most recent unrepaired lapse is observable.
- CLOSE merges `closed_by`/`closed_at` onto whatever claim exists, so a row
  closed out of the swept state keeps `expired_at` (111 done rows do).

Corollary: `ts_iso == expired_at` on all 403 expired rows, and `worker is None`
⟺ (`expired_at` XOR `released_at`) — 403 + 47 = 450 = every null-worker row.

## R4 — the paged projection DOES carry `claim`

```bash
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
curl -s -H "Authorization: Bearer $TOK" \
  "https://guerrilla.barkpark.cloud/v1/data/query/production/task?limit=500" |
python3 -c "
import json,sys
r=json.load(sys.stdin)['result']
print('count',r['count'],'limit',r['limit'],'returned',len(r['documents']),r['perspective'])
print('claim key on doc:', 'claim' in r['documents'][0])
print('expired_at rows', sum(1 for d in r['documents'] if (d.get('claim') or {}).get('expired_at')))
"
```
`claim` is a TOP-LEVEL key on each projected doc (content is flattened; there is
no `content` key). `expired_at` survives the projection. So the ledger-census
expiry arm costs no extra per-row fetch — but note: `result.count` echoes the
PAGE size, not the board total (limit=1 → count=1), the server caps at 1000
(asked 2000, echoed 1000), and `perspective` is `published`. The arm must page
by explicit offsets exactly as clause (1) of `scripts/pds-ledger-census.sh`
already requires.
