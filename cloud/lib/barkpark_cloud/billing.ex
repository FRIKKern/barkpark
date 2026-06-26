defmodule BarkparkCloud.Billing do
  @moduledoc """
  The billing context — the pay-once go-live path, built and tested at €0 spend.

  Every payment side effect routes through a config-selected
  `BarkparkCloud.Billing.Gateway`: `StubGateway` in dev/test (in-memory,
  deterministic, no network), the Stripe skeleton in prod once a human wires
  live keys (cloud-17). The context never names a provider — it calls
  `gateway()` and the behaviour. This is the same config-driven-adapter seam as
  `Registry.Vault`'s key source.

  Scope is deliberately narrow (YAGNI). What ships:

    * `subscribe/2`          — create a gateway customer, open a subscription on
      a plan, and PERSIST a `Subscription` row in one go.
    * `charge_go_live/2`     — the one-off pay-once go-live charge.
    * `active_subscription/1` — a Team's current active subscription, or nil.

  NOT here: dunning, invoices, proration, refunds, webhook event handlers beyond
  `Gateway.verify_webhook/2`, and any admin UI. The five plan tiers are a
  `validate_inclusion` list on `Subscription`, not a pricing engine — real
  prices are the human task cloud-17.
  """
  import Ecto.Query, warn: false

  alias BarkparkCloud.Repo
  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Billing.Subscription

  # The currency the control plane bills in. Single value (not a per-team
  # setting) — multi-currency is out of scope (YAGNI).
  @currency "eur"

  @doc """
  The configured billing gateway module. Resolved at call time (not compile
  time) so runtime.exs's prod override is honoured — mirrors `Registry.Vault`'s
  config-at-call-time key resolution. Defaults to `StubGateway` so a missing
  config never silently routes money anywhere.
  """
  @spec gateway() :: module()
  def gateway do
    Application.get_env(:barkpark_cloud, __MODULE__, [])
    |> Keyword.get(:gateway, BarkparkCloud.Billing.StubGateway)
  end

  @doc "The currency the control plane bills in (ISO-4217, lower-case)."
  @spec currency() :: String.t()
  def currency, do: @currency

  @doc """
  Subscribe `team` to `plan`: create a customer with the gateway, open a
  subscription on the plan, then persist a `Subscription` row carrying the
  gateway's customer/subscription ids and an `active` status.

  Returns `{:ok, %Subscription{}}` or `{:error, reason}` — a gateway failure
  short-circuits before anything is persisted, and a changeset failure (e.g. an
  invalid plan, or a second active subscription for the team) returns the
  changeset.
  """
  @spec subscribe(Team.t() | binary(), Subscription.plan() | atom() | String.t()) ::
          {:ok, Subscription.t()} | {:error, term}
  def subscribe(team, plan) do
    plan = to_string(plan)
    gw = gateway()

    with {:ok, customer_id} <- gw.create_customer(%{team_id: team_id(team)}),
         {:ok, subscription_id} <- gw.create_subscription(customer_id, plan) do
      %Subscription{}
      |> Subscription.changeset(%{
        team_id: team_id(team),
        plan: plan,
        status: "active",
        gateway_customer_id: customer_id,
        gateway_subscription_id: subscription_id
      })
      |> Repo.insert()
    end
  end

  @doc """
  Charge `team` `amount_cents` (minor units) for going live — the pay-once
  go-live charge. Creates a customer for the team and charges it through the
  gateway. Returns `{:ok, charge_id}` or `{:error, reason}`. Does not persist a
  row (a go-live charge is a one-off event, not a subscription).
  """
  @spec charge_go_live(Team.t() | binary(), pos_integer()) ::
          {:ok, BarkparkCloud.Billing.Gateway.charge_id()} | {:error, term}
  def charge_go_live(team, amount_cents) when is_integer(amount_cents) and amount_cents > 0 do
    gw = gateway()
    tid = team_id(team)

    with {:ok, customer_id} <- gw.create_customer(%{team_id: tid}) do
      gw.charge(customer_id, amount_cents, @currency, %{team_id: tid, reason: "go_live"})
    end
  end

  @doc """
  Verify an inbound billing webhook through the configured gateway. Thin
  pass-through to `Gateway.verify_webhook/2` — verification only, no event
  dispatch (YAGNI).
  """
  @spec verify_webhook(binary(), binary()) :: {:ok, term} | {:error, term}
  def verify_webhook(payload, signature) do
    gateway().verify_webhook(payload, signature)
  end

  @doc "A Team's active subscription, or nil. Scoped — never crosses teams."
  @spec active_subscription(Team.t() | binary()) :: Subscription.t() | nil
  def active_subscription(team) do
    tid = team_id(team)

    Subscription
    |> where([s], s.team_id == ^tid and s.status == "active")
    |> Repo.one()
  end

  ## Helpers

  defp team_id(%Team{id: id}), do: id
  defp team_id(id) when is_binary(id), do: id
end
