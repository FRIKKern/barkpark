# Graph-visibility ceiling — re-derivation recipes (2026-08-05)

Wave: deploy-truth-wave-1-2026-08-05, verifier lane `graph-visibility`.
Host under test: `https://guerrilla.barkpark.cloud` (NOT `api.barkpark.cloud`,
which 404s `/v1/schemas/production` — it is the control plane).
Admin token: `~/.config/barkpark/config.json` → `.token`.

    export ADMIN=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
    export H=https://guerrilla.barkpark.cloud

## R1 — schema visibility census (39 schemas, 34 private)

    curl -s -H "authorization: Bearer $ADMIN" $H/v1/schemas/production \
      | python3 -c "import json,sys;s=json.load(sys.stdin)['schemas'];print(len(s),'schemas',sum(1 for x in s if x.get('visibility')!='public'),'private')"

Public types are exactly: command, metric, paper, tag, task.

## R2 — graph corpus enumerates PRIVATE types (node-type census)

    curl -s -H "authorization: Bearer $ADMIN" "$H/v1/graph?dataset=production" \
      | python3 -c "import json,sys,collections;n=json.load(sys.stdin)['nodes'];print(len(n),'nodes',sum(1 for x in n if str(x.get('doc_id','')).startswith('drafts.')),'drafts');print(collections.Counter(x['type'] for x in n).most_common(20))"

`session` (private) and `listener` (private) appear → private-type titles served.

## R3 — enumeration is structural, not incidental (no docs needed)

    curl -s -H "authorization: Bearer $ADMIN" "$H/v1/graph?dataset=production&types=weapon"      # 200 ok:true, nodes:[]
    curl -s -H "authorization: Bearer $ADMIN" "$H/v1/graph?dataset=production&types=notarealtype" # 400 unknown types

`weapon` is private with zero docs and is still an accepted `types=` value →
`parse_graph_types/2` validated it against `Content.list_schemas/2`, which has
no visibility filter.

## R4 — CEILING, proved by mutation (create → publish → observe → delete)

    curl -s -X POST $H/v1/data/mutate/production -H "authorization: Bearer $ADMIN" -H 'content-type: application/json' \
      -d '{"mutations":[{"createOrReplace":{"_id":"probe-graphvis-weapon-2026-08-05","_type":"weapon","title":"PROBE graph-visibility ceiling weapon"}}]}'
    curl -s -X POST $H/v1/data/mutate/production -H "authorization: Bearer $ADMIN" -H 'content-type: application/json' \
      -d '{"mutations":[{"publish":{"id":"probe-graphvis-weapon-2026-08-05","type":"weapon"}}]}'
    curl -s -H "authorization: Bearer $ADMIN" "$H/v1/graph?dataset=production&types=weapon"
    # cleanup (delete REQUIRES "type"; the REST /v1/data/publish/... routes all 404 — use mutate actions)
    curl -s -X POST $H/v1/data/mutate/production -H "authorization: Bearer $ADMIN" -H 'content-type: application/json' \
      -d '{"mutations":[{"delete":{"id":"probe-graphvis-weapon-2026-08-05","type":"weapon"}}]}'

## R5 — the LIVE public-read leak is the SCOPED search route, not graph

    # mint (needs "label", and an ADMIN bearer — anonymous mint is 403)
    curl -s -X POST "$H/w/default/p/default/v1/tokens" -H "authorization: Bearer $ADMIN" -H 'content-type: application/json' \
      -d '{"label":"probe-graphvis-2026-08-05","permissions":["public-read"]}'
    export PR=<token>
    curl -s -o /dev/null -w '%{http_code}\n' -H "authorization: Bearer $PR" "$H/v1/data/search/production?q=session"                    # 403 (PublicRead)
    curl -s -H "authorization: Bearer $PR" "$H/w/default/p/default/v1/data/search/production?q=session&types=session&limit=2"            # 200, 6 private-type hits

There is NO token-revoke route (`grep -n 'v1/tokens' router.ex` → one `post`
only), so probe tokens can only be retired at the DB.

## R6 — perspective is clean on search (public-read is pinned)

    curl -s -H "authorization: Bearer $PR" "$H/w/default/p/default/v1/data/search/production?q=a&perspective=drafts&limit=1" \
      | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['count'],d['facets']['status'])"

Identical count to the un-parameterised call; status facet 100% `published`.

## R7 — the visibility gate is AUTH-keyed, not permission-keyed

    # same route, same query, only the bearer differs
    curl -s "$H/v1/data/search/production?q=a&limit=1"                              | python3 -c "import json,sys;print(json.load(sys.stdin)['facets']['type'])"
    curl -s -H "authorization: Bearer $ADMIN" "$H/v1/data/search/production?q=a&limit=1" | python3 -c "import json,sys;print(json.load(sys.stdin)['facets']['type'])"

Anonymous 5468 / public types only; any token 5478 / session+document+bulldoc.
Source: `git show origin/main:api/lib/barkpark/search/documents_retriever.ex | sed -n '325,345p'`
(`restrict_anonymous_to_public_types/3` — bypassed for any `:api_token`).

## R8 — graph_show leaks drafts at the DEFAULT perspective; ?drafts=true 500s

    curl -s -H "authorization: Bearer $ADMIN" "$H/v1/graph/gh-9531"              # 200, node doc_id "drafts.gh-9531" + full title
    for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} ' -H "authorization: Bearer $ADMIN" "$H/v1/graph/gh-9531?drafts=true"; done  # 500 x10

Find a draft-only root:

    curl -s -H "authorization: Bearer $ADMIN" "$H/v1/data/query/production/task?perspective=drafts&limit=50" \
      | python3 -c "import json,sys;print([x['_id'] for x in json.load(sys.stdin)['result']['documents'] if x['_id'].startswith('drafts.')])"

## R9 — orphans/dangling take no perspective at all

    git show origin/main:api/lib/barkpark/content/graph.ex | sed -n '855,865p'   # prefix = "drafts.%" ; where not like(d.doc_id, ^prefix)
    curl -s -H "authorization: Bearer $ADMIN" "$H/v1/graph/orphans?dataset=production" \
      | python3 -c "import json,sys,collections;o=json.load(sys.stdin)['orphans'];print(len(o));print(collections.Counter(x['type'] for x in o).most_common());print('drafts',sum(1 for x in o if str(x.get('doc_id','')).startswith('drafts.')))"

1042 rows, 0 drafts, `listener` (private) present.

## R10 — the plug suite is silent on the readmit path

    cd api && CC=clang mix test test/barkpark_web/plugs/public_read_test.exs      # 14 tests, 0 failures
    git show origin/main:api/test/barkpark_web/plugs/public_read_test.exs | grep -c 'graph\|search'   # 0

NOTE: the local checkout is 434 commits behind origin/main and BOTH
`public_read.ex` and `public_read_test.exs` differ, so a local green is a green
over the stale copy. Both revisions carry 14 tests and neither names /v1/graph.
