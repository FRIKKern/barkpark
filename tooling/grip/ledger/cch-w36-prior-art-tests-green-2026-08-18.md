# Re-derivation: prior-art MCP guards green + non-vacuous (wave 36, prior-art-tests-green)

Question: do the two committed prior-art guards (Go MCP auth suite; deploy shell
harness) actually PASS on origin/main, and are they non-vacuous? If yes, the wave-36
"pin the proof" build is redundant.

## Files verified identical to origin/main (verdict is about main, worktree was 158 behind)

    git diff --quiet origin/main -- internal/cli/mcp_http_test.go && echo SAME
    git diff --quiet origin/main -- internal/cli/mcp_serve_test.go && echo SAME
    git diff --quiet origin/main -- deploy/instance-deploy_test.sh && echo SAME

## GREEN (re-run)

    CC=clang go build ./...                                    # clean, no output
    CC=clang go test ./internal/cli/... -run 'MCP' -v          # ok 9.483s; 18/18 MCP tests PASS
    #   TestMCPHTTPDenyPathsFailClosed/{missing_bearer,bogus_bearer} PASS
    #   TestMCPHTTPForwardThroughBearer PASS
    bash deploy/instance-deploy_test.sh                        # ALL PASS — 256 PASS / 0 FAIL

## NON-VACUITY (mutate → catch → revert)

Go auth guard — PROVEN non-vacuous:
    # internal/cli/mcp_serve.go bearerFromRequest: `return ""` -> `return "ambient-token-MUTATION"`
    CC=clang go test ./internal/cli/... -run 'TestMCPHTTPDenyPathsFailClosed'
    # -> FAIL mcp_http_test.go:334: downstream carried Authorization="Bearer ambient-token-MUTATION", want ""
    #    (ambient substitution = fail-open, caught by exact assertion)

Deploy harness PORT leg — PROVEN non-vacuous:
    # deploy/instance-deploy.sh mcp block: `reverse_proxy localhost:${MCP_PORT}` -> `localhost:9999`
    bash deploy/instance-deploy_test.sh    # -> 251 PASS / 5 FAIL, all pinning :4010

Deploy harness PATH leg — NON-VACUITY GAP (finding):
    # deploy/instance-deploy.sh mcp block: `@barkpark_mcp path /mcp /mcp/*` -> `/mcp-BROKEN /mcp-BROKEN/*`
    bash deploy/instance-deploy_test.sh    # -> STILL 256 PASS / 0 FAIL (mutation slips through)
    # The harness pins the reverse_proxy PORT + arm-once idempotency but NOT the matched
    # path literal. A regression breaking the public /mcp PATH is NOT caught here.

## Verdict

AUTH fail-closed + /mcp->:4010 PORT arming: guards genuinely green AND non-vacuous ->
"pin the proof" build for those axes is REDUNDANT. BUT the public /mcp PATH literal has
NO committed guard (harness proved blind to it) — if the wave wants a committed guard
that the /mcp PATH specifically routes, that leg is NOT redundant.

All four touched files confirmed `git diff --quiet origin/main` CLEAN after revert.
