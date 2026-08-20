# cch-w48 — third-party-handoff doctrine: re-derivation recipes (2026-08-07)

Verifier `third-party-handoff-doctrine`, wave 48. Every recipe runs against a full-tree
archive of `origin/main` (`fc27f0d7499046c2a5d511f2334f3fe1bc5878f7` at time of writing),
never the primary checkout.

    D=$(mktemp -d); git archive origin/main | tar -x -C $D; cd $D/cloud

## R1 — the Vercel client seam declares exactly two callbacks, both writes

    grep -n '@callback' lib/barkpark_cloud/vercel/client.ex

Expect exactly two: `deploy_project/3`, `create_transfer_code/1`. No read of any kind.

## R2 — Vercel.Real issues zero GETs

    grep -n 'build_request(' lib/barkpark_cloud/vercel/real.ex

Expect four builder call sites, all `:post`. `grep -c ':get' lib/barkpark_cloud/vercel/real.ex` → 0.

## R3 — Vercel.state/1 has no `claimed` key

    sed -n '103,112p' lib/barkpark_cloud/vercel.ex

Expect the four keys `configured / deployed / deployment_url / claim_url` and nothing else.
`deployed:` is `present?(bp.vercel_project_id)` — a LOCAL column that is never cleared, so it
stays `true` after Vercel has reassigned the project to the user's team.

## R4 — `returnUrl` is constructed and never handled

    grep -n 'returnUrl\|return_url' priv/static/app.js

Expect exactly two hits, both inside `vercelClaimLinkHtml` (a comment at :18073 and the
construction at :18076). No parser, no boot handler — contrast `checkoutFlag()` (:15982) and
`billingPortalFlag()` (:16023), which both parse their return trip.

## R5 — the transfer-request body is empty, so the callback is dropped

    sed -n '120,129p' lib/barkpark_cloud/vercel/real.ex

Expect `Jason.encode!(%{})`. Vercel's documented request body for
`POST /projects/{idOrName}/transfer-request` accepts `callbackUrl` ("The URL to send a webhook
to when the transfer is accepted") and `callbackSecret` ("The secret to use to sign the webhook
payload with HMAC-SHA256"). Re-derive the doc side with:

    WebFetch https://vercel.com/docs/rest-api/reference/endpoints/projects/create-project-transfer-request

## R6 — the suite structurally cannot express "already claimed"

    grep -n 'def create_transfer_code' -A 8 lib/barkpark_cloud/vercel/fake.ex
    CC=clang mix test test/barkpark_cloud/vercel_test.exs

The Fake succeeds for EVERY project id except the one `invalid_project_id/0` sentinel, so the
green at "re-deploy is idempotent on the project" (vercel_test.exs:166) is a green over a double
that cannot model transfer-out. 19 tests, 0 failures.

## R7 — the 502 arm renders an invented remedy

    grep -c 'vercel_error' priv/static/app.js          # → 0 (never in ERRORS)
    grep -c 'faultCopy(' priv/static/app.js            # → 19 other call sites
    sed -n '18170,18172p' priv/static/app.js           # → bare friendly(r.data, "Please try again.")

`friendly()` falls through to the caller fallback, so a permanently-403 Vercel refusal renders
"Couldn't deploy to Vercel — Please try again." and the router's `detail` is discarded.

## R8 — the seven handoffs and their completion signals

    grep -n 'vercel\.com\|github\.com\|install_url\|claim_url\|_blank' priv/static/app.js
    grep -n 'function handleCheckoutReturn\|function handleBillingPortalReturn' priv/static/app.js
    grep -n 'domain-status' priv/static/app.js lib/barkpark_cloud/web/router.ex
    grep -n 'github/installations' priv/static/app.js  # → 0 SPA callers
    grep -n 'post "/v1/webhooks/github' lib/barkpark_cloud/web/router.ex  # → per-site push hook only

| # | handoff | signal class | verdict |
|---|---|---|---|
| 1 | Stripe Checkout | (b)+(c) `?checkout=` + webhook, corroborated by `status==="active"` | PASS |
| 2 | Stripe Customer Portal | (b)+(c), ack deliberately NEUTRAL | PASS |
| 3 | OAuth SSO | (b) `/#oauth_code=` exchanged against our own server | PASS |
| 4 | Custom domain attach | (c) `GET /v1/:id/domain-status` verifier | PASS |
| 5 | `vercelCloneUrl` | (a) `#new-site-url` hand-back | PASS |
| 6 | GitHub `install_url` | none | FAIL |
| 7 | Vercel `claim_url` | none | FAIL |

## R9 — REACHABILITY: both FAIL members are dark in production (L1, running container)

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
      "echo TOTAL=\$(docker exec cloud-control_plane_blue-1 env | wc -l); \
       docker exec cloud-control_plane_blue-1 env | sed 's/=.*//' | sort | grep -iE 'vercel|github|stripe|token'"

Expect `TOTAL=25` and exactly `STRIPE_PRICE_SUPPORTER / STRIPE_PRICE_SUPPORT_PLUS /
STRIPE_SECRET_KEY / STRIPE_WEBHOOK_SECRET / WORKER_TOKEN` — the grep FIRES, so the absence of
every `VERCEL_*` and `GITHUB_*` name is a measured absence, not a vacuous green.

Consequence: `Vercel.configured?()` is false, so `vercelClaimHtml` returns `""` (app.js:18086)
and the claim CTA cannot paint; `renderGithub`'s `g.configured && g.install_url` arm cannot
paint either. The two PASS exemplars (Stripe Checkout, Stripe Portal) ARE live. **A guard
asserting on either FAIL arm would pass on an empty DOM.** The doctrine row is fundable; a
builder slice against those two arms is not.
