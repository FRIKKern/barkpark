# s6 CLI seam — blast radius re-derivation recipe (2026-08-06)

Verifier `s6-cli-seam-blast-radius`, deploy-reliability wave 2. Every row below
re-derives from `origin/main` (0792d3347 at time of writing). The local checkout
is DIVERGED from origin/main by +866 lines across the three s6 files — read
`git show origin/main:<path>`, never the worktree.

## 0. Stand up an origin/main tree to run gates in (the checkout stays on main)

    SP=$(mktemp -d) && git archive origin/main | tar -x -C "$SP" && cd "$SP"

## 1. The gates, at origin/main authority

    CC=clang go build ./...
    CC=clang go vet ./internal/cli/... ./internal/cloudclient/...
    CC=clang go test ./internal/cli/... ./internal/cloudclient/...

## 2. (a) No list method returns the WIDE type; and the wide type is not wide enough

    git show origin/main:internal/cloudclient/client.go | grep -n 'type Deployment struct\|type SiteDeployment struct\|func (c \*Client) ListDeployments\|SiteDeployment, error)'
    git show origin/main:internal/cloudclient/client.go | sed -n '1154,1172p'   # no limit, no before, no next_cursor
    git grep -n 'failure_class\|failure_reason_raw\|LastDeployment' origin/main -- internal/    # ZERO

## 3. (b) What the server sends vs what Go decodes

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | awk '/defp deployment_json\(/,/^  end/'
    git show origin/main:internal/cloudclient/client.go | sed -n '1384,1403p'

## 4. (c) spawnSiteStatusMap blast radius — MUTATION, not reading

    grep -rn 'spawnSiteStatusMap' internal/ cmd/          # 1 prod caller (cloud_site_cmd.go:1101), 0 test constructions
    # then, in the scratch tree, insert one extra list read into runCloudSiteStatus:
    #   _, _ = cfg.CloudClient().ListDeployments(cloudCtx(), id)
    CC=clang go test ./internal/cli/ -run 'TestRunCloudSiteStatus'
    # => 5 FAILs, all "unexpected request GET /v1/sites/<id>/deployments"
    # The single cause: siteCP.serve()'s switch matches only
    # HasPrefix(path, ".../deployments/") — trailing slash — so a BARE list GET
    # falls to `default: t.Fatalf`. One new case fixes all five.

## 5. (d) The impossible fixture

    git show origin/main:internal/cli/cloud_site_cmd_test.go | sed -n '1145,1163p'
    git show origin/main:cloud/lib/barkpark_cloud/registry/deployment.ex | sed -n '88,96p'   # "live" => [] (terminal)
    grep -rn 'current_deployment_id:' cloud/lib/                                             # 3 writers, all live-gated
    grep -rn 'set_site_current_deployment' cloud/lib/ | grep -v 'def set_site'               # 1 prod caller

## 6. Charter anchor drift found

`bp-deploy-reliability-charter.md:38` cites `parse_limit(…, 100, 200)` at
router.ex:6318. On origin/main it is line **6371**.

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'parse_limit(conn.query_params\["limit"\], 100, 200)'
