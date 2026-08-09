# Wave 65 immediately-before-dispatch concurrency rescan — re-derivation recipes

Scan taken 2026-08-09T21:14Z–21:20Z. Every row below is a command, not a memory.
All git reads are against `origin/main` after `git fetch origin --prune`.

## 1. Open PRs touching the contested file set

```
gh pr list --state open --limit 100 --json number,mergeable,headRefName,files \
  -q '.[]|.number as $n|.files[]|select(.path|test("registry\\.ex|app\\.js|app\\.css|__app\\.test\\.mjs|__css_check|smoke\\.mjs|scenarios\\.mjs|web/router\\.ex"))|"\($n) \(.path)"'
```

Expected at scan time: 10944 (registry.ex), 10154/10129/9956/6028 (cloud web/router.ex),
10006 + 6028 (app.js + __app.test.mjs), 9530 (api web/router.ex). NOTHING newer than 2026-08-08.

## 2. Nothing new since 21:00Z

```
gh pr list --state all --limit 60 --json number,state,createdAt,mergedAt,headRefName \
  -q '.[]|select(.createdAt>"2026-08-09T20:00:00Z")|"\(.number)\t\(.state)\t\(.createdAt)\t\(.headRefName)"'
git log origin/main -1 --format='%H %cI %s'
```

## 3. cch-w63-s3 merge status (it is a bp slug, NOT a branch name)

```
bp search query "cch-w63-s3"
gh pr view 11378 --json number,state,mergedAt,headRefName
```

## 4. dr-w33 branches vs dr-w33 CLAIMS (branches lag claims by minutes)

```
git for-each-ref --sort=-committerdate --format='%(committerdate:iso8601-strict) %(refname:short)' refs/remotes/origin | head -15
git branch -r | grep -i w33
```

## 5. Live foreign-claim census (the dimension `bp task ls --status` cannot serve)

`--status` is not a flag and `--all` returns ~56MB. Page the query API by `_updatedAt desc`
and treat a claim as LIVE only when `lifecycle_status ∈ {open,in_progress}` AND
`claim.worker` is non-null AND `claim.expired_at` is absent-or-future.

```
python3 - <<'EOF'
import json,urllib.request,os,datetime
tok=json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token']
def q(u):
    return json.load(urllib.request.urlopen(urllib.request.Request(u,headers={'Authorization':'Bearer '+tok})))
now=datetime.datetime.now(datetime.timezone.utc); off=0; hits=[]
while off<1200:
    docs=q('https://guerrilla.barkpark.cloud/v1/data/query/production/task?limit=200&offset=%d&order=_updatedAt+desc'%off)['result']['documents']
    if not docs: break
    for t in docs:
        if t.get('lifecycle_status') not in ('open','in_progress'): continue
        c=t.get('claim') or {}
        if not c.get('worker'): continue
        exp=c.get('expired_at'); alive=True
        if exp: alive = datetime.datetime.fromisoformat(exp.replace('Z','+00:00')) > now
        if alive: hits.append((t['_id'],c['worker'],t['lifecycle_status'],exp,t['_updatedAt']))
    off+=200
print(len(hits)); [print(h) for h in hits]
EOF
```

Counting `claim.worker` alone WITHOUT the lifecycle filter yields 126 rows over the same
600-task window — closed rows retain their worker. That number is a trap; do not quote it.

## 6. dr-w33 slice fences (no fence field exists — extract paths from the whole doc)

```
python3 - <<'EOF'
import json,urllib.request,os,re,urllib.parse
tok=json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token']
for i in ['dr-w33-s1-coverage-window-contract','dr-w33-s2-census-reader-stops-being-the-limiter',
          'dr-w33-s3-digest-names-the-environment','dr-w33-s4-alarm-reaches-a-human',
          'dr-w33-s5-ledger-questions-become-runnable']:
    u='https://guerrilla.barkpark.cloud/v1/data/query/production/task?filter%5B_id%5D='+urllib.parse.quote(i)+'&limit=1'
    t=json.load(urllib.request.urlopen(urllib.request.Request(u,headers={'Authorization':'Bearer '+tok})))['result']['documents'][0]
    print(i, sorted(set(re.findall(r'[\w][\w./-]*\.(?:ex|exs|mjs|js|css|yml|yaml|go|sh|heex)\b',json.dumps(t)))))
EOF
```

## 7. Every reader of `update_checked_at` (S2's blast radius, re-derived)

```
git grep -n "update_checked_at" origin/main -- cloud/lib
for f in $(git grep -ln "update_checked_at" origin/main -- cloud/test | sed 's|^origin/main:||'); do
  echo "$(git show origin/main:$f | grep -c update_checked_at)  $f"; done
git show origin/main:cloud/lib/barkpark_cloud/notifications/digest_email.ex | grep -n "defp format_ts" -A3
```

Three lib readers, not one: `registry.ex:4346` (`order_by: [asc: b.update_checked_at]`,
gated by `update_state == "behind"`), `digest_email.ex:655` (renders it; `format_ts(nil)`
at :783 returns `"never"`), `web/router.ex:9422` (passes it through). Seven test files.
