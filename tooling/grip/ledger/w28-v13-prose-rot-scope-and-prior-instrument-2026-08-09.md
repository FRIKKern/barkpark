# w28-v13 — prose-rot scope + prior instrument: re-derivation recipes

All commands run 2026-08-09 ~10:00-10:25Z from `/Volumes/SATECHI/github/barkpark`.
Tree under test is a clean `git archive origin/main` extract, NOT the working checkout.

## 0. pin the tree

```sh
rm -rf /tmp/w28ar && mkdir -p /tmp/w28ar && git archive origin/main | tar -x -C /tmp/w28ar
```

## 1. the citation corpus, and the truncation split (D469 rule 1)

```sh
cd /tmp/w28ar
grep -rEoh '\b(dr|cch)-w[0-9]+[a-z0-9-]*' . \
  --include='*.ex' --include='*.exs' --include='*.go' \
  --include='*.mjs' --include='*.js' --include='*.yml' --include='*.sh' \
  | sed 's/-$//' > /tmp/cits.txt
wc -l /tmp/cits.txt                      # 1613 occurrences
grep -cE '^(dr|cch)-w[0-9]+-(s[0-9]+[a-z]?|bl|hg|r[0-9]+)-[a-z][a-z0-9-]*$' /tmp/cits.txt   # 91 conform
grep -vcE '^(dr|cch)-w[0-9]+-(s[0-9]+[a-z]?|bl|hg|r[0-9]+)-[a-z][a-z0-9-]*$' /tmp/cits.txt  # 1522 truncated
```

## 2. where the truncated citations LIVE (the landability question)

```sh
cd /tmp/w28ar
grep -rEn '\b(dr|cch)-w[0-9]+[a-z0-9-]*' . \
  --include='*.ex' --include='*.exs' --include='*.go' \
  --include='*.mjs' --include='*.js' --include='*.yml' --include='*.sh' > /tmp/citlines.txt
wc -l /tmp/citlines.txt                                                     # 1583 lines
cut -d: -f1 /tmp/citlines.txt | sort | uniq -c | sort -rn | head -5
grep -cE '^\S+:[0-9]+: *(test|describe|it)\(' /tmp/citlines.txt             # 284 inside test NAMES
grep -cE '^\S+:[0-9]+:\s*(//|#|\*)'          /tmp/citlines.txt              # 1056 on comment lines
```

## 3. verdict-adjacency (D469 rule 2), case-SENSITIVE, non-.md

```sh
cd /tmp/w28ar && python3 - <<'EOF'
import re,os
ID=re.compile(r'\b(?:dr|cch)-w\d+[a-z0-9-]*|#\d{4,5}\b')
VERB=re.compile(r'DOES NOT EXIST|not_found|never filed|is OPEN|is CLOSED|must still land|is MERGED')
exts=('.ex','.exs','.go','.mjs','.js','.yml','.sh')
tot=0;hits={}
for root,d,fs in os.walk('.'):
    if '/.git' in root: continue
    for f in fs:
        if not f.endswith(exts): continue
        p=os.path.join(root,f); t=open(p,encoding='utf-8',errors='replace').read()
        n=sum(1 for m in ID.finditer(t) if VERB.search(t[m.end():m.end()+80]))
        if n: hits[p]=n; tot+=n
print(tot,len(hits)); [print(n,p) for p,n in sorted(hits.items(),key=lambda x:-x[1])]
EOF
# 16 hits / 4 files. Add '.md' to exts and re.I -> 145 hits / 47 files (28 in the DR charter).
```

## 4. the prior instruments

```sh
cd /Volumes/SATECHI/github/barkpark
bash scripts/docs-anchors-check.sh >/tmp/dac.out 2>&1; echo $?    # 0, "PASS (19 warning(s))"
node tooling/doc-truth/verify-docs.mjs --code >/tmp/vd.out 2>&1; echo $?   # 0 ALWAYS (advisory)
tail -8 /tmp/vd.out            # TOTALS confirmed 10296 · false 1618 · stale 107 · unverifiable 372
node tooling/doc-truth/acceptance-code-comments.mjs; echo $?      # 0, RESULT: PASS
node tooling/doc-truth/retired-terms.mjs; echo $?                 # 0, GATE: PASS
grep -rn "verify-docs\|acceptance-code-comments\|retired-terms" .github/workflows/
# only doc-gates.yml:447-448 gate the latter two; verify-docs is NOT gated anywhere.
sed -n '8,40p' .github/workflows/doc-gates.yml   # trigger paths: NO **/*.mjs, NO **/*.js
```

## 5. truncated ids really are unresolvable

```sh
bp task get cch-w32-s1 -o json   # not_found
bp task get dr-w19-s5  -o json   # not_found
bp task get dr-w26-s5  -o json   # not_found
bp task get dr-w26-s5-crown-gets-its-writer -o json   # EXISTS, assignee set, claim epoch 7
```

## 6. the deferral-cause population, from the running DB (L1)

```sh
Q=$(printf "select coalesce(deferral_cause,'NULLCAUSE') c, count(*) n, min(inserted_at), max(inserted_at) from deployments where status='deferred' group by 1 order by 2 desc;" | base64)
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
  "docker exec cloud-db-1 sh -c 'echo $Q | base64 -d > /tmp/q.sql; psql -U \$POSTGRES_USER -d \$POSTGRES_DB -f /tmp/q.sql'"
```

Result at `now() = 2026-08-09 10:22:54.882837+00`:

```
 NULLCAUSE                | 1818 | 2026-08-05 21:27:11.41321  | 2026-08-07 10:01:54.507774
 BOX_AT_CAPACITY_DEFERRED | 1279 | 2026-08-07 10:12:35.033826 | 2026-08-09 10:14:31.913016
```

NULL is a CLOSED population (max frozen 2 days; count unchanged from D471's 08:05Z reading of 1818).
Live share is 1818/3097 = **58.70%**, not 59.7%, and it decays every hour the box defers.
Note the host: `cloud-db-1` runs on `barkpark.cloud`, not on `89.167.28.206` (which refuses this key).
Credentials come from the container's own `$POSTGRES_USER`/`$POSTGRES_DB`; the role `postgres` does not exist.
