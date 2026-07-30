# PDS w25 — adjudication fields are TOP-LEVEL on the HTTP envelopes, nested only under `bp task get`

Verdict: the census is reading the RIGHT key path. `GET /v1/data/query/production/task` and
`GET /v1/data/doc/production/task/<id>?perspective=published` both FLATTEN `Document.content`
into the document envelope — `disposition`, `disposition_reason`, `disposition_owner`,
`reopen_trigger` are top-level and there is no `content` wrapper. `bp task get -o json` is the
odd one out: `.doc.content.<field>`.

## Re-derivation

```bash
T=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")

# 1. query envelope (what pds-ledger-census.sh reads, :458)
curl -s -H "Authorization: Bearer $T" \
  'https://guerrilla.barkpark.cloud/v1/data/query/production/task?limit=1000&offset=0' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);t=[x for x in d['result']['documents'] if x['_id']=='task-606ba84ecae99043'];print(sorted(t[0].keys()) if t else 'not on this page')"

# 2. doc envelope — NOTE the /task/ segment; omitting the type 404s
curl -s -H "Authorization: Bearer $T" \
  'https://guerrilla.barkpark.cloud/v1/data/doc/production/task/task-606ba84ecae99043?perspective=published' \
  | python3 -m json.tool | head -40

# 3. CLI
bp task get task-606ba84ecae99043 -o json | python3 -c "import sys,json;print(json.load(sys.stdin)['doc']['content'].keys())"
```

## Corpus-wide counts (3,810 rows, 4 pages of limit 1000, 2026-07-30)

| key | non-empty TOP-LEVEL | non-empty under `content.` |
|---|---|---|
| disposition | 172 | 0 |
| disposition_reason | 193 | 0 |
| disposition_owner | 171 | 0 |
| reopen_trigger | **1** | 0 |

The single `reopen_trigger` in the entire corpus is the survey's scratch row
`task-606ba84ecae99043` (len 64), which has no `parent_id` and is therefore OUTSIDE the epic
closure. Clause 4 will read 0 structured triggers across the closure — RED for the RIGHT
reason (the rows genuinely have none), not for a key-path reason.

13 rows carry a literal top-level `content` key (a doubly-nested `content.content` written by
hand, e.g. `mob-bl-push-hardening`); none of them hides an adjudication field.
