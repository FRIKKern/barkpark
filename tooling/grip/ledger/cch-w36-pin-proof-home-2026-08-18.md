<!-- doc-tier: cold | canonical-for: connectors-wave36-pin-proof-home-rederive | budget: 900tok -->

# Connectors Wave 36 — pin-proof-home re-derivation recipe (2026-08-18)

Verifier row for the [pin-proof-home] judgment call. Re-derives the live MCP
reachability matrix and the two ownership facts that decide whether "pin the MCP
reachability proof" has any in-fence buildable home.

## Live reachability matrix (L1, public host, through Caddy)

    curl -s -o /dev/null -w '%{http_code}\n' https://guerrilla.barkpark.cloud/connectors/health   # 200
    curl -s -o /dev/null -w '%{http_code}\n' https://guerrilla.barkpark.cloud/connectors/mcp      # 404 (by design — no such route)
    curl -s -o /dev/null -w '%{http_code}\n' https://guerrilla.barkpark.cloud/mcp                  # 405 (GET; needs POST)
    curl -s -X POST https://guerrilla.barkpark.cloud/mcp \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' \
      -D - --max-time 15
    # → HTTP/2 200 · via: 1.1 Caddy · serverInfo.name "barkpark-tasks"

The public MCP endpoint IS reachable. The wish's "/connectors/mcp 404 — arm the
Caddy MCP path" premise is a PHANTOM: `/mcp` is a dedicated route → :4010
(barkpark-mcp.service, `bp mcp serve --http` = internal/cli), entirely separate
from `/connectors` → :4020 (Node bridge). `/connectors/mcp` was never meant to
exist.

## Ownership facts (why no in-fence build exists)

    # Auth fail-closed proof ALREADY committed, OUTSIDE fence:
    git show origin/main:internal/cli/mcp_http_test.go | grep -n 'func Test'
    #   TestMCPHTTPForwardThroughBearer / TestMCPHTTPDenyPathsFailClosed
    # Gated by go-tests.yml (paths: "**/*.go") — NOT connectors.yml.

    # connectors.yml gates the :4020 bridge, hardcodes proof scripts BY NAME
    # (never glob-discovers scripts/connectors/), runs only HERMETIC self-tests
    # against fake binaries + real Postgres. No live host, no bearer in CI.
    git show origin/main:.github/workflows/connectors.yml | grep -nE 'paths:|hardcodes|scripts/connectors'

    # Caddy arming non-vacuity ALREADY committed, OUTSIDE fence:
    git show origin/main:deploy/instance-deploy_test.sh   # arm_caddy_mcp_route / arm_caddy_connectors_route

## Verdict

DISPOSITION: charter D272 annotation ONLY (extend to name-retire the
`/connectors/mcp` phantom + correct "/mcp 405 is Phoenix :4000" → :4010
barkpark-mcp) + park a live-reachability check as a POST-DEPLOY SMOKE (out of
fence). NO scripts/connectors/ artifact — it would land the proof in the wrong
service's gate (:4020, not :4010), could not run in CI (no live host, no
bearer), and duplicates the already-green mcp_http_test.go auth gate. Zero
in-fence build content for this slice.
