# console-harness-pins — re-derivation recipes (wave 57 verify, 2026-08-09)

Baseline: origin/main @ 0239dd4ee662dd30c4d8da0c6b9a149638224b1d.

## WARNING: the primary checkout's static tree is STALE

`cloud/priv/static/{app.js,__app.test.mjs,app.css,index.html,__preview__/*}` are
DIRTY and BEHIND origin/main in the primary checkout. Running the harnesses in
`/Volumes/SATECHI/github/barkpark` measures the wrong tree (721 tests, not 1018).
Every recipe below runs against an EXPORT of origin/main.

    S=$(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C $S && cd $S

Exporting only `cloud/` is NOT enough: 6 cases reach into `internal/`, `cmd/`
and the coherence goldens and fail spuriously. Export the WHOLE tree.

## Recipes

    # both blocking harnesses on origin/main
    cd $S && node --check cloud/priv/static/app.js
    cd $S && node cloud/priv/static/__app.test.mjs 2>&1 | tail -8      # 1018 pass / 0 fail
    cd $S && node cloud/priv/static/__preview__/smoke.mjs 2>&1 | tail -2 # all 110 scenarios

    # the six cases that need the non-cloud tree present
    cd $S && node cloud/priv/static/__app.test.mjs 2>&1 | grep -E '^not ok'

    # confirmDecommission's consequence bullets are pinned NOWHERE
    cd $S && grep -rn "Permanently tears down\|Removes the instance from your dashboard" cloud/priv/static/

    # the loose dunning pins
    cd $S && grep -n 'Your card was declined on \.\+\|Your payment failed on \.\+\|Suspended \.\+ — payment failed' cloud/priv/static/__app.test.mjs

    # the canceled state /v1/subscription can never mint
    cd $S && sed -n '1231,1237p' cloud/lib/barkpark_cloud/billing.ex   # status in ["active","past_due"]
    cd $S && grep -n 'status: "canceled"' cloud/priv/static/__preview__/scenarios.mjs   # no fixture

    # the un-cancel arm
    cd $S && sed -n '612,632p' cloud/lib/barkpark_cloud/billing.ex

Note: the router path is `cloud/lib/barkpark_cloud/web/router.ex`.
`cloud/lib/barkpark_cloud_web/router.ex` does not exist on origin/main.
`post "/v1/billing/cancel"` is line 5728; 5722 is its comment.
