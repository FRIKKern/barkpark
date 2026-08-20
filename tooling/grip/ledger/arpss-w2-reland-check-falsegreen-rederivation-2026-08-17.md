# reland-check silent false-green — re-derivation recipe (2026-08-17)

Epic: api-read-path-security-sweep, wave 2, slice `reland-check-silent-falsegreen`.
Host under test: `https://guerrilla.barkpark.cloud` (the workflow's default `LEDGER_BASE`).

## R1 — an HTTP error body yields findings=0, exit 0 (the false green)

    cd /Volumes/SATECHI/github/barkpark
    curl -sS -o /tmp/rc404.json 'https://guerrilla.barkpark.cloud/v1/data/query/production/nosuchtype?perspective=published&limit=1000'; echo "curl_rc=$?"
    printf 'api/lib/foo.ex\n' > /tmp/rcfiles.txt
    python3 tooling/task-obsession/reland_check.py --files /tmp/rcfiles.txt --tasks /tmp/rc404.json --out /tmp/f.json 2>&1; echo "py_rc=$?"
    cat /tmp/f.json

Expected today: `curl_rc=0` (no `--fail`, so the workflow's `if ! curl` skip-notice branch is
never taken), `RELAND_FINDINGS=0`, `py_rc=0`, and `"digests_scanned": 0`.

## R2 — corpus truncation at 1000, and limit is clamped (not raisable)

    curl -s 'https://guerrilla.barkpark.cloud/v1/data/query/production/task?perspective=published&limit=5&offset=1000&fields=_id' \
      | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print("keys",list(r.keys()),"docs_at_1000",len(r["documents"]))'
    curl -s 'https://guerrilla.barkpark.cloud/v1/data/query/production/task?perspective=published&count=true&limit=1' | head -c 200
    curl -s 'https://guerrilla.barkpark.cloud/v1/data/query/production/task?perspective=published&limit=2000&fields=_id' \
      | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print("returned",len(r["documents"]),{k:v for k,v in r.items() if k!="documents"})'

Expected today: rows exist at offset=1000; `total` is 6212 only when `count=true` is passed
(otherwise the response carries no total, so the truncation is undetectable by the caller);
`limit=2000` is silently clamped to 1000 — the fix must paginate on `offset`.

## R3 — the check is vacuous even on a HEALTHY fetch (no land digests exist)

    python3 - <<'EOF'
    import json,urllib.request,os
    tok=json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token']
    n=w=0
    for off in range(0,7000,1000):
        u='https://guerrilla.barkpark.cloud/v1/data/query/production/task?perspective=published&limit=1000&offset=%d'%off
        docs=json.load(urllib.request.urlopen(urllib.request.Request(u,headers={'Authorization':'Bearer '+tok})))['result']['documents']
        if not docs: break
        for d in docs:
            n+=1
            if d.get('landed') or ((d.get('content') or {}).get('landed') if isinstance(d.get('content'),dict) else None): w+=1
    print('docs',n,'with_landed',w)
    EOF

Expected today: `docs 6212 with_landed 0` (same result anonymously). `content.landed` is written
only by the GitHub merge-event bridge (`api/lib/barkpark/plugins/github/merge_events.ex:118` ->
`Tasks.reconcile_merge_gate/3` -> `merge_landed/2` at `api/lib/barkpark/tasks/close.ex:642`), and
no live task carries it. Absence is genuine, not redaction: `lead_live_probe` is likewise
undeclared in `api/lib/barkpark/tasks/schema.ex` yet surfaces on an authenticated read.

## R4 — the token is already in the job env

    git show origin/main:.github/workflows/reland-check.yml | grep -n 'LEDGER_TOKEN\|continue-on-error\|Bearer\|curl -sS\||| true'

Expected: `60: LEDGER_TOKEN: ${{ secrets.BARKPARK_TASK_TOKEN }}` in the same step that runs the
tokenless ledger curl at line 65 — no new secret plumbing is needed to authenticate the main fetch.
