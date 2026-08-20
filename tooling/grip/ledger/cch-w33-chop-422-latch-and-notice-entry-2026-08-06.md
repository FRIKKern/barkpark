# cch-w33 verify — the 422/latch trap and notice-entry safety (2026-08-06)

Re-derivation recipes for the two coupled correctness calls behind wave 33 s3.
All file facts are read from `origin/main` (`0792d3347`), never from the primary
checkout — which is DIVERGED (`a31faa52d` is not an ancestor of origin/main).

## Q1 — does a 422 count toward `maxConsoleFails=3`?

Source path (read, no build needed):

    git show origin/main:internal/builder/console.go | grep -n 'maxConsoleFails\|StatusCode < 200\|c.fails++'
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '7238,7258p'   # {:error,:invalid} -> 422

Runtime proof — copy the package into a scratch module and add probes (no repo write):

    SP=$(mktemp -d); mkdir -p $SP/bt
    cp internal/builder/*.go $SP/bt/
    printf 'module btprobe\ngo 1.22\n' > $SP/bt/go.mod
    # probe A: httptest server answering 422 on every POST, feed 50 lines, count POSTs
    # probe B: alternate 422/200, feed 50 lines, count POSTs
    # probe C: 5 logf (all 422) then 5 caption, count /detail POSTs
    # probe D: consoleTee fed 256KB newline-less in 4KB chunks; decode {"line":…} lengths
    cd $SP/bt && CC=clang go test -run TestProbe_ -v ./...

Observed: A=3 POSTs then latched; B=50 (a success resets the counter);
C=0 of 5 captions (the `detail` channel shares the latch);
D=4 consecutive emitted lines of 69,632 / 69,632 / 69,632 / 53,248 chars.

## Q2 — does a synthetic `%{"line","at","kind"=>"notice"}` entry break the readers?

    git show origin/main:cloud/priv/static/app.js > /tmp/app_main.js
    # load it in the same node:vm sandbox __app.test.mjs uses, grab __bpTestHook,
    # then call deployRailLedgerFromConsole / deployConsoleHtml / deployIsPreClaim
    # with [notice, ...realEntries]:
    node <probe>.mjs /tmp/app_main.js

Serializer pass-through (the clause-seven question):

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '10366,10440p'   # deployment_json console fold
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '8664,8698p'     # scrub_entry / caption_entry

Elixir-side filters:

    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '1403,1412p'   # stages/1 filters on entry["stage"] in @stages
    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | grep -n 'defp cap_console' -A6  # Enum.drop from the HEAD

Pins that constrain the fix:

    git show origin/main:cloud/test/barkpark_cloud/registry_test.exs | sed -n '869,876p'  # "an oversized line is truncated to 2 KB, not rejected"
