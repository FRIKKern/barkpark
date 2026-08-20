# Law-0 close-execution readiness — cch wave 66 verify (2026-08-09T22:56:44Z)

Re-derivation recipes for every fact in the `law0-close-execution-readiness` verify report.
Env for all bp reads:

    export BP=https://guerrilla.barkpark.cloud
    export TOK="$(python3 -c 'import json;print(json.load(open("'"$HOME"'/.config/barkpark/config.json"))["token"])')"
    mkdir -p /tmp/w66

## R1 — the published roster, with a truncation guard and a read timestamp

    date -u +%Y-%m-%dT%H:%M:%SZ
    curl -sG "$BP/v1/data/query/production/task" \
      --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' \
      --data-urlencode 'filter[status]=published' \
      --data-urlencode 'limit=1000' \
      -H "Authorization: Bearer $TOK" > /tmp/w66/roster.json
    python3 -c "
    import json,collections
    d=json.load(open('/tmp/w66/roster.json'))['result']; docs=d['documents']
    print('count',d['count'],'len',len(docs),'TRUNCATED' if d['count']!=len(docs) else 'NOT-TRUNCATED')
    c=collections.Counter(x.get('lifecycle_status') for x in docs); print(dict(c))
    print('LIVE(open+in_progress)=',c['open']+c['in_progress'])
    print('drafts.=',sum(1 for x in docs if str(x.get('_id','')).startswith('drafts.')))"

Observed 2026-08-09T22:56:44Z: `count 866 len 866 NOT-TRUNCATED` /
`{'open': 429, 'cancelled': 66, 'done': 370, 'considering': 1}` / `LIVE=429` / `drafts.=0`.

## R2 — D781's twelve PRs: four required contexts at ?per_page=100 + compare-to-main

    cd /Volumes/SATECHI/github/barkpark
    for n in 11376 11377 11378 11135 10725 10727 11102 11104 11105 11134 11106 11015; do
      sha=$(gh pr view $n --json headRefOid --jq .headRefOid)
      mc=$(gh pr view $n --json mergeCommit --jq .mergeCommit.oid)
      echo -n "PR#$n merge=${mc:0:12} $(gh api repos/:owner/:repo/compare/$mc...main --jq '.status') | "
      gh api "repos/:owner/:repo/commits/$sha/check-runs?per_page=100" --jq '[.check_runs[]|select(.name=="Elixir gate" or .name=="Cloud gate" or .name=="Console gate" or .name=="PR references an active task")]|group_by(.name)|map("\(.[0].name)=\(map(.conclusion)|join("/"))")|join("  ")'
    done
    gh api "repos/:owner/:repo/compare/c2dbadfd78...main" --jq '.status'   # -> diverged

## R3 — D781's close list is ALREADY PAID (13 rows, 2026-08-09T19:39Z)

    python3 -c "
    import json
    docs=json.load(open('/tmp/w66/roster.json'))['result']['documents']
    rows=[( (x.get('claim') or {}).get('closed_at'), x['_id'], x.get('lifecycle_status'))
          for x in docs if (x.get('claim') or {}).get('closed_by')=='epic-builder-the-law-0-repayment-twelve-evidence-back']
    [print(r) for r in sorted(rows)]; print('n=',len(rows))"

## R4 — CAS state on every open shipped row (worker is NULL; `previous_worker` is the only self-resume id)

    python3 -c "
    import json
    docs=json.load(open('/tmp/w66/roster.json'))['result']['documents']
    for x in sorted(docs,key=lambda d:d['_id']):
        k=x['_id']
        if not k.startswith(('cch-w63-s','cch-w64-s','cch-w65-')): continue
        if x.get('lifecycle_status')!='open': continue
        c=x.get('claim') or {}; ac=x.get('acceptance_criteria') or []
        met=sum(1 for a in ac if a.get('met') is True)
        print(k, 'epoch=',c.get('epoch'),'worker=',c.get('worker'),'prev=',c.get('previous_worker'),f'{met}/{len(ac)}')"

Close semantics that make `previous_worker` load-bearing:

    git show origin/main:api/lib/barkpark/tasks/internal.ex | sed -n '105,123p'   # close_holder/2 three arms
    git show origin/main:api/lib/barkpark/tasks/close.ex   | sed -n '369,376p'   # check_fencing/2 (epoch only)

## R5 — merge-gate markers actually present on this epic's roster

    python3 -c "
    import json
    docs=json.load(open('/tmp/w66/roster.json'))['result']['documents']
    for x in docs:
        for i,c in enumerate(x.get('acceptance_criteria') or []):
            if isinstance(c,dict) and c.get('merge_gate') is True:
                print(x['_id'],'idx',i,'met',c.get('met'))"

Seven rows carry the marker; only FOUR of them are `cch-w*-s*` slices
(`cch-w63-s7` idx7, `cch-w63-s8` idx12, `cch-w64-s6` idx13, `cch-w65-s2` idx9).
`cch-w64-s6` idx12 is NOT merge-gated — it is a `HIGH-FLIP-RISK DECLARED` criterion.

## R6 — the wave-65/66 close list's PRs (all merged, all four contexts green)

    for n in 11435 11436 11437 11438 11488 11489 11420; do
      sha=$(gh pr view $n --json headRefOid --jq .headRefOid)
      mc=$(gh pr view $n --json mergeCommit --jq .mergeCommit.oid)
      echo -n "PR#$n merge=${mc:0:12} $(gh api repos/:owner/:repo/compare/$mc...main --jq '.status') | "
      gh api "repos/:owner/:repo/commits/$sha/check-runs?per_page=100" --jq '[.check_runs[]|select(.name=="Elixir gate" or .name=="Cloud gate" or .name=="Console gate" or .name=="PR references an active task")]|group_by(.name)|map("\(.[0].name)=\(map(.conclusion)|join("/"))")|join("  ")'
    done
    gh pr diff 11420 --patch | grep -c "^+.*| D78[01] |"    # -> 2 (this is the charter PR cch-w64-s5 c11 names)
