# Re-derivation recipes — wave 49 verifier [billing-capability-shape]

Every row re-derives from scratch. Run from repo root unless noted.

## R1 — `configured?/0` is an AND and collapses THREE states, not two

```
cd cloud && cat > /tmp/p.exs <<'EOF'
alias BarkparkCloud.Billing
gw = BarkparkCloud.Billing.StripeGateway
set = fn prices, secret ->
  Application.put_env(:barkpark_cloud, Billing, gateway: gw, prices: prices)
  Application.put_env(:barkpark_cloud, gw, webhook_secret: secret)
end
show = fn l -> IO.puts("#{l}: configured?=#{inspect(Billing.configured?())} price_id(supporter)=#{inspect(Billing.price_id("supporter"))}") end
set.(%{}, nil); show.("A")
set.(%{}, "whsec_x"); show.("B")
set.(%{"supporter" => "price_1"}, nil); show.("C")
set.(%{"supporter" => "price_1"}, "whsec_x"); show.("D")
EOF
MIX_ENV=dev mix run --no-start /tmp/p.exs
```

Expected: A/B/C false, D true. **C is the money-moves state**: `price_id` resolves, so
`Billing.checkout/2` never returns `:plan_invalid` and the router's `configured?` branch
NEVER fires — a real Stripe session opens while `verify_webhook` is `{:error, :no_secret}`.

## R2 — partial wiring makes `configured?` true while a tier still 422s

```
cd cloud && cat > /tmp/p2.exs <<'EOF'
alias BarkparkCloud.Billing
gw = BarkparkCloud.Billing.StripeGateway
Application.put_env(:barkpark_cloud, Billing, gateway: gw, prices: %{"supporter" => "price_sup"})
Application.put_env(:barkpark_cloud, gw, webhook_secret: "whsec_x")
IO.puts("configured?=#{inspect(Billing.configured?())}")
for p <- ["free","supporter","support_plus"], do: IO.puts("  #{p}=#{inspect(Billing.price_id(p))}")
EOF
MIX_ENV=dev mix run --no-start /tmp/p2.exs
```

## R3 — the router consults `configured?` only in the refuse arm

```
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'Billing.configured?'
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '5255,5275p'
```

## R4 — `/v1/me` forbids capability claims, verbatim

```
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '1448,1462p'
```

## R5 — the working-tree app.js is NOT main; derive from origin/main

```
git diff --stat origin/main -- cloud/priv/static/app.js     # 508 ins / 4346 del on 2026-08-07
git show origin/main:cloud/priv/static/app.js > /tmp/main-app.js
grep -n 'PLAN_CATALOG = \|function renderTiers\|function launchPlanGridHtml\|billing/checkout' /tmp/main-app.js
```

## R6 — `billing_not_configured` copy already exists client-side

```
git show origin/main:cloud/priv/static/app.js | grep -n 'billing_not_configured'
```

## R7 — `subscription_json` is outside the payload-key-set census

```
git show origin/main:cloud/test/barkpark_cloud/payload_key_set_census_test.exs | grep -n 'subscription_json'
```
(zero hits; and the `barkpark_json/4 :phantom team` reconciled row states in-route
`Map.put` keys are invisible to Side A — same shape as a top-level sibling key.)
