# PAT reachability of the deploy-ledger read surface — live curl, 2026-08-08

Re-derivation recipe. Every number below was taken against `https://barkpark.cloud` on
2026-08-08 with a **real** `bpc_pat_`-prefixed read PAT, not a session token.

## 0. The trap that voids the whole measurement

`~/.config/barkpark/config.json`'s `cloud_token` is a **session** token, NOT a PAT
(PATs carry a `bpc_pat_` prefix; the stored value has none). Curling with it returns
**200** from the list route and reproduces nothing. Mint a real read PAT first:

    S=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")
    curl -s -X POST -H "Authorization: Bearer $S" -H 'Content-Type: application/json' \
      -d '{"name":"probe","abilities":["read"]}' https://barkpark.cloud/v1/tokens \
      | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])"
    # revoke afterwards: DELETE /v1/tokens/<pat.id> with the SESSION token

Note: `expires_in_days` in the mint body was ignored — the returned PAT expired at
+30d, not the +1d requested. Revoke explicitly; do not rely on the expiry you asked for.

## 1. The four-route probe

    BP_PAT=<bpc_pat_…>
    SITE=b376168d-3ac5-443f-8c2c-4010c9b19fb4      # jarl-website
    DEP=4b8b886b-08c4-445f-bd17-5e95d820dd79
    W='from=2026-08-01T00:00:00Z&to=2026-08-08T23:59:59Z'
    for u in "/v1/sites/$SITE/deployments" \
             "/v1/sites/$SITE/deployments/$DEP" \
             "/v1/deploy-ledger/census?$W" \
             "/v1/operator/deploy-ledger/census?$W"; do
      printf '%s -> ' "$u"
      curl -s -o /tmp/r.json -w '%{http_code}\n' -H "Authorization: Bearer $BP_PAT" "https://barkpark.cloud$u"
    done

Observed 2026-08-08T10:2x:

    list      -> 401 {"error":"unauthorized"}
    detail    -> 200
    census    -> 200   (and 422 invalid_window with no from=)
    operator  -> 401 {"error":"unauthorized"}

The operator twin **401s** a PAT (it never authenticates one:
`require_platform_operator` → `require_user`, session-only). It 403s
`{"error":"forbidden","scope":"platform","required":"platform_operator"}` only to a
*session* user outside `platform_admin_emails()`.

## 2. What the PAT-reachable detail body actually carries

    curl -s -H "Authorization: Bearer $BP_PAT" \
      "https://barkpark.cloud/v1/sites/$SITE/deployments/$DEP" \
    | python3 -c "import json,sys;d=json.load(sys.stdin)['deployment'];print(len(d));print(sorted(d))"

31 keys (the charter's D138 "25 keys" is stale — `deferral_{cause,depth,bound}`,
`refusal_phase` and friends landed 2026-08-07):

    artifact_sha256 artifact_url became_live_at branch build_id build_log_url console
    content_rev deferral_bound deferral_cause deferral_depth detail environment
    failure_class failure_reason failure_reason_raw git_ref id image_tag inserted_at
    preview_host preview_url refusal_phase site_id source stage stages status trigger
    updated_at url

**No field is keyable to a GitHub Actions run id.**
`git grep -n "run_id\|workflow_run\|GITHUB_RUN_ID" origin/main -- cloud/lib deploy` = zero hits.
`delivery_id` is a column but is NOT rendered, and it is the `x-github-delivery`
webhook GUID (`router.ex:12792`), not a run id. `build_id` is
`hash(code_rev+content_rev+config)` (`deployment.ex:105-110`). And `git_ref` is
**null on `content-auto` rows** — the dominant guerrilla trigger — so even the sha
half of a `(sha, run_id, first_seen_at)` key is absent there.

## 3. `delivery` and `publish_clock` are both on PAT-unreachable routes

    grep -n "defp deploy_census_json" -A 4 <(git show origin/main:cloud/lib/barkpark_cloud/web/router.ex)

`deploy_census_json/2` (`Map.put(:delivery, DeployLedger.delivery(from, to))`) is
called ONLY by `/v1/operator/deploy-ledger/census`. The team census
(`router.ex` `get "/v1/deploy-ledger/census"`) calls `DeployLedger.census/3` directly
and adds only `:scope`. Confirmed live: the PAT census body's top-level keys are

    boundaries cancelled classes coalesced_attempts completeness deferred failed
    failure_rate in_flight live live_rate min_sample not_attempted residual scope
    sites total_sites truncated volume window

— **no `delivery`**.

`publish_clock` (and `next_cursor`) are top-level siblings of `deployments` on the
**list** route, i.e. behind the 401. Reproduce with the session token:

    curl -s -H "Authorization: Bearer $S" \
      "https://barkpark.cloud/v1/sites/7c2025a5-4181-46df-8b00-6151fe3da9d4/deployments?limit=5" \
      | python3 -c "import json,sys;print(sorted(json.load(sys.stdin)))"
    # ['deployments', 'next_cursor', 'publish_clock']
