# cch-w16-s4 criterion 6 — true cost, re-derivation recipes (wave 18 verify)

Verdict: criterion 6 needs **NO new scenario key**. The `acme-previews` preview-only
fixture is already committed on merged main (`scenarios.mjs:398-409`) and already renders
through TWO existing scenarios (`sites`, `sites-on-instance`). The residual cost is the
BLOCKER row's own criterion 3 (scheme-less `liveInstance.url`), which is unmet on main.

## Recipes

    # 0. pristine merged-main tree
    D=$(mktemp -d) && git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud | tar -x -C $D && cd $D

    # 1. the fixture is already committed, and smoke already asserts it
    grep -n "acme-previews" cloud/priv/static/__preview__/scenarios.mjs cloud/priv/static/__preview__/smoke.mjs

    # 2. all three enumerating instruments are GREEN on main (100 scenarios / 75 residue / 15 widths)
    export CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
    node cloud/priv/static/__preview__/smoke.mjs | tail -3            # "all 100 scenarios rendered", rc 0
    node --test cloud/priv/static/__preview__/breakpoint-sweep.test.mjs | grep '^# '   # 51/51, rc 0
    node cloud/priv/static/__preview__/breakpoint-sweep.mjs | tail -6 # rc 0

    # 3. PRICE THE ALTERNATIVE by mutation: insert any scenario key with no EXPECTATIONS entry
    #    -> smoke rc 1 (assertCensus, before any render)
    #    -> breakpoint-sweep.test.mjs 4 failures (17, 21, 44, 47)
    #    -> breakpoint-sweep.mjs rc 2 ("UNLISTED scenario ...")

    # 4. the driven cell (serve + iframes at width, deepLink hash MANDATORY)
    node cloud/priv/static/__preview__/serve.mjs --port 4193 &
    # ?scen=sites&theme=light#sites          -> 38083 B @320 / 38091 B @1280, rows=6, a.site-open=4,
    #                                           acme-previews row: "Not deployed", site-open 0
    # ?scen=sites-on-instance#instance/5b2c1e00-0000-4000-8000-0000000000a1
    #                                        -> 45352 B @320 / 45360 B @1280, rows=6, open=4,
    #                                           acme-previews row: NO "Not deployed" text (cch-w16-bl row)
    # ?scen=sites (NO hash)                  -> 35283 B, rows=0, open=0   <- the D199 false zero

    # 5. blocker criterion 3 is UNMET on main — measured, not read
    grep -n 'url: "production-5b2c1e' cloud/priv/static/__preview__/scenarios.mjs   # :100, no scheme
    # driven a.site-open href  = "production-5b2c1e.barkpark.cloud/sites/acme-web/"
    # resolved                 = "http://localhost:4193/production-5b2c1e.barkpark.cloud/sites/acme-web/"

    # 6. blast radius of the scheme fix: no instrument outside scenarios.mjs pins the bare host
    grep -rn "production-5b2c1e" cloud/priv/static --include="*.mjs" --include="*.js" | grep -v scenarios.mjs
