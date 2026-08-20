# v8 — Is converting the inline `422 {error:"no_team"}` emitters to 403 a wire break?

Wave 40 verify (cch-wave-40-2026-08-07). Re-derivation recipes only. All commands
run from the repo root; authority is `origin/main` @ `95642c550` unless stated.

## R1 — the Go gate (the "no gate in this repo can see it" claim)

    CC=/usr/bin/clang go build ./... \
      && CC=/usr/bin/clang go vet ./internal/cli/... \
      && CC=/usr/bin/clang go test ./internal/cli/... ; echo "rc=$?"

Note: `CC=clang` alone resolves to the `cc`/Claude wrapper on this host and dies
with `error: unknown option '-E'` in `runtime/cgo`. Use the absolute
`/usr/bin/clang`.

## R2 — the ONE Go consumer that branches on 422 + no_team

    grep -rn "no_team" internal/
    sed -n '592,604p' internal/cli/cloud_support_cmd.go
    sed -n '1114,1120p' internal/cli/cloud_support_cmd_test.go
    CC=/usr/bin/clang go test ./internal/cli/ -run TestCloudSupportAddCPRefusalNarrations -v

## R3 — the exit ladders the conversion moves

    sed -n '173,189p' internal/cli/cloud_rollback_cmd.go   # rollbackExit: 403->exitAuth, 422->exitGeneric
    sed -n '190,205p' internal/cli/errors.go               # statusExit:  403->exitAuth, 422->exitUsage
    sed -n '30,40p'  internal/cli/cli.go                   # exitGeneric=1 exitUsage=2 exitAuth=3

## R4 — #9956's router.ex diff is 100% comment prose

    gh pr diff 9956 > /tmp/pr9956.diff
    awk '/^diff --git/{f=$0} {if(f ~ /router.ex/ && /^[+-]/ && !/^(\+\+\+|---)/) print}' /tmp/pr9956.diff \
      | grep -vE '^[+-]\s*#' | grep -vE '^[+-]\s*$'
    # -> EMPTY. The behaviour change is entirely in cloud/lib/barkpark_cloud/web/auth.ex.

## R5 — the inline emitter census + reachability

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex > /tmp/router_main.ex
    grep -n 'error: "no_team"' /tmp/router_main.ex          # 15 emitters
    for L in 1838 2112 3900 4139 4258 4328 4349 4413 4457 5102 5209 5250 6140 8196 8385; do
      echo "== $L"; awk -v L=$L 'NR>=L-40 && NR<=L+1 {printf "%d: %s\n", NR, $0}' /tmp/router_main.ex \
        | grep -E 'require_[a-z_]*\(conn|: *(get|post|put|patch|delete) "' | tail -4
    done

FIVE are dead code behind a halting gate, not two:
  3900 / 4139 / 4258 — `Auth.require_team_admin` -> `gate_role/4` already halts
                        403 `{forbidden, reason:"no_team", scope:"team"}` (auth.ex:496).
  5209 / 5250       — `Auth.require_primary_team_owner` halts 422 (auth.ex:453).
LIVE reachable inline emitters = **10**, not 13.

## R6 — the console's third consumer

    git show origin/main:cloud/priv/static/app.js > /tmp/app_main.js
    awk 'NR>=18394 && NR<=18413 {printf "%d: %s\n", NR, $0}' /tmp/app_main.js
    git show origin/main:cloud/priv/static/__app.test.mjs | sed -n '7606,7614p'

## R7 — nothing in Go decodes a 403's authority evidence

    grep -rn 'DeployCensusError' internal/            # -> no matches (type does not exist)
    grep -rn '`json:"required"`\|`json:"scope"`' internal/   # -> manifest + pdrender only
    sed -n '252,296p' internal/cloudclient/client.go  # cloudError: error + detail, nothing else
