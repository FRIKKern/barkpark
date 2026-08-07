# dr-w14 — ledger closability of the 54 one-short dr-* rows, and the exact 409 shapes

Re-derivation recipes. Every number below is reproduced by running the command beside it.
Verified 2026-08-07 against `origin/main` = `77cf2060c` and live `guerrilla.barkpark.cloud`.

## 1. The population: 54 one-short rows

```bash
bp task ls --all -o json > /tmp/ledger.json
python3 - <<'EOF'
import json
d=json.load(open('/tmp/ledger.json'))['docs']
dr=[t for t in d if (t.get('doc_id') or '').startswith('dr-')]
def cp(t):
    c=t.get('criteria_progress')
    if c: return c['met'],c['total']
    ac=t['content'].get('acceptance_criteria') or []
    return sum(1 for a in ac if a.get('met')),len(ac)
one=[t for t in dr if cp(t)[1]>0 and cp(t)[0]==cp(t)[1]-1]
print(len(dr),'dr-* rows;',len(one),'one-short; all lifecycle=',set(t['lifecycle_status'] for t in one))
EOF
# -> 232 dr-* rows; 54 one-short; all lifecycle= {'open'}
```

`doc_id` — NOT `title`, NOT tags — is the only reliable selector. Tag `deploy-reliability`
returns 101 rows and misses 131 of the epic's own children.

## 2. Joining a row to ITS PR — the only method that does not lie

`gh search prs --repo FRIKKern/barkpark "<slug>"` matches on TOKENS, so it returns
title-similar PRs that never mention the row. Verify the body verbatim:

```bash
gh api -X GET search/issues \
  -f q='repo:FRIKKern/barkpark type:pr "dr-w13-s3-deferral-columns-reach-the-wire" in:body' \
  --jq '.total_count, ([.items[].number]|@json)'
# -> 1 / [10301]     (builders end the PR body with "Task: <slug>")
```

42 of the 54 have exactly one such verbatim-linked PR. 12 have zero.

## 3. The three 409 shapes, run against the live server

```bash
TOK=$(python3 -c "import json,os;c=json.load(open(os.path.expanduser('~/.config/barkpark/config.json')));\
print([v for k,v in c.items() if 'token' in k.lower()][0] if 0 else __import__('re').search(r'\"[A-Za-z0-9_.-]{20,}\"',json.dumps(c)).group(0).strip('\"'))")

# (a) LIVE foreign claim -> 409 not_holder, WITH the remedy in the body
curl -s -w '\nHTTP=%{http_code}\n' -X POST \
  https://guerrilla.barkpark.cloud/v1/tasks/dr-w2-s4-scrub-knows-our-own-token/close \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"worker_id":"verify-worker","observed_epoch":"7"}'
# -> HTTP 409  {"reason":"not_holder:dr-w6-s3-ledger-repair", "message":"… --set holder_override=\"…\" …"}

# (b) REAPED claim (worker:null, previous_worker set), CORRECT epoch -> same 409
curl -s -w '\nHTTP=%{http_code}\n' -X POST \
  https://guerrilla.barkpark.cloud/v1/tasks/dr-w13-s4-runner-503-test-stops-flaking/close \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"worker_id":"verify-worker","observed_epoch":"6"}'
# -> HTTP 409  {"reason":"not_holder:epic-builder-the-runner-503-honesty-test-stops-losing", …}

# (c) WRONG epoch -> 409 fenced_off, a BARE body with no message and no current epoch
curl -s -w '\nHTTP=%{http_code}\n' -X POST \
  https://guerrilla.barkpark.cloud/v1/tasks/dr-w13-s4-runner-503-test-stops-flaking/close \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"worker_id":"verify-worker","observed_epoch":"999"}'
# -> HTTP 409  {"ok":false,"reason":"fenced_off"}
```

Gate order is `check_fencing` (epoch) -> `check_close_holder` -> `check_work_digest` ->
`check_criteria_payload` -> `check_criteria_proven`:

```bash
git show origin/main:api/lib/barkpark/tasks/close.ex | sed -n '318,326p'
git show origin/main:api/lib/barkpark/tasks/internal.ex | sed -n '58,78p'   # close_holder's 3 allow-arms
```

`close_holder/2` allows only: no claim at all (`:unclaimed`), `claim.worker == worker_id`
(`:holder`), or `worker_id in [previous_worker, released_by]` (`:self_resume`). A REAPED
row therefore refuses every NEW worker name — the epoch is irrelevant to that refusal.

## 4. The claim-shape census that predicts the sweep's blast radius

```bash
python3 - <<'EOF'
import json,collections
d=json.load(open('/tmp/ledger.json'))['docs']
op=[t for t in d if (t.get('doc_id') or '').startswith('dr-') and t['lifecycle_status']=='open']
c=collections.Counter()
for t in op:
    cl=t.get('claim')
    c['no_claim' if not cl else ('live_holder' if cl.get('worker') else 'reaped/expired')]+=1
print(len(op), dict(c))
EOF
# -> 218 {'reaped/expired': 52, 'no_claim': 164, 'live_holder': 2}
```

Only **2** open dr-* rows carry a LIVE foreign claim (both held by `dr-w6-s3-ledger-repair`,
claimed 2026-08-06T18:58/19:00Z). The "16 fenced stale claims" figure is not reproducible
by any claim-shape query; 16 is the count in `dr-w10-bl-epic-ledger-stamp-repair`'s
"16 STAMP-NOW rows" and in `dr-bl-w8-stamp-sixteen-merged-and-unstamped-tasks`.

## 5. The criteria gate is REAL and the manifest denies it

```bash
git show origin/main:api/lib/barkpark/tasks/close.ex | sed -n '437,449p'
# check_criteria_proven(doc,"done",…) -> {:error,{:criteria_unmet, indices}} unless overridden
git show origin/main:api/lib/barkpark/plugins/tasks.ex | grep -n 'never block a close'
# 774: "…Unmet criteria never block a close (soft warning only). " <>
```

The served manifest sentence is false for `done` closes; it is true only for
`cancelled`/`blocked`, which are exempt by name. Already recorded as D78 in
`.claude/workflows/bp-barkpark-tasks-mobile-charter.md:300`.

## 6. The recipe that actually closes a merge-gated row (no override)

Merge-gate criteria carrying a `landed` digest are DEDUCTED from the unmet set on the
server's own authority (`unmet_after_autostamp/2`). The honest, override-free ritual, which
`dr-w12-bl-close-satisfied-merge-gated-children` criterion 0 already prescribes:

    bp task claim <slug> <worker>            # reaped rows re-claim; NEW epoch comes back
    bp task stamp …                          # holder-only
    bp task close <slug> <worker> <new-epoch>

For the 2 LIVE-held rows a re-claim is unavailable (`release` is holder-gated with no
override), so the only path is the one the 409 itself names:
`--set holder_override="<why you are closing someone else's claim>"`.
