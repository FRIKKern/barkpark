# Re-derivation recipe — `bp task create` stalls, then lies (PDS wave 24, task-create-lie)

Verifier: w24 `task-create-lie`. Measured 2026-07-30 14:14–14:25 UTC against
`https://guerrilla.barkpark.cloud` (slot `barkpark-slot@blue`, host NOT quiet —
concurrent waves were live and `/v1/capabilities` was 429-ing during the run, so
every wall-clock number below is an UPPER bound that includes contention).

## Claim

Every `type:task` CREATE pays a full-backlog dedup scan in the request path
(`api/lib/barkpark/content/writer.ex:139` → `Barkpark.Tasks.Dedup.check_new_task/5`,
`api/lib/barkpark/tasks/dedup.ex:136-162` `fetch_candidates/2`, `limit 5000`,
selecting full `content` JSONB). Cost grows with the NEW description's distinct
token count because `Barkpark.Tasks.Similarity.score/6`
(`api/lib/barkpark/tasks/similarity.ex:119`) recomputes `tokens(new_task)` INSIDE
the per-candidate loop — O(N_candidates x |new description|). On a ledger with
>= 1000 `type:task` rows this exceeds the 15 s DB checkout budget, the request
raises `DBConnection.ConnectionError`, and the catch-all at
`api/lib/barkpark/content/errors.ex:578` answers `500 internal_error / "unknown
error"` — a 500 that names nothing after 20-60 s.

## Recipe

```bash
TOK=$(jq -r .token ~/.config/barkpark/config.json)
SRV=https://guerrilla.barkpark.cloud

# 0. corpus size (the query route hard-caps limit at 1000 — this is a FLOOR)
curl -s "$SRV/v1/data/query/production/task?perspective=raw&limit=5000" \
  -H "Authorization: Bearer $TOK" \
| python3 -c "import sys,json;d=json.load(sys.stdin)['result'];print(d['count'],d['limit'])"

# 1. size sweep on the raw mutate route with UNIQUE nonsense prose (no lexical
#    overlap => no 409 confound). desc_bytes 0 / 2000 / 5000 / 10000 / 20000.
python3 -c "
import random,string,json,sys
n=int(sys.argv[1]); random.seed(n)
d=' '.join(''.join(random.choices(string.ascii_lowercase,k=7)) for _ in range(n//8))[:n]
op={'_type':'task','kind':'task','lifecycle_status':'open','title':'probe %d'%n,'description':d}
print(json.dumps({'mutations':[{'create':op}]}))" 5000 > /tmp/g.json
curl -s -o /tmp/g.resp -w '%{http_code} %{time_total}\n' -X POST \
  "$SRV/v1/data/mutate/production" -H "Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' -d @/tmp/g.json --max-time 180
cat /tmp/g.resp

# 2. the server-side truth the CLI never shows (30 s client budget vs the
#    request's real lifetime), and the exception behind "unknown error"
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  "journalctl -u barkpark-slot@blue --since '<t0>' --no-pager \
   | grep -E 'data/mutate|Sent 500|Sent 409|DBConnection'"
```

## Observed (2026-07-30, busy host)

| probe | desc bytes | http | secs |
|---|---|---|---|
| raw mutate, nonsense | 0 | 200 | 10.28 |
| raw mutate, nonsense | 2000 | 500 unknown error | 19.64 |
| raw mutate, nonsense | 5000 | 500 unknown error | 50.77 |
| `bp task create` | 37 | 200 draft | 8.98 |
| `bp task create` | 2000 | `bp: task create: unknown error` | 29.79 |
| `bp task create` | 5000 / 10000 | client `context deadline exceeded` | 30.07 / 30.05 |

Server journal for the same window: `Sent 500 in 29441ms`, `Sent 500 in 37144ms`,
`Sent 500 in 61024ms`, `Sent 409 in 40764ms` — i.e. requests the CLI abandoned at
30 s stayed alive server-side for up to 61 s.

Isolation matrix (2 KB description, realistic prose): unscoped/no-brief 18.81 s,
unscoped/brief 14.91 s, scoped/no-brief 12.19 s, scoped/brief 12.84 s — so neither
the injected `content.brief` nor the `/w/:ws/p/:proj` scoping explains it; only
description size does.

## Falsifier

If `fetch_candidates/2` is made FTS-pre-filtered (or `tokens(new_task)` is hoisted
out of `score/6`), the 5000-byte cell must return 2xx in single-digit seconds on a
quiet host. If it still 500s, the cause is NOT the dedup scan and this row is wrong.
