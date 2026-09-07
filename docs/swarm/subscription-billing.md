<!-- doc-tier: human | canonical-for: swarm-subscription-billing | budget: 1200tok -->
# subscription-billing (candidate)

Extend Barkpark Cloud's billing slice past the binary `active` gate into a real
subscription lifecycle: dunning (`past_due`), cancellation (`canceled`),
recovery, a self-serve management surface (Stripe Customer Portal + cancel), and
the teeth that disable already-provisioned instances on a lapse. **Candidate —
judge before merge.** €0 / no live Stripe.

## What & why

Before this change `Billing.handle_webhook/2` only ever wrote `status: "active"`
— `canceled` / `past_due` were dead enum values, a failed payment did nothing,
and a launched box stayed live forever regardless of billing. That is fine for a
demo, not for leaving beta. This adds the state machine, the customer-facing
controls, and the enforcement, leaning entirely on the existing gateway seam +
signed-webhook verifier (no parallel system, no new dep).

## Coolify source anchors (reference, read-only)

- `app/Jobs/StripeProcessJob.php` — the webhook router. Its handled event set
  (`checkout.session.completed`, `customer.subscription.created/updated/deleted`,
  `invoice.paid`, `invoice.payment_failed`) is mirrored 1:1 here.
- `app/Jobs/SubscriptionInvoiceFailedJob.php` + `Subscription.stripe_past_due` —
  the dunning model behind `mark_past_due/2`.
- `app/Models/Team.php::subscriptionEnded()` — walks `team->servers` and sets
  `is_usable=false`/`is_reachable=false` on each. The model for the
  suspend-on-lapse teeth (`Registry.suspend_team_barkparks/2`).
- `app/Models/Subscription.php` — `stripe_past_due`, `stripe_cancel_at_period_end`
  gate columns + `isSubscriptionActive()` (stays true through `past_due`); the
  model for `entitled?/1`.
- `bootstrap/helpers/subscriptions.php::getStripeCustomerPortalSession()` — the
  portal session, mirrored by `create_billing_portal_session/2`.
- `app/Actions/Stripe/CancelSubscription.php` /
  `CancelSubscriptionAtPeriodEnd.php` — immediate vs grace cancel, mirrored by
  `cancel_subscription/2`'s `:at_period_end` opt. **The parity stops at the
  gateway.** `POST /v1/billing/cancel` offers the GRACE cancel only: it always
  passes `at_period_end: true` and refuses a body carrying `false` with 422
  `{invalid, details}` (task-527f2a101b99ebf9, ruled 2026-09-07 — the immediate
  arm was reachable by any plain team owner behind nothing but the password
  re-confirm below, and no shipped client ever sent it). `Billing.request_cancel/2`
  keeps the `false` branch; nothing routes to it.
- `app/Livewire/Subscription/Actions.php` — re-confirms the password before a
  destructive cancel (the model for `POST /v1/billing/cancel`'s password gate).
- `app/Jobs/SyncStripeSubscriptionsJob.php` — the nightly reconcile sweep.
  **Designed but deferred** here (see Caveats).
- `app/Actions/Stripe/RefundSubscription.php` — refunds. **Out of scope**;
  `subscriptions.refunded_at` is reserved as the future seam only.

## Barkpark files touched (all under `cloud/`)

| File | Change |
|---|---|
| `lib/barkpark_cloud/billing/subscription.ex` | +5 fields (`past_due`, `cancel_at_period_end`, `current_period_end`, `canceled_at`, `refunded_at`); relaxed unique constraint → `one_live_per_team` (active OR past_due) |
| `lib/barkpark_cloud/billing/gateway.ex` | +2 callbacks: `create_billing_portal_session/2`, `cancel_subscription/2` |
| `lib/barkpark_cloud/billing/stripe_gateway.ex` | impl portal (`POST /billing_portal/sessions`) + cancel (`POST`/`DELETE /subscriptions/:id`); `:delete` method; `portal_return_url` config |
| `lib/barkpark_cloud/billing/stub_gateway.ex` | deterministic portal + cancel stubs |
| `lib/barkpark_cloud/billing/http_client.ex` | `to_httpc/1` `:delete` clause |
| `lib/barkpark_cloud/billing.ex` | lifecycle dispatch (`handle_subscription_updated/2`, `handle_lifecycle/1`); `mark_past_due/2`, `cancel_subscription/1`, `recover_subscription/1`, `maybe_enforce/1`; `live_subscription/1`, `entitled?/1`; `billing_portal_url/2`, `request_cancel/2` |
| `lib/barkpark_cloud/registry/barkpark.ex` | +suspension axis (`suspended`, `suspended_reason`, `suspended_at`) + `suspend_changeset/2` |
| `lib/barkpark_cloud/registry.ex` | `suspend_team_barkparks/2`, `resume_team_barkparks/1` (bulk `update_all`, managed-only, idempotent) |
| `lib/barkpark_cloud/web/router.ex` | `POST /v1/billing/portal`, `POST /v1/billing/cancel`; launch gate → `entitled?`; `GET /v1/subscription` → `live_subscription`; `barkpark_json`/`subscription_json` carry the new fields; `confirm_password/1` |
| `config/runtime.exs` | `portal_return_url: STRIPE_PORTAL_RETURN_URL` (no secret) |
| `priv/repo/migrations/20260629120500_add_lifecycle_to_subscriptions.exs` | new |
| `priv/repo/migrations/20260629120600_add_suspended_to_barkparks.exs` | new |
| `test/barkpark_cloud/billing_lifecycle_test.exs` | new — lifecycle, entitlement, self-serve, registry suspension, gateway shapes |
| `test/barkpark_cloud/web/router_billing_lifecycle_test.exs` | new — portal/cancel routes + grace-aware gate |
| `test/barkpark_cloud/web/router_billing_cancel_immediate_refused_test.exs` | new (task-527f2a101b99ebf9) — the removed immediate arm, guarded at the gateway seam |
| `test/barkpark_cloud/billing_test.exs` | updated one constraint-message assertion |

## Data model

`subscriptions` gains the lifecycle columns; the partial unique index moves from
`status = 'active'` to `status IN ('active','past_due')` (a past_due sub is still
the team's one live row). `barkparks` gains a billing-suspension axis kept
SEPARATE from `health_status`/`agent_status` (suspension is a billing verdict,
not a health fact). Migrations are written but **NOT run** (the swarm rule).

## How to test

```bash
cd cloud
mix deps.get          # deps are not provisioned in the worktree
mix ecto.migrate      # applies the two new migrations to a dev/test DB
mix test test/barkpark_cloud/billing_lifecycle_test.exs \
          test/barkpark_cloud/web/router_billing_lifecycle_test.exs \
          test/barkpark_cloud/billing_test.exs
```

Everything runs through `StubGateway` — no network, no live Stripe keys. The
`StripeGateway` portal/cancel request shapes are asserted via the pure
`build_request/3` builder and never sent.

## Caveats / honest notes

- **No full `mix compile`/`mix test` run here** — deps/`_build` aren't
  provisioned in the worktree. Every touched file passes a pure-syntax parse;
  correctness is by-reading + the test suite above. `mix format` could not run
  (`import_deps :ecto` needs `mix deps.get`).
- **Reconciliation sweep still deferred — but NOT for the reason recorded here.**
  Coolify's `SyncStripeSubscriptionsJob` (nightly drift repair) is designed as an
  Oban `ReconcileWorker`. `cloud/` DOES have an Oban/cron substrate now
  (`{:oban, "~> 2.17"}`, an `{Oban, ...}` child, a live `Oban.Plugins.Cron` crontab,
  14 workers under `cloud/lib/barkpark_cloud/workers/`); what is missing is a
  `ReconcileWorker` written against it. Until one is, the webhook path is the only
  reconciliation — the operational safety-net gap is real and flagged.
- **Agent-side enforcement is advisory for beta.** Suspension is authoritative at
  the control plane (dashboard surfaces it; `entitled?/1` blocks re-launch). The
  on-box agent reading `suspended` to stop serving is a thin follow-up that
  reuses the column.
- **`past_due` grace anchor** comes from the event's `data.object.current_period_end`.
  For a real `invoice.payment_failed` the object is the invoice; if that field is
  absent the sub stays in grace (beta-safe: never suspend a paying customer on a
  missing field). The nightly sweep is the intended belt-and-braces.
- **Out of scope** (per triaged intent): usage metering, proration/quantity,
  refunds, an invoices table. `refunded_at` exists as a reserved column only.
- **Live Stripe keys remain the cloud-17 human gate** — no secrets added.
