<!-- doc-tier: cold | canonical-for: cch-w37-route-citation-smoke | budget: 900tok -->
# W37 route-and-citation smoke — re-derivation recipes (2026-08-18)

Verifier: route-and-citation-smoke lane, wave 37. Every row re-derivable by the command shown.

## Live routes (guerrilla, through Caddy) — ALL CONFIRMED

    for p in mcp connectors/mcp; do echo -n "GET /$p: "; curl -s -o /dev/null -w '%{http_code}\n' https://guerrilla.barkpark.cloud/$p; done
    # GET /mcp: 405 ; GET /connectors/mcp: 404
    curl -s -X POST https://guerrilla.barkpark.cloud/mcp -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}' \
      -w ' HTTP:%{http_code}\n' | tail -c 200
    # -> serverInfo.name:"barkpark-tasks" ... HTTP:200

## required checks = FOUR; go-tests NOT among them (matches file AND live protection API)

    git show origin/main:.github/required-checks.json | python3 -c "import sys,json;print([c['context'] for c in json.load(sys.stdin)['protection']['required_status_checks']['checks']])"
    # ['Cloud gate','Console gate','Elixir gate','PR references an active task']
    gh api repos/:owner/:repo/branches/main/protection/required_status_checks -q '.checks[].context'
    # Elixir gate / PR references an active task / Cloud gate / Console gate

## MATERIAL PREMISE TURN — #12136 is MERGED, not stranded-OPEN

    gh pr view 12136 --json state,mergedAt,mergeCommit,headRefName
    # state:MERGED  mergedAt:2026-08-18T02:39:46Z  mergeCommit:8dadc9b516  head:epic-charter/connectors-w36-20260818T015032Z
Doc-budgets red is ADVISORY (not in the 4 required contexts) so it never blocked the merge.
The charter phantom-retirement (D272 W36 correction + D280/D281 + W36-1 charter text) is ALREADY on origin/main:

    git show origin/main:.claude/workflows/bp-connectors-charter.md | grep -c 'PHANTOM'   # 2
D272 on main now carries the inline correction ("NOT Phoenix :4000 — it is the barkpark-mcp shim on loopback :4010"),
so the plan premise "correction only in #12136 / D272 still stale" is itself STALE. Wave-37 task (1)
"diagnose the doc-budgets red so the lead can merge #12136" is MOOT — nothing to diagnose, it merged.

## SECONDARY — #12155 (W36-1 code slice) is still OPEN; charter over-claims "Landed"

    gh pr view 12155 --json state,mergeable,mergeStateStatus,headRefName
    # state:OPEN mergeable:MERGEABLE mergeStateStatus:CLEAN head:loop-epic/retire-the-connectors-mcp-phantom-in-cod-0-r
    git show origin/main:connectors/test/webhook-server.test.ts | grep -c 'connectors/mcp'   # 0 (two-segment test NOT on main)
The charter text merged via #12136 says W36-1 "Landed," but the actual boundary-test code is NOT on origin/main.
The lead still needs to merge #12155.
