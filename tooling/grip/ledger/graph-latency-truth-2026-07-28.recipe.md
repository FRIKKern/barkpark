# Recipe — /v1/graph latency + credential truth (2026-07-28)

Tree: `origin/main @ ab396959c` (clean, `git rev-parse HEAD` == `origin/main`).
Host: local mac, **load averages 10.77 → 25.41** during the run — every timing below
is a LOADED-HOST reading and must be quoted with that load or not at all.
Target: `guerrilla.barkpark.cloud` (live). Load ON guerrilla was NOT measured — see caveat.

## Tokens

    ADMIN=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
    PUB=UXOvtfPOUiJF7Bw4kAz3jVW3IDyHGoLBz6Ygj7NcpnE   # label site-read-search-ember, perms {public-read}
    # provenance of PUB: tooling/grip/ledger/indx-flat-truth-2026-07-26.md:4

`PUB` is the credential the flagship inlines into the browser bundle as
`NEXT_PUBLIC_BARKPARK_WS_TOKEN` (templates/search-starter/next.config.mjs, the
three-var derive; .env.example:44).

## 1. Corpus-graph latency (the 10x disagreement)

    for i in 1 2 3 4 5 6 7 8 9 10; do
      curl -s -o /dev/null -w "run$i t=%{time_total} code=%{http_code}\n" \
        -H "Authorization: Bearer $ADMIN" \
        'https://guerrilla.barkpark.cloud/v1/graph?dataset=production'
    done

Observed: run1 `t=50.24 code=500`, run2 `t=16.23 code=200`, then warm steady
state `2.67 – 5.20s code=200`. Public-read: `3.47 / 4.46 / 4.80 / 4.30`.
Verdict: BOTH prior numbers are partly right — 2.5-3.6s is the WARM figure,
28-36s was a COLD/contended figure. Neither is a stable quotable constant.
**A first request can 500 after 50s.**

## 2. Credential parity (byte-identical)

    curl -s -o admin.json -H "Authorization: Bearer $ADMIN" '…/v1/graph?dataset=production'
    curl -s -o pub.json   -H "Authorization: Bearer $PUB"   '…/v1/graph?dataset=production'
    md5 admin.json pub.json   # → both 240718abb467a3101fcaf0ee1a80630a

Anonymous: `code=401` (`{"error":{"code":"unauthorized"…}}`) — the graph is NOT
anonymously readable, so the shipped token is load-bearing for the landing graph.

## 3. Payload / truncation truth

    python3 -c "import json,collections;d=json.load(open('pub.json'));
    print(len(d['nodes']),len(d['edges']),d['truncated'],repr(d['truncation_reason']));
    print(collections.Counter(n.get('type') for n in d['nodes']).most_common())"

→ `1796 941 True 'per_type_cap'`, types:
`task=1000, paper=585, tag=146, None=31, command=22, metric=6, session=5, listener=1`.
`task` is pinned exactly at the 1000 cap. **The flagship landing graph on
`production` is truncated in production and the page has no way to say so
unless it reads `truncated`/`truncation_reason`, which the API DOES emit here.**
31 nodes carry `type: null`.

## 4. dataset=docs (the value .env.example:23 ships)

    curl -H "Authorization: Bearer $ADMIN" '…/v1/graph?dataset=docs'
    # → {"ok":true,"nodes":[],"dataset":"docs","edges":[],"truncated":false,"truncation_reason":null}  code=200 t=0.17

    curl -H "Authorization: Bearer $ADMIN" '…/v1/w/default/p/default/graph?dataset=docs'
    # → code=404 {"error":{"code":"not_found"…}}

`docs` is EMPTY (flat route, 200 + zero nodes). The SCOPED graph route does not
exist at all: `git show origin/main:api/lib/barkpark_web/router.ex` mounts
`/graph*` only inside `scope "/v1"` with `pipe_through([:api, :require_token])`
(lines ~1828-1838). There is no `/v1/w/:ws/p/:proj/graph`.

## 5. The drafts p0 — defect CONFIRMED, content-leak REFUTED

    curl -s -o t_pub.json   -H "Authorization: Bearer $PUB" '…/v1/graph/task-c31a4f0a6c5be3ea'
    curl -s -o t_draft.json -H "Authorization: Bearer $PUB" '…/v1/graph/task-c31a4f0a6c5be3ea?perspective=drafts'
    md5 t_pub.json t_draft.json    # DIFFER: d52f3bb8… vs 56693632…

`perspective=drafts` IS honoured for a `{public-read}` token on the **traverse**
route (`graph_show`), exactly as the code comment predicts —
`graph_traverse_opts/3` ends `Keyword.put(:perspective, Params.parse_perspective(params))`
under a comment reading "this whole controller is already behind :require_token,
so honouring the param here IS the gate". 99 published nodes vs 114 draft nodes,
97 ids present only in draft space.

BUT the exploitability is REFUTED on this host. All 15 sampled draft-only ids are
independently readable **with the same public token**:

    while read id; do curl -s -o /dev/null -w "$id task=%{http_code} " -H "Authorization: Bearer $PUB" \
      "…/v1/data/doc/production/task/$id"; curl -s -o /dev/null -w "paper=%{http_code}\n" \
      -H "Authorization: Bearer $PUB" "…/v1/data/doc/production/paper/$id"; done < only.txt

→ 15/15 return 200 on one type or the other (14 task, 1 paper). What differs is
draft-space EDGE TOPOLOGY, not document confidentiality.
Note `/v1/graph?dataset=production&perspective=drafts` (the CORPUS route) is
byte-identical to published — `graph_corpus` does not read the param at all.
Also: `450fa68f2` and `9a92d85a3` ARE both ancestors of `origin/main`, and the
behaviour above is still live — so they did NOT close this.

## Caveats a reader must not lose

- Guerrilla's own load/build-id was never read; `/v1/health` 404s. I cannot
  assert guerrilla carries #6284 — only that warm latency is consistent with it.
- All timings taken from one client on a host at load 10-25. Client-side
  contention cannot be separated from server time by `curl` alone.
- The 500 on run1 was not reproduced and its body was discarded (`-o /dev/null`).
