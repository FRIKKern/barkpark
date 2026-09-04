defmodule BarkparkCloud.Billing.Subscription do
  @moduledoc """
  A Team's billing subscription — the persisted result of subscribing through
  the configured `BarkparkCloud.Billing.Gateway`. Belongs to one Team; a Team
  has at most one ACTIVE subscription at a time (`Billing.active_subscription/1`).

  The gateway customer/subscription ids (`gateway_customer_id` /
  `gateway_subscription_id`) are opaque references the gateway hands back —
  deterministic `*_stub_*` ids under `StubGateway`, real `cus_*` / `sub_*` ids
  under `StripeGateway` once a human wires live keys (cloud-17). We hold the
  reference, never the card data.

  Two enumerations, kept as `validate_inclusion` lists (NOT a pricing engine —
  real prices/plan ids are the human task cloud-17):

    * `plan`   — the three tiers (`free` / `supporter` / `support_plus`). `free`
      is the no-charge signup tier; an active PAID subscription gates managed
      launch, so `free` means signed-up-but-not-paying. `supporter` and
      `support_plus` are the two paid tiers (Stripe price ids are cloud-17).
    * `status` — `active` / `canceled` / `past_due`. All three are now LIVE
      transitions driven by `Billing.handle_webhook/2`'s lifecycle path (a
      failed invoice → `past_due`; a deleted Stripe sub → `canceled`; a paid
      invoice → back to `active`). Before subscription-billing only `active`
      was ever written — the other two were dead enum values.

  Lifecycle / dunning columns (mirror Coolify's `Subscription` gate columns
  `stripe_past_due` / `stripe_cancel_at_period_end` / `stripe_refunded_at`):

    * `past_due`            — a payment failed; the team is in dunning. Still
      ENTITLED while inside the grace window (`grace_ends_at`), matching
      Coolify's `isSubscriptionActive()` staying true through `stripe_past_due`.
    * `cancel_at_period_end` — the customer requested cancel-at-period-end
      (reversible grace); stays entitled until Stripe later posts
      `customer.subscription.deleted`.
    * `grace_ends_at`       — the DUNNING grace anchor, and nothing else. Written
      ONLY by `Billing.mark_past_due/2` (`now + @grace_days`), read ONLY by
      `Billing.entitled?/1` and `Billing.maybe_enforce/1`. It is deliberately NOT
      lifted off any Stripe payload: cch-w57-bl split it out of
      `current_period_end` precisely so a payload-sourced renewal date can never
      move a dunning deadline. A NULL `grace_ends_at` on a `past_due` row means
      NOT entitled — an unanchored dunning row is closed, not open forever.
    * `current_period_end`  — the TRIAL EXPIRY, and nothing else. Written by
      `Billing.grant_trial/1` (14 days out) and read by the `trial` arm of
      `entitled?/1`, `expire_trial/2` and `trial_days_remaining/1`. A PAID plan
      stores none (`promise_actor_manifest_test.exs` reds if one ever does).
    * `canceled_at`         — when the subscription went terminal.
    * `refunded_at`         — RESERVED for the deferred refund seam (column
      exists, unused now — Coolify `RefundSubscription.php`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # The subscription tiers. A list (not a free string) so a typo can't create an
  # unbillable plan row. `free` is the no-charge signup tier; `supporter` and
  # `support_plus` are the two paid tiers (internal key `support_plus` — "++"
  # isn't slug-safe; the display name is "Support++"). Real per-tier prices +
  # Stripe price ids are the HUMAN task cloud-17 — this is the tier vocabulary,
  # not a price book.
  #
  # `forever` is an ADMIN-ONLY comp tier — never purchasable (it has no Stripe
  # price, so `Billing.checkout/2` rejects it like `free`), granted only by
  # `Billing.grant_forever/1` / `mix barkpark_cloud.grant_forever`. It carries no
  # gateway ids, so the Stripe lifecycle webhooks (keyed on customer id) can
  # never touch it — a `forever` row stays `active` and entitled indefinitely.
  #
  # `trial` is the SELF-SERVE time-boxed tier granted automatically at signup
  # (`Billing.grant_trial/1`): an `active` row carrying NO gateway ids but a
  # `current_period_end` 14 days out. Unlike `forever`, it is entitled ONLY while
  # `current_period_end` is in the future — an EXPIRED trial is no longer
  # entitled (`Billing.entitled?/1`), so the user must subscribe to a paid tier
  # (which the checkout webhook UPGRADES the trial row into, in place). Also
  # unpriced, so it is never purchasable via `Billing.checkout/2`.
  @plans ~w(free trial supporter support_plus forever)
  @statuses ~w(active canceled past_due)

  schema "subscriptions" do
    field :plan, :string
    field :status, :string, default: "active"
    field :gateway_customer_id, :string
    field :gateway_subscription_id, :string

    # Lifecycle / dunning state (subscription-billing). See moduledoc.
    field :past_due, :boolean, default: false
    field :cancel_at_period_end, :boolean, default: false
    field :current_period_end, :utc_datetime_usec
    field :grace_ends_at, :utc_datetime_usec
    field :canceled_at, :utc_datetime_usec
    # Reserved for the deferred refund seam — column added, unused now.
    field :refunded_at, :utc_datetime_usec

    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def plans, do: @plans
  def statuses, do: @statuses

  @doc """
  Changeset for a subscription. `team_id`, `plan`, and `status` are required;
  `plan` and `status` are validated against their enumerations. The gateway ids
  are set by the context from the gateway's response.
  """
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :plan,
      :status,
      :gateway_customer_id,
      :gateway_subscription_id,
      :past_due,
      :cancel_at_period_end,
      :current_period_end,
      :grace_ends_at,
      :canceled_at,
      :refunded_at,
      :team_id
    ])
    |> validate_required([:plan, :status, :team_id])
    |> validate_inclusion(:plan, @plans)
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:team)
    # One LIVE subscription per team — `active` OR `past_due` (a past_due sub is
    # still the team's live subscription, paid-with-a-warning; Coolify treats
    # `stripe_past_due` the same). `canceled` rows are excluded from the index so
    # re-subscribing after a cancel inserts a fresh `active` row without
    # colliding. Backed by `subscriptions_one_live_per_team_idx`.
    |> unique_constraint(:team_id,
      name: :subscriptions_one_live_per_team_idx,
      message: "already has a live subscription"
    )
  end
end
