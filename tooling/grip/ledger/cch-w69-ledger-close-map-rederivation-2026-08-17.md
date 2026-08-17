# cch w69 — ledger-close map re-derivation recipes (2026-08-17)

Every integer the Law-0 footer needs, with the one command that re-derives it.
origin/main at derivation = `05a98dd2cadd10b649c3bc17cf75145a7571f80f`.

## Route-A vs Route-B row sets (the 9-row delta)

    bp task get cloud-console-hardening-epic -o json > /tmp/ra.json
    TOK=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
    curl -sf -G -H "Authorization: Bearer $TOK" \
      'https://guerrilla.barkpark.cloud/v1/data/query/production/task' \
      --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' \
      --data-urlencode 'limit=1000' > /tmp/rb.json
    python3 -c "import json;a={c['doc_id'] for c in json.load(open('/tmp/ra.json'))['children']};b={d['_id'].replace('drafts.','') for d in json.load(open('/tmp/rb.json'))['result']['documents']};print('A-not-B:',sorted(a-b));print('B-not-A:',sorted(b-a))"

Result: A=903, B=894, B-not-A empty, A-not-B = 9 ids that literally BEGIN with
`drafts.` (Route A's `doc_id` keeps the prefix, so the `.replace('drafts.','')`
normaliser in the given one-liner never matches them). All nine are draft-only
rows — 3 `lifecycle_status: cancelled`, 6 `open` (3 `zz-p*` probe stubs, a
near-duplicate wave-64 Law-0 pair, one cancelled foreign probe). NOT missed
published rows.

## Live denominator + lifecycle census

    python3 -c "import json,collections;ch=json.load(open('/tmp/ra.json'))['children'];pub=[c for c in ch if not c['doc_id'].startswith('drafts.')];print(len(pub),collections.Counter(c.get('lifecycle_status') for c in pub))"

## Closes booked today (post-digest movement)

    python3 -c "import json;docs=json.load(open('/tmp/rb.json'))['result']['documents'];rows=[((d.get('claim') or {}).get('closed_at'),d['_id'],(d.get('claim') or {}).get('closed_by')) for d in docs if (d.get('claim') or {}).get('closed_at','')>='2026-08-17'];[print(r) for r in sorted(rows)]"

## Row state one-liner (any slug)

    bp task get <slug> -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];c=d['content'];cl=d.get('claim');ac=c.get('acceptance_criteria') or [];print(d.get('doc_id'),d.get('priority'),d.get('assignee'),(cl or {}).get('closed_at'),sum(1 for a in ac if a.get('met')),'/',len(ac))"

Note: `bp task get -o json` nests everything under `.doc` / `.doc.content` —
a top-level `.status`/`.acceptance_criteria` read returns null and reads as
"empty row".

## Rollback-pair fence

    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | grep -n "rollback_refusal\|teardown_refusal\|defp rollback_copy"
    for n in $(gh pr list --state open --limit 100 --json number --jq '.[].number'); do gh pr diff $n --name-only | grep -q 'cloud/lib/barkpark_cloud/sites/deploy.ex' && echo "COLLIDES: $n"; done

## twofa duplicate authorisation (on main, in writing)

    git show origin/main:design/audit-actions.json | grep -o '"verb": "twofa[^}]*}'
