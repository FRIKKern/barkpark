<!-- doc-tier: cold | canonical-for: wbqs-billing-reason-leak-runproof | budget: 1200tok -->

# wbq-cloud-billing-reason-leak — fail-closed re-derivation recipe

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Verifier assignment [billing-runproof], wild-bulk-quality-sweep reconcile wave.
Pin: origin/main @ 710c38f06a7e21441f3993ef3ebff01c1317a8ae.

## Claim

A LIVE, unsuperseded, offline-buildable, above-bar security defect: the billing
error sinks in the cloud router echo `reason: inspect(reason)` where `reason` is
`{:stripe_http_error, status, body}` carrying the RAW Stripe HTTP response body,
reachable by an authenticated NON-ADMIN primary-team owner (a normal paying
customer). Its only prior blocker (wbq-cloud-auth-onboarding-500) is DONE.

## Re-derivation commands (each re-derives one fact)

1. Raw body flows verbatim into the error tuple, and `inspect(reason)` carries it:
   ```
   cd cloud && MIX_ENV=test mix run -e '
   alias BarkparkCloud.Billing.StripeGateway
   base = Application.get_env(:barkpark_cloud, StripeGateway, [])
   Application.put_env(:barkpark_cloud, StripeGateway, Keyword.merge(base, [secret_key: "sk_test_x", http_client: fn _req -> {:ok, %{status: 402, body: ~s({"error":{"LEAK":"cus_SENSITIVE"}})}} end]))
   {:error, {:stripe_http_error, s, b}} = StripeGateway.create_customer(%{email: "x@y.com"})
   IO.puts("REASON_FIELD_JSON=" <> inspect({:stripe_http_error, s, b}))'
   ```
   Expect: `REASON_FIELD_JSON={:stripe_http_error, 402, "{\"error\":{\"LEAK\":\"cus_SENSITIVE\"}}"}`

2. Shipped test binds `_body` (ignores body) — proving body==raw needs an EXTENDED assertion:
   `git show origin/main:cloud/test/barkpark_cloud/billing/http_client_test.exs | sed -n '136,142p'`
   The assertion is `{:error, {:stripe_http_error, 402, _body}}` — shape only, NOT body content.

3. The gateway builds the tuple with raw body (source):
   `git show origin/main:cloud/lib/barkpark_cloud/billing/stripe_gateway.ex | sed -n '272,283p'`
   Line: `{:ok, %{status: status, body: body}} -> {:error, {:stripe_http_error, status, body}}`

4. Four router sinks echo `inspect(reason)`:
   `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '5842p;5872p;5932p;6008p'`
   5842 checkout_failed, 5872 portal_failed, 5932 cancel_failed, 6008 invalid_webhook.
   All three billing routes (checkout/portal/cancel) route through StripeGateway.request/2
   → same {:stripe_http_error,...} reason. Webhook (6008) is signature-gated, different reason type.

5. Auth gate = normal paying customer, NOT platform admin:
   `git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | sed -n '445,461p'`
   `require_primary_team_owner` → `Authz.team_owner?(current_user, current_team)` — owner of
   their OWN team. A team owner is a paying customer, not a PLATFORM_ADMIN.

6. Prod wires a REAL http_client (raw-body liveness is real when STRIPE_SECRET_KEY set):
   `git show origin/main:cloud/config/runtime.exs | sed -n '132,135p'`
   `http_client: &BarkparkCloud.Billing.HttpClient.request/1` (prod branch, when key set).

## Verdict

GENUINE above-bar, offline-buildable, currently-unsuperseded security defect.
cch-w72-s2 curates FRONT-END console copy for portal_failed, NOT the API JSON
`reason` field — a direct API caller (bp/curl) still receives the raw body.
Proving body==raw in the test requires extending the assertion from `_body` to a
concrete `body` bind + equality assert. Fix edits a cloud/ cp-deploy prod path —
FENCE-FORBIDDEN to build here; surface as a SPIN candidate, do not re-parent shut.
