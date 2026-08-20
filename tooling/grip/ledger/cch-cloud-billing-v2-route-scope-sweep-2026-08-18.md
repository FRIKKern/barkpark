<!-- doc-tier: cold | canonical-for: none | budget: 2000tok -->
# V2 route-scope-sweep — raw-Stripe-body echo fence (origin/main 3ddc00a0)

Re-derivation recipes for the V2 completeness verdict. All commands read `origin/main`
(local checkout is 184 commits behind — anchor on origin/main, never local line numbers).

## Fence is EXACTLY router.ex 5842 / 5872 / 5932

The `{:stripe_http_error, status, body}` tuple is minted at exactly one site and
reaches a client only through the three billing routes that call a gateway function
which calls `request/`.

    git show origin/main:cloud/lib/barkpark_cloud/billing/stripe_gateway.ex | grep -n 'stripe_http_error'
    # → 280: {:ok, %{status: status, body: body}} -> {:error, {:stripe_http_error, status, body}}

    git grep -nE 'reason: inspect|inspect\(reason\)|detail:.*inspect|message:.*inspect' origin/main -- 'cloud/lib/**/*.ex' | grep json
    # client-facing json() echoes: router.ex 5842 checkout_failed(422), 5872 portal_failed(422),
    # 5932 cancel_failed(422), 6008 invalid_webhook(400), 12217 deploy_not_started(503),
    # 13879 upload_failed(500), 13962 deploy_not_started(503)

## Webhook 6008 CANNOT carry the tuple (verify path never calls request/)

    git show origin/main:cloud/lib/barkpark_cloud/billing/stripe_gateway.ex | sed -n '189,203p'
    # verify_webhook -> webhook_secret() -> verify_signature(); no request/ call.
    # Billing.handle_webhook only calls verify_webhook. So 6008 carries
    # {:no_secret}/{:invalid_signature}/decode atoms — NOT the raw Stripe HTTP body.
    # 6008 = optional cheap hardening (same helper), NOT a raw-body leak site.

## Sibling card-PII paths (charge / create_subscription / create_customer) are UNREACHABLE

`request/` callers in stripe_gateway.ex: create_customer(61), update_customer(72),
charge(93), create_subscription(113), create_checkout_session(151),
create_billing_portal_session(168), cancel_subscription(179/184).
The charge/create_subscription/create_customer group is only reached through
`Billing.subscribe/2` (billing.ex:463) and `Billing.charge_go_live/2` (billing.ex:489).

    git grep -nE 'Billing\.subscribe|charge_go_live|Billing\.charge' origin/main -- 'cloud/lib/**/*.ex' | grep -v test
    # → only the defs in billing.ex; NO production caller. charge_go_live is
    #   documented legacy (launch/go-live subscription replaced it). Router client
    #   routes call only Billing.checkout / billing_portal_url / request_cancel /
    #   handle_webhook. => no sibling echoes the tuple; card PII cannot escape.

## Other echo forms carry no tuple

    git grep -nE 'to_string\(reason\)|Atom\.to_string\(reason\)' origin/main -- 'cloud/lib/**/*.ex'
    # domain_status.ex:722 (is_atom guard), registry.ex:4000, usage.ex:253 — atoms only.

    git grep -nE 'json\(conn, [0-9]+, %\{.*reason' origin/main -- 'cloud/lib/**/*.ex' | grep -v router.ex
    # (empty) — no client-facing billing echo outside router.ex.

## Out-of-fence, file as SEPARATE backlog rows (not stripe, no card PII)

    router.ex:12102 cloudflare_bind_failed (502) — Cloudflare provider error term via inspect(reason) — parallel provider-body leak
    router.ex:12217 deploy_not_started (503) — deploy-driver term
    router.ex:13879 upload_failed (500) — storage term
    router.ex:13962 deploy_not_started (503) — deploy-driver term

VERDICT: APPROVE on completeness. Raw-Stripe-body fence = router.ex 5842/5872/5932.
No missed sibling. 6008 = optional hardening (verify path, no raw body).
