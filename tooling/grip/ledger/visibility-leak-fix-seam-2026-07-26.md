# visibility-leak-fix-seam — re-derivation recipes (verifier, 2026-07-26)

Each row re-derives one load-bearing fact from scratch.

## Live leak + oracle

- Anonymous search returns private-type docs; query route 404s the same type:
  `curl -s 'https://guerrilla.barkpark.cloud/v1/data/search/production?q=e&type=session&limit=2' | head -c 400 ; curl -s -o /dev/null -w 'query/session=%{http_code}\n' 'https://guerrilla.barkpark.cloud/v1/data/query/production/session?limit=1'`
- Counts/facets are an existence oracle — anonymous browse facets name private types (session, document, bulldoc, listener):
  `curl -s 'https://guerrilla.barkpark.cloud/v1/data/search/production?q=%20&limit=1' | python3 -c "import sys,json;j=json.load(sys.stdin);print(j.get('count'),j.get('facets',{}).get('type'))"`
- Schema visibility census (5 public: command, metric, paper, tag, task; 34 private):
  `bp schema ls -o json | python3 -c "import sys,json,collections;d=json.load(sys.stdin);print(collections.Counter(x.get('visibility') for x in d['schemas']));print([x['name'] for x in d['schemas'] if x.get('visibility')=='public'])"`

## Seam + predicate

- All four callers already thread `caller_context` into search opts (the predicate input exists at the retriever):
  `grep -n "caller_context" api/lib/barkpark_web/plugs/scope_helpers.ex` (line 72 — `from_assigns` puts it for Conn AND both Socket structs)
- QueryController's rule the filter mirrors:
  `grep -n "preview?(conn) or authed?(conn) or Content.schema_public?" api/lib/barkpark_web/controllers/query_controller.ex` (line 20; `authed?` = any api_token, line 599)
- One-clause seal precedent on `base` (results+count+facets all derive from `base`):
  `sed -n 80,103p api/lib/barkpark/search/documents_retriever.ex`

## Fail-broken check (flagship)

- Live flagship surfaces ONLY `paper` (public), engine postgres:
  `curl -s 'https://guerrilla.barkpark.cloud/sites/search-capstone/api/find?q=%20&browse=1' | python3 -c "import sys,json,collections;j=json.load(sys.stdin);print(collections.Counter(h['type'] for h in j['hits']),j.get('facets',{}).get('type'),j.get('total'))"`
- Live client bundle has NO inlined WS token/url (WS leg disabled; both legs that exist are token-authed server-side):
  `curl -sL https://guerrilla.barkpark.cloud/sites/search-capstone/ | grep -oE '/sites/search-capstone/_next/static/chunks/[^\"]*\.js' | sort -u | while read js; do curl -s "https://guerrilla.barkpark.cloud$js"; done | grep -oE '.{40}NEXT_PUBLIC_BARKPARK_WS_TOKEN.{60}'` (shows the raw env lookup expression, not a value)

## Latency

- Public-type-name resolve on live prod Postgres = 0.078 ms (vs 224–675 ms search fixed cost from the `ms` field of any live search response):
  `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql barkpark_prod -c \"EXPLAIN ANALYZE SELECT name FROM schema_definitions WHERE visibility='public' AND dataset='production';\""`

## Prototype proof (repeatable)

- Add `|> scope_to_public_types(scope, opts)` after `maybe_scope_to_grants` on `base` in
  `api/lib/barkpark/search/documents_retriever.ex` (bypass when `caller_context.principal_type in [:api_token, :user]` or `admit_private_types: true`; else `d.type in ^(Content.list_schemas(scope, ws/proj) |> filter visibility=="public" |> names)`), then:
  `cd api && CC=clang MIX_ENV=test mix test test/barkpark/search/` → 19/198 failures (docs seeded without public schema rows) — baseline without the filter is 0/198.
  `mix test test/barkpark_web/controllers/search_local_test.exs test/barkpark_web/channels/search_channel_test.exs test/barkpark_web/controllers/grant_search_deny_test.exs` → 3/20 failures, ALL in search_local (loopback is anonymous); channel (token-authed) and grant tests stay green.
  Revert with `git checkout -- api/lib/barkpark/search/documents_retriever.ex`.

## Residual unsealed paths (companion fixes the builder must carry)

- Indx incremental upsert has NO visibility gate (rebuild does):
  `grep -n "schema_public" api/lib/barkpark/plugins/indx/indexer_worker.ex` (only the rebuild listing at :477; `run_upsert` at :305 never calls it) and
  `grep -n "schema_public\|visibility" api/lib/barkpark/plugins/indx/lifecycle.ex` (zero hits).
- Studio FinderLive passes no caller_context (would be narrowed by the filter):
  `sed -n 90,105p api/lib/barkpark_web/live/finder_live.ex`
- Internal anonymous-opts callers: `grep -rn "search_documents(" api/lib --include="*.ex" | grep -v "def "` → golden_eval.ex:86, synonyms.ex:297, findability_posttest.ex:186, finder_live.ex:96.
