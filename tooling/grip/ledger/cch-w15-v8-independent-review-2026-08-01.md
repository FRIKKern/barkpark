# cch-w15 v8 — independent re-derivation of the #8659 freshness ruling (re-run recipe)

Discharges `cch-w14-bl-independent-review-owed` on MERGED code (origin/main `32662d0c4`).
Everything below is driven; nothing is asserted from a code read.

## 0. Isolated tree (the main checkout is 238 behind / 48 ahead and dirty — never compile into it)

    S=/tmp/v8; git worktree add --detach $S/v8tree origin/main
    ln -s "$(git rev-parse --show-toplevel)/cloud/deps" $S/v8tree/cloud/deps
    cd $S/v8tree/cloud && CC=/usr/bin/clang MIX_ENV=test MIX_BUILD_PATH=$S/build_test mix compile

## 1. The builder's own suite, on merged bytes

    cd $S/v8tree/cloud && CC=/usr/bin/clang MIX_BUILD_PATH=$S/build_test \
      mix test test/barkpark_cloud/web/router_sites_freshness_environment_test.exs
    # → 4 tests, 0 failures

## 2. INDEPENDENT drive — a LIVE, un-torn-down preview (the builder only drove a torn-down one)

Scripts live outside the repo (scratchpad `v8/v8_independent_review_test.exs`,
`v8/v8_census_test.exs`); `mix test <abs-path>` runs them against the merged tree.

    V8-A  preview_host=s-72--feat-live-3394e2.barkpark.cloud status=live env=preview
    V8-A  GET /v1/sites last_deployment = nil
    V8-B  preview-only vs never-deployed row diff = []      (identity keys dropped)
    V8-C  ladder status=200 deployments=[]

## 3. DOM drive of the pill (textContent, not app.js)

    cd $S/v8tree/cloud/priv/static/__preview__ && node serve.mjs --port 4353
    # http://localhost:4353/?scen=sites#sites  → acme-labs row
    # .site-status .status-pill textContent === "Not deployed"
    # class === "status-pill status-pill--neutral"

## 4. PRICE of the alternative (criterion 2), by mutation

Add `environment` as a 5th key to `latest_deployment_status_map/1` AND drop
`where: d.environment == "production"`:

    mix test test/barkpark_cloud/registry_deployment_freshness_test.exs \
             test/barkpark_cloud/web/router_sites_freshness_environment_test.exs \
             test/barkpark_cloud/web/router_sites_test.exs
    # → 104 tests, 5 failures
    #   keyset:  left [:environment,:inserted_at,:status,:trigger,:updated_at]
    #            right [:inserted_at,:status,:trigger,:updated_at]  ×2
    #   badge:   left "cancelled" right "live"                      ×2
    # restore, re-run → 9 tests, 0 failures

## 5. POPULATION census (criterion 3)

    SELECT
      (SELECT count(*) FROM sites) AS sites_total,
      (SELECT count(*) FROM sites s
         WHERE EXISTS (SELECT 1 FROM deployments d WHERE d.site_id=s.id AND d.environment='preview')
           AND NOT EXISTS (SELECT 1 FROM deployments d WHERE d.site_id=s.id AND d.environment='production')) AS preview_only,
      (SELECT count(*) FROM sites s WHERE NOT EXISTS (SELECT 1 FROM deployments d WHERE d.site_id=s.id)) AS never_deployed;

Non-vacuity proven (`v8/v8_census_test.exs`): `sites_total=3 preview_only=1 never_deployed=1`.
No production DB is reachable from this environment — the prod number is NOT quoted.

Design-corpus census:

    cd $S/v8tree/cloud/priv/static/__preview__ && node -e '<walk SCENARIOS.*.data.sites>'
    # → 44 site rows, 40 with last_deployment == null, 0 modelling a preview-only site

## 6. Unfiled defect surfaced by the drive

`siteOpenLink(siteLiveUrl(s, bp))` — app.js:7534 and :9497 — is gated ONLY on a URL
string existing, never on deployment state. The acme-labs row paints
`Not deployed` and `Visit ↗ / title="Open the live site"` in the SAME row.
