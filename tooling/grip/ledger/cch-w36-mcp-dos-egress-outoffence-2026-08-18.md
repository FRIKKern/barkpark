<!-- doc-tier: cold | canonical-for: cch-w36-mcp-dos-egress-recipe | budget: 800tok -->
# W36 — mcp-session-egress DoS finding: CONFIRMED on origin/main, OUT OF FENCE

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Verifier [dos-surface-confirm], wave 36. Re-derivation recipe for the one genuinely
new security finding. This is a task to FILE (published child hardening task), NOT a
slice to build — both offending files are outside the cloud/+connectors/+scripts/connectors fence.

## Claim
`internal/cli/mcp_serve.go`'s `http.Server` has NO Read/ReadHeader/Write/Idle timeout,
no MaxHeaderBytes, and no rate-limit middleware; the armed Caddy `/mcp` route has no
`rate_limit` directive. So the unauthenticated `initialize`/`tools/list` path is an
unbounded request-flood + slow-read surface, and every request triggers a full
per-request server rebuild (`getServer` -> `buildMCPServer`).

## Re-derive
```
cd /Volumes/SATECHI/github/barkpark
# 1. The bare http.Server — only Handler set (mcp_serve.go:265):
git show origin/main:internal/cli/mcp_serve.go | sed -n '265p'
#   => httpSrv := &http.Server{Handler: handler}
# 2. No timeout / rate-limit fields anywhere in the file (expect NO output):
git show origin/main:internal/cli/mcp_serve.go | grep -nE 'ReadTimeout|ReadHeaderTimeout|WriteTimeout|IdleTimeout|MaxHeaderBytes|RateLimit|Throttle|limiter'
# 3. Per-request rebuild — getServer calls buildMCPServer per request (mcp_serve.go ~330):
git show origin/main:internal/cli/mcp_serve.go | sed -n '326,340p'
# 4. Armed Caddy /mcp block is a bare reverse_proxy, no rate_limit (instance-deploy.sh 530-561):
git show origin/main:deploy/instance-deploy.sh | sed -n '533,540p'
git show origin/main:deploy/instance-deploy.sh | grep -nE 'rate_limit|ratelimit|Throttle'   # NO output
```

## Fence check (both OUTSIDE cloud/ + connectors/ + scripts/connectors/)
```
for f in internal/cli/mcp_serve.go deploy/instance-deploy.sh; do
  case "$f" in cloud/*|connectors/*|scripts/connectors/*) echo "$f INSIDE";; *) echo "$f OUTSIDE";; esac
done
#   internal/cli/mcp_serve.go -> OUTSIDE
#   deploy/instance-deploy.sh -> OUTSIDE
```

## Verdict
CONFIRMED at L1 on origin/main. OUT OF FENCE both files. Decide: FILE as a published
child hardening task (add http.Server timeouts + MaxHeaderBytes in mcp_serve.go; add a
Caddy `rate_limit` on the `/mcp` route in instance-deploy.sh), NOT a wave-36 slice.
Note the mitigating context authored in-file: server holds NO ambient credential
(forward-through bearer, charter D18), Stateless (no session bleed) — so this is a
resource-exhaustion / availability finding, not a confidentiality one.
