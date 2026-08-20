# Re-derivation recipes — what window each deploy surface prints (wave 13 verify, 2026-08-07)

Every row below is a command that re-derives the fact from scratch. Nothing here is a
worktree claim: the `bp` binary is built from `origin/main`, the HTTP reads hit prod.

## 0 — build bp from origin/main (the July host binary is the trap)

    git worktree add --detach /tmp/wt-w13 origin/main
    cd /tmp/wt-w13 && CGO_ENABLED=0 go build -o /tmp/bp-w13 ./cmd/barkpark

    bp cloud deployments        # host binary (2026-07-31): exit 2, "unknown cloud command"
    /tmp/bp-w13 cloud deployments   # origin/main: exit 3, a 403 that NAMES ITS WINDOW

## 1 — the census verb pins and prints its window (the only surface that does)

    /tmp/bp-w13 cloud deployments --days 1 -o table
    /tmp/bp-w13 cloud deployments --from 2026-08-06 --to 2026-08-07 -o table

Both print `… census for <from> → <to> (24 hours) …` inside the refusal. The window is a
CLIENT-side fact — the 403 body carries no window:

    curl -s -H "Authorization: Bearer $CLOUD_TOKEN" \
      "https://api.barkpark.cloud/v1/operator/deploy-ledger/census?from=2026-08-06T00:00:00Z&to=2026-08-07T00:00:00Z"
    # {"error":"forbidden","scope":"platform","required":"platform_operator"}   (403; route EXISTS)

## 2 — site status prints NO window and is head-only

    /tmp/bp-w13 cloud site status search-capstone -o table

    SID=d8e9c2c7-df13-4edc-aa0f-4dafa48bd64f
    curl -s -H "Authorization: Bearer $CLOUD_TOKEN" \
      "https://api.barkpark.cloud/v1/sites/$SID/deployments?limit=200" | python3 -c "
    import sys,json;from collections import Counter
    r=json.load(sys.stdin)['deployments']
    print(len(r),dict(Counter(x['status'] for x in r)),r[-1]['inserted_at'],r[0]['inserted_at'])"

## 3 — the deferral columns have a writer and NO serializer

    cd /tmp/wt-w13
    grep -n 'deferral_depth' cloud/lib/barkpark_cloud/sites/deploy.ex          # writer, 1 hit
    grep -rn 'deferral_depth\|deferral_bound\|deferral_cause' cloud/lib/barkpark_cloud/web/  # ZERO
    sed -n '10720,10822p' cloud/lib/barkpark_cloud/web/router.ex               # deployment_json/1 key list

Live proof the key is absent from the wire (and depth lives only in prose):

    curl -s -H "Authorization: Bearer $CLOUD_TOKEN" \
      "https://api.barkpark.cloud/v1/sites/$SID/deployments?limit=60" | python3 -c "
    import sys,json;d=json.load(sys.stdin)['deployments']
    print(sorted(d[0].keys()))
    print([x['failure_reason'][:160] for x in d if x['status']=='deferred'][:1])"

## 4 — the census's own delivery node is never emitted

    cd /tmp/wt-w13
    sed -n '/def census(/,/^  end/p' cloud/lib/barkpark_cloud/deploy_ledger.ex | tail -8   # no :delivery key
    grep -rn 'DeployLedger\.delivery' cloud/lib/                                            # def only, no caller
    grep -rn 'PublishClock' --include='*.ex' cloud/lib/ | grep -v publish_clock.ex          # ZERO callers

## 5 — the SPA has no deferral vocabulary

    node --check /tmp/wt-w13/cloud/priv/static/app.js
    node /tmp/wt-w13/cloud/priv/static/__app.test.mjs 2>&1 | tail -8      # 950/950 pass
    grep -n 'deferred' /tmp/wt-w13/cloud/priv/static/app.js               # 3 hits, all unrelated
    node <scratchpad>/probe-deferred.mjs /tmp/wt-w13/cloud/priv/static/app.js
    # freshnessModel({status:"deferred"}) -> {"label":"Deferred","dot":"unknown", ...}
    # the deploy-list footer says "Showing the N most recent deployments." — a COUNT, never a window
