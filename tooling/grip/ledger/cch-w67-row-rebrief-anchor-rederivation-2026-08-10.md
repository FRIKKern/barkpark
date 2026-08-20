# cch wave 67 — row-rebrief: re-derivation recipes for every drifted anchor

Every command below is run from the repo root and reads `origin/main`, never the checkout.

## The route (all anchors LIVE as of origin/main this run)

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'delete "/v1/sites/:id"\|box_present\|node_ports_exhausted\|teardown_failed\|Registry.delete_site\|has no console surface'

Expected: 6900 `{:error, :ports_exhausted}` · 6902 `error: "node_ports_exhausted"` · 7056 `delete "/v1/sites/:id"` ·
7063 `{:ok, _} = Registry.delete_site(site)` · 7072 `box_present: not is_nil(bp)` · 7081-7083 the named-deferral comment ·
7088 `error: "teardown_failed"`.

## The two non-existent paths cited by briefs

    git show origin/main:cloud/lib/barkpark_cloud/router.ex        # fatal: path ... does not exist
    git show origin/main:cloud/lib/barkpark_cloud_web/router.ex    # fatal: path ... does not exist

Real path: `cloud/lib/barkpark_cloud/web/router.ex`.

## `node_ports_exhausted` is on the CREATE path, not the delete path

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | awk 'NR>=6700 && NR<=6910' | grep -n 'post "\|delete "'

Prints `87:  post "/v1/sites" do` → absolute line 6786; 6902 is inside it.

## router.ex:7031 is NOT the deferral comment

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '7025,7036p'

Prints the site-settings PATCH `nothing_to_update` 422 — an actively misleading landing, not an empty one.

## app.js anchors drifted +63…+67 (23,339 → 23,410 lines)

    git show origin/main:cloud/priv/static/app.js > /tmp/app_main.js
    wc -l /tmp/app_main.js                                   # 23410
    grep -n 'api("DELETE".*sites' /tmp/app_main.js           # 13845 (was cited 13778)
    grep -n 'has never read data.detail' /tmp/app_main.js    # 12232 (was cited 12169)
    grep -n 'typeof data.detail === "string"' /tmp/app_main.js  # 13101 (was cited 13034)
    grep -n 'function friendly' /tmp/app_main.js             # 346  (STILL CORRECT)
    grep -n 'function faultCopy\|function faultDetail\|function fleetLoadErrorHtml' /tmp/app_main.js  # 421/471/489
    grep -n 'fail: function' /tmp/app_main.js                # 929  ctl.fail(message, recoveryLabel, onRecover)
    sed -n '8640,8652p' /tmp/app_main.js                     # promote honest copy (cited as 9956-9962, which is wh-events)

## The CLI receipt that the crown's producer change falsifies

    git show origin/main:internal/cli/cloud_site_cmd.go | sed -n "$(git show origin/main:internal/cli/cloud_site_cmd.go | grep -n 'func renderSiteDeleted' | cut -d: -f1),+14p"
    git grep -n -A5 'SiteDeleteResult struct' origin/main -- internal/cloudclient/client.go   # 1731-1736: ok/status/slug only

## The 500 arm no reader covers

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '8707,8723p;8737p'

`%{error: crash_slug(reason, status), request_id: request_id}` → `server_error`. No `ok`, no `detail`.

## The false-done is an honest dedupe (do not reopen)

    bp task get cch-w63-bl-the-site-teardown-refusal-has-no-console-reader -o json | python3 -c "import json,sys;c=json.load(sys.stdin)['doc']['content'];print(c['close_reason']);print(json.dumps(c['close_override'])[:800])"

Prints `DUPLICATE — closing so one defect keeps one row.` plus a `close_override.criteria` block naming both
unmet criteria by index and the surviving row. Filed 17:39:25Z, closed 17:40:52Z — 87 seconds.
