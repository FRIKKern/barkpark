<!-- doc-tier: cold | canonical-for: none | budget: 1500tok -->
# V3 — redaction-correctness + UI preflight (cloud billing raw-body leak)

Verdict: **APPROVE**. Generalizing the client-facing `reason` at the router boundary
(keep the error CODE) is ZERO-regression across every client that consumes billing errors,
and router-boundary redaction is LOAD-BEARING (a JS-only fix would still leak via the Go CLI).

## Re-derive on origin/main

    # 1. JS console never renders data.reason for billing (only CODE/details/detail)
    git show origin/main:cloud/priv/static/app.js | sed -n '399,490p'   # friendly(): reads data.error(code), data.details, data.detail — NEVER data.reason
    git show origin/main:cloud/priv/static/app.js | sed -n '368,378p'   # only forbiddenEvidenceCopy reads data.reason, gated on error==="forbidden" (not billing codes)
    git grep -nE 'billing/(checkout|portal|cancel)' origin/main -- cloud/priv/static/app.js
    #   all 3 callers render friendly(r.data, <fallback>): 15801 checkout, 16299 portal, 16183 cancel
    #   checkout_failed(260)/portal_failed(261) have curated ERRORS entries; cancel_failed has NONE → caller fallback

    # 2. Go CLI: cloudError decodes reason and Error() appends it, but branches on reason VALUE
    #    only for no_team / platform_deliveries_missing / UNIDENTIFIABLE (deliveries/rollback/site) — NOT billing
    git show origin/main:internal/cloudclient/client.go | sed -n '393,505p'
    git grep -nE '\.Reason ==' origin/main -- internal/cli   # none are billing
    git show origin/main:internal/cli/cloud12_cmd.go | sed -n '1009,1017p'  # checkout: string-matches CODE plan_invalid only, else surfaces verbatim

    # 3. web/ has NO billing UI (single "stripe" hit = a tailwind visual stripe comment)
    git ls-tree -r origin/main --name-only web/app | grep -iE 'billing|checkout|stripe'   # empty

    # 4. census test keys on CODE cancel_failed, regex-scanned from router source (not the response reason)
    git show origin/main:cloud/test/barkpark_cloud/console_reader_census_test.exs | sed -n '980,990p'
    git show origin/main:cloud/test/barkpark_cloud/console_reader_census_test.exs | sed -n '106,116p'  # emitted_codes()

## Load-bearing conclusions

- **Two client surfaces, not one.** JS console structurally never reads `reason`; the Go CLI
  (`bp subscribe` → CreateCheckout) DOES surface `reason` verbatim in `err.Error()`. Redacting
  at the ROUTER covers both. A gateway-only or JS-only fix would leave the Go CLI leaking.
- **No consumer string-matches the billing `reason` VALUE.** JS keys on CODE; Go string-matches
  only `plan_invalid` (a CODE) for checkout. Generalizing the free-text `reason` loses nothing.
- **Over-redaction risk = none.** Preserve the error CODE (checkout_failed/portal_failed/
  cancel_failed) and only generalize the `reason` free-text.
