<!-- doc-tier: cold | canonical-for: graph-draft-leak-payload-verdict | budget: 2000tok -->
# Graph draft-leak payload verdict — re-derivation recipes (2026-08-17)

Verifier assignment [graph-draft-leak-payload], API Read-Path Security Sweep wave.
All probes run against live guerrilla.barkpark.cloud. Tokens minted, used, revoked, verified dead.

## Verdicts

1. `?perspective=drafts` / `?drafts=true` / `depth>=1` emit SLUG-ONLY (`type:null, title=slug`).
   No draft titles, no content. Structural in code: `content/graph.ex:223` `traverse_drafts`
   emits `%{id: slug, doc_id: slug, type: nil, title: slug}` and never calls `hydrate_nodes`
   (the only `title: d.title` site, graph.ex:620/818, is `traverse_published`-only).
2. `?drafts=true` does NOT 500 — HTTP 200 every attempt. Prior-art `dr-bl-graph-show-draft-leak`
   claim ("full title leak + 500 10/10") REFUTED on current live.
3. Routing `graph_traverse_opts` through `AnonPerspective` = ZERO observable delta on any live
   principal. Public-read 403'd at BOTH graph callers (published AND drafts). Plain read token
   is not `anon_pinned?` so it stays unpinned under AnonPerspective anyway. Pure chokepoint move.
4. HONEST REMAINDER — the graph door's ONLY live content leak: DEFAULT perspective (no params),
   plain `read` token, GET /v1/graph/gh-9531 (a draft-ONLY id, no published revision) returns 200
   with the full draft title + real UUID. `resolve_graph_root` (tasks_controller.ex:1398) resolves
   to the `drafts.`-row and `traverse_published`→`hydrate_nodes` emits `d.title`. Perspective
   plumbing never touches this — AnonPerspective build does NOT fix it. Needs a published-existence
   check on the resolved root (matches dr-bl-graph-show-draft-leak defect 1, still open+live).

## Re-derivation commands

    A="<admin bearer from ~/.config/barkpark/config.json .token>"
    ID=api-read-path-security-sweep-wave-2026-08-17
    R=$(curl -s -X POST https://guerrilla.barkpark.cloud/w/default/p/default/v1/tokens \
      -H "Authorization: Bearer $A" -H 'Content-Type: application/json' \
      -d '{"label":"verify-graph-read","permissions":["read"]}' \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')

    # Verdict 1+2: drafts path is slug-only, no 500
    for q in '?perspective=drafts' '?drafts=true' '?perspective=drafts&depth=2'; do
      curl -s -w '\nHTTP:%{http_code}\n' -H "Authorization: Bearer $R" \
        "https://guerrilla.barkpark.cloud/v1/graph/$ID$q" | head -c 800; done
    # -> nodes[].type:null, title==doc_id (slug), HTTP:200 each

    # Verdict 3: public-read 403 at both graph callers
    PRT=$(curl -s -X POST https://guerrilla.barkpark.cloud/w/default/p/default/v1/tokens \
      -H "Authorization: Bearer $A" -H 'Content-Type: application/json' \
      -d '{"label":"pr","permissions":["public-read","read"]}' \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
    curl -s -w ' %{http_code}\n' -H "Authorization: Bearer $PRT" "https://guerrilla.barkpark.cloud/v1/graph/$ID"                     # 403
    curl -s -w ' %{http_code}\n' -H "Authorization: Bearer $PRT" "https://guerrilla.barkpark.cloud/v1/graph/$ID?perspective=drafts" # 403
    curl -s -w ' %{http_code}\n' -H "Authorization: Bearer $PRT" "https://guerrilla.barkpark.cloud/v1/graph/$ID/tasks?perspective=drafts" # 403

    # Verdict 4: DEFAULT-perspective draft-only title leak (the real door)
    curl -s -w '\nHTTP:%{http_code}\n' -H "Authorization: Bearer $R" \
      "https://guerrilla.barkpark.cloud/v1/graph/gh-9531"
    # -> 200, node type:task, doc_id:"drafts.gh-9531", full draft title, root coalesced to "gh-9531"

    # cleanup (always)
    curl -s -X DELETE https://guerrilla.barkpark.cloud/v1/auth/app-tokens \
      -H "Authorization: Bearer $A" -H 'Content-Type: application/json' -d '{"token":"'$R'"}'
    curl -s -o /dev/null -w 'dead:%{http_code}\n' -H "Authorization: Bearer $R" \
      "https://guerrilla.barkpark.cloud/v1/graph/$ID"   # dead:401
