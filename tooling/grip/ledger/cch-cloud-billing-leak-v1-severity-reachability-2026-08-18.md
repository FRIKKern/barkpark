<!-- doc-tier: cold | canonical-for: none | budget: 2000tok -->
# V1 — Cloud Billing raw-Stripe-body leak: severity + reachability re-derivation (origin/main 3ddc00a0)

VERDICT: APPROVE (defect real, owner-reachable not anon, identifiers not card-PAN; 6008 is optional-hardening, NOT raw-body fence).

Anchor everything on origin/main — local checkout is 184 commits behind (`git rev-list --count HEAD..origin/main` = 184), so its line numbers (5811/5841/5901/5977) are STALE. Locate by grep pattern.

## Re-derive the leak source (raw body minted)
    git show origin/main:cloud/lib/barkpark_cloud/billing/stripe_gateway.ex | sed -n '272,285p'
    # 280: {:ok, %{status: status, body: body}} -> {:error, {:stripe_http_error, status, body}}
    # `body` = raw Stripe HTTP response bytes. Minted at exactly ONE site.

## Re-derive the client echo sites (origin/main lines)
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'reason: inspect(reason)\|_failed", reason'
    # 5842 checkout_failed | 5872 portal_failed | 5932 cancel_failed | 6008 invalid_webhook

## Re-derive the authenticated owner gate (NOT anon)
    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | sed -n '445,462p'
    # require_primary_team_owner: require_user (401 anon) -> no_team (422) -> Authz.team_owner? (403 non-owner) -> pass
    # Only an authenticated PRIMARY-TEAM OWNER reaches the echo. Anon halts 401.

## Re-derive the propagation path (gateway -> Billing -> router, unmodified)
    git show origin/main:cloud/lib/barkpark_cloud/billing.ex | sed -n '136,153p;949,1000p'
    # checkout -> gateway().create_checkout_session -> request(:url)   (stripe_gateway 151)
    # billing_portal_url -> gateway().create_billing_portal_session -> request(:url)  (168)
    # request_cancel -> gateway().cancel_subscription -> request(:id/:delete)  (179/184)
    # each returns {:error, {:stripe_http_error,...}} unmodified; router catch-all echoes it.

## Re-derive 6008 CANNOT carry the tuple (exclude from raw-body fence)
    git show origin/main:cloud/lib/barkpark_cloud/billing.ex | sed -n '564,572p'
    # handle_webhook -> verify_webhook -> gateway().verify_webhook
    git show origin/main:cloud/lib/barkpark_cloud/billing/stripe_gateway.ex | sed -n '188,204p'
    # verify_webhook does LOCAL HMAC only (verify_signature) — never calls request/.
    # Its errors: :no_secret | :invalid_signature | :invalid_payload | changeset. NO raw HTTP body.
    # => 6008 is optional hardening, not part of the raw-body fence.

## Re-derive the contractual tuple pin (redact at router, NOT at gateway)
    git show origin/main:cloud/test/barkpark_cloud/billing/http_client_test.exs | sed -n '134,141p'
    # asserts {:error, {:stripe_http_error, 402, _body}} — stripping body at gateway breaks this + kills operator diag.

## Proof the tuple is minted (injected stub round-trip)
    cd cloud && mix test test/barkpark_cloud/billing/http_client_test.exs
    # 8 tests, 0 failures — incl. "non-2xx -> {:error, {:stripe_http_error, ...}}"

## Data classes on the 3 named routes
Stripe API error bodies on /v1/checkout/sessions, /v1/billing_portal/sessions, /v1/subscriptions/:id:
identifiers (cus_/sub_/price_/prod_), free-text error type/code/message, request-log url hints.
NOT raw card PAN/CVC (Stripe never returns those). Card PII would require a charge/subscription
echo site — that is V2's completeness question. Severity: above-bar leak of internal identifiers +
Stripe account internals to an authenticated owner; NOT anonymous, NOT cardholder PAN.

## Belt-log guard (for the builder)
stripe_gateway.ex has NO `require Logger` and NO `Logger.` calls (grep confirmed) — a belt server-side
log there reds the cp-deploy build unless `require Logger` is added first (#11723 brick guard).
