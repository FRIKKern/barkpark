# site-deploy.sh arms the public route, cannot fail, and never says so

Re-derivation recipes for the wave-19 v5 site-deploy sweep. Every command below
runs from the repo root against `origin/main` (pinned `3de49fb1074564b78225287c8d186bdc218090cd`).

NOTE: the local checkout used for this sweep was **629 commits behind** origin/main
(`git rev-parse HEAD` = `0789ab90a`). The worktree copies of both engines are
1365/1440 lines; origin/main's are 2193/1803. Always sweep origin/main bytes:

    git show origin/main:deploy/site-deploy.sh      > /tmp/om-site-deploy.sh
    git show origin/main:deploy/site-deploy-node.sh > /tmp/om-site-deploy-node.sh

## 1. Both engines parse clean, and are deliberately `-e`-less

    bash -n /tmp/om-site-deploy.sh && bash -n /tmp/om-site-deploy-node.sh
    git show origin/main:deploy/site-deploy.sh      | grep -n '^set '   # 117:set -uo pipefail
    git show origin/main:deploy/site-deploy-node.sh | grep -n '^set '   # 115:set -uo pipefail

## 2. The finding: `arm_caddy_site_route` returns 0 with the route NOT armed

    grep -n 'with_caddy_lock arm_caddy_site_route' /tmp/om-site-deploy.sh
    # 2172:with_caddy_lock arm_caddy_site_route || true

Mutation proof — extract the function verbatim, fake a `caddy validate` that
rejects, and read the return status plus the Caddyfile state:

    T=$(mktemp -d); mkdir -p "$T/bin"
    printf '#!/bin/bash\n[ "$1" = validate ] && exit 1\nexit 0\n' > "$T/bin/caddy"
    printf '#!/bin/bash\nexit 0\n' > "$T/bin/systemctl"
    chmod +x "$T/bin/caddy" "$T/bin/systemctl"
    sed -n '/^arm_caddy_site_route() {/,/^}/p' /tmp/om-site-deploy.sh > "$T/fn.sh"
    export PATH="$T/bin:$PATH"
    CADDYFILE="$T/Caddyfile"; SITE_SLUG=proofsite; ROOT="$T/site"; mkdir -p "$ROOT"
    printf 'example.com {\n\treverse_proxy localhost:4000\n}\n' > "$CADDYFILE"
    cp "$CADDYFILE" "$T/orig"
    log() { echo "[log] $*"; }
    . "$T/fn.sh"; arm_caddy_site_route; echo "RETURN STATUS = $?"
    grep -q "BARKPARK_SITE_ROUTE:proofsite" "$CADDYFILE" \
      && echo "MARKER PRESENT" || echo "MARKER ABSENT (route NOT armed)"
    cmp -s "$CADDYFILE" "$T/orig" && echo "IDENTICAL - no public route"

Observed: `RETURN STATUS = 0`, `MARKER ABSENT`, `IDENTICAL`.
The revert path ends in a bare `mv`, so the failure is not representable at the
function boundary — removing `|| true` at :2172 alone does NOT fix it.

## 3. The same file already knows the fix — on the disarm twin only (engine D77)

Identical harness, `disarm_caddy_site_route`, Caddyfile WITH the marker armed:

    sed -n '/^disarm_caddy_site_route() {/,/^}/p' /tmp/om-site-deploy.sh > "$T/fn.sh"

Observed: `RETURN STATUS = 2`, `MARKER STILL PRESENT`. Caller branches on 2 vs 1
(`teardown_failed`, exit 25). See the contract comment at
`deploy/site-deploy.sh:1765-1774` and its node twin at
`deploy/site-deploy-node.sh:1496-1501` ("it was the CALLER that discarded it
with `|| true` (D77)").

## 4. The node engine made route-arming FATAL; the static engine did not

    sed -n '1777,1782p' /tmp/om-site-deploy-node.sh   # if ! with_caddy_lock arm_caddy_node_route ... exit 16
    sed -n '2172,2183p' /tmp/om-site-deploy.sh        # || true, then emit SWITCH started

## 5. There is no ROUTE stage on the machine channel

    grep -c 'emit ROUTE' /tmp/om-site-deploy.sh          # 0
    grep -oE 'emit (PLAN|BUILD|STAGE|HEALTH|SWITCH|RETIRE)' /tmp/om-site-deploy.sh | sort -u
    git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | grep -n 'stage_exit_code('

`DeployRunner` folds BPSTAGE lines only; with no ROUTE stage the arm's outcome is
structurally invisible to the control plane, and the run ends:

    log "HEALTHY — '$SITE_SLUG' live at https://$HEALTH_HOST/sites/$SITE_SLUG/"
    exit 0

## 6. `|| true` census, production path vs self-test

Self-test regions: static `526`..`~1700`, node `599`..`1483`.

    grep -n '|| true' /tmp/om-site-deploy.sh       # 25 total: 9 pre / 10 in-selftest / 6 deploy-path
    grep -n '|| true' /tmp/om-site-deploy-node.sh  # 18 total: 11 pre / 4 in-selftest / 3 deploy-path

Of the 6 static deploy-path hits, five are cosmetic (`chown --reference` :1798/:2161,
`mkdir -p` :2033) or immediately tested (`staged_sha` :1888/:1922). One is the defect
above (:2172).  All 3 node deploy-path hits are benign (:1499 comment, :1554 `rm -f`
slot env, :1665 `mkdir -p`).

## 7. Shape (b) — unchecked `systemctl restart` — is ABSENT from both engines

    grep -n 'systemctl \(restart\|start\|reload\)' /tmp/om-site-deploy.sh /tmp/om-site-deploy-node.sh

Static has no restart/start at all — only two `systemctl reload caddy`, both inside
`if ... then ... else log ... fi`. Node's `start_slot` (:207) is `systemctl restart`,
and its status IS checked at :407 (`if ! start_slot "$slot"; then ... return 1`).
The cp-deploy.sh:194 shape does not recur here.
