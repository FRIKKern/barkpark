<!-- doc-tier: cold | canonical-for: none | budget: 900tok -->
# Wave 36 — D18 premise-smoke re-derivation recipe (2026-08-18)

Assignment: prove charter D18 authorizes the forward-through / no-pre-verify MCP
auth design that `internal/cli/mcp_serve.go` cites, and that the named code sites
still exist on origin/main.

## Finding (one line)

D18 is REAL (not a phantom D-number) and its core principle underwrites the
design, but the `mcp_serve.go` citation OVER-REACHES: D18's actual text is about
the `/v1/chat` auth model (the `RequireChatAccess` plug resolving a token to
`:global` vs `{:workspace, ws}`), NOT about MCP, `RequireBearerToken`, or token
expiry. Directionally-true citation, imprecise on the specifics.

## Re-derivation commands

    # 1. D18 is COLLAPSED on origin/main (only the summary line 41); full text
    #    lives on the wavelog branch the charter itself designates:
    git show origin/main:.claude/workflows/bp-connectors-charter.md | grep -n 'D13.\{0,4\}D20'
    #    -> line 41: "Full text preserved in the Wave 1 wave-log commits on
    #       loop-epic/connectors-w1-wavelog"; the parenthetical DOES carry the
    #       D18 gist ("new RequireChatAccess plug resolves :global vs {:workspace,ws}").

    # 2. Full D18 text (auth model — NOT MCP):
    git show loop-epic/connectors-w1-wavelog:.claude/workflows/bp-connectors-charter.md | grep -n -A1 '\*\*D18'
    #    -> "D18 — Auth model: global-admin stays a superuser fast-path; a scoped
    #        connector path is ADDED ... RequireChatAccess replaces :require_admin
    #        on the /v1/chat pipeline ..."

    # 3. The forward-through / RequireBearer / no-expiry text appears NOWHERE in
    #    the origin/main charter — grep is empty (the mechanics are code-side, not
    #    a charter ruling):
    git show origin/main:.claude/workflows/bp-connectors-charter.md | grep -niE 'forward-through|RequireBearerToken|no expiry|verify-only route'
    #    -> (empty)

    # 4. Code sites still exist on origin/main:
    git show origin/main:internal/cli/mcp_serve.go | grep -nE 'func bearerFromRequest|charter D18|charter D19'
    #    -> 246 (D18), 307 (D18), 304 (D19), 349 (func bearerFromRequest)
    git show origin/main:deploy/instance-deploy.sh | grep -nE 'arm_caddy_mcp_route|arm_caddy_connectors_route'
    #    -> 520 arm_caddy_mcp_route (path /mcp /mcp/* -> reverse_proxy localhost:${MCP_PORT})
    #    -> 584 arm_caddy_connectors_route (-> reverse_proxy localhost:${CONNECTORS_PORT})

## Secondary finding (bonus, out of primary scope)

`mcp_serve.go:304` cites "charter D19" for "loopback bind behind a reverse
proxy". D19's actual text (wavelog) is the CROSS-TENANT NEGATIVE TEST; the
host/loopback-behind-Caddy deploy shape is D34/D32 (`git show
origin/main:...charter.md | grep -n 'D34'` line 70). So the D19 citation is
also imprecise. Both citations are conceptually-adjacent, not literal.

## Recommendation for Decide

Do not quote "charter D18" as a literal MCP ruling. Annotate: D18 = the
token->scope / no-verify-only-route PRINCIPLE (authorizes the design's SHAPE);
the RequireBearerToken/expiry mechanics are a Go-SDK code rationale, not a
charter decision. Tighten the citations so Wave 37 does not re-file this.
