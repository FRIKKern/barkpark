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
    * `status` — `active` / `canceled` / `past_due`.
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
  @plans ~w(free supporter support_plus)
  @statuses ~w(active canceled past_due)

  schema "subscriptions" do
    field :plan, :string
    field :status, :string, default: "active"
    field :gateway_customer_id, :string
    field :gateway_subscription_id, :string

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
      :team_id
    ])
    |> validate_required([:plan, :status, :team_id])
    |> validate_inclusion(:plan, @plans)
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:team)
    |> unique_constraint(:team_id,
      name: :subscriptions_one_active_per_team_idx,
      message: "this team already has an active subscription"
    )
  end
end
