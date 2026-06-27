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

    * `checkout/2`           — resolve a plan's price id and open a hosted
      Checkout Session so the customer pays in a browser. "free"/unknown/unpriced
      → `{:error, :plan_invalid}`.
    * `handle_webhook/2`     — verify a Stripe-signed webhook over the RAW body
      and, on a valid activating event, mark the team's subscription active.
      Idempotent; a forged event grants nothing.
    * `subscribe/2`          — create a gateway customer, open a subscription on
      a plan, and PERSIST a `Subscription` row in one go.
    * `charge_go_live/2`     — the one-off pay-once charge (legacy; the launch
      gate now requires an ACTIVE subscription instead).
    * `active_subscription/1` — a Team's current active subscription, or nil.

  NOT here: dunning, invoices, proration, cancel/portal, refunds, per-tier
  quotas (an active subscription gates launch; the tier is recorded, quotas are
  a later config). The five plan tiers are a `validate_inclusion` list on
  `Subscription`, not a pricing engine — real prices/price-ids are the human
  task cloud-17.
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
  Open a hosted Checkout Session for `team` on `plan` — the customer-initiated
  subscription path (the browser pays). Resolves the plan's gateway-side price
  id from config, then calls the gateway's `create_checkout_session/3` with the
  team's id (the AUTHED team — the caller passes a `%Team{}`/id it already
  authorized, never a client value), the plan, and the resolved price id.

  Returns `{:ok, checkout_url}` or `{:error, :plan_invalid}` for "free", an
  unknown plan, or a plan with no configured price (`free` needs no checkout;
  an unpriced plan can't open one). The actual subscription is marked active
  later, when Stripe posts a signed `checkout.session.completed` webhook that
  `subscribe/2` lands.
  """
  @spec checkout(Team.t() | binary(), Subscription.plan() | atom() | String.t()) ::
          {:ok, BarkparkCloud.Billing.Gateway.checkout_url()} | {:error, :plan_invalid | term}
  def checkout(team, plan) do
    plan = to_string(plan)

    case price_id(plan) do
      nil ->
        {:error, :plan_invalid}

      price_id ->
        gateway().create_checkout_session(team_id(team), plan, price_id: price_id)
    end
  end

  @doc """
  The configured gateway-side price id for `plan`, or nil. "free" and any plan
  without a configured price resolve to nil (no checkout). Read at call time so
  runtime.exs's env-fed prices win.
  """
  @spec price_id(String.t()) :: String.t() | nil
  def price_id(plan) when is_binary(plan) do
    Application.get_env(:barkpark_cloud, __MODULE__, [])
    |> Keyword.get(:prices, %{})
    |> Map.get(plan)
  end

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

  # The webhook event types that activate a subscription. checkout.session
  # .completed is the primary signal (the customer finished the hosted
  # checkout); the subscription.created/updated pair is honoured too so a status
  # flip to active is not missed.
  @activating_event_types ~w(
    checkout.session.completed
    customer.subscription.created
    customer.subscription.updated
  )

  @doc "The webhook event types that mark a subscription active. For the router/tests."
  @spec activating_event_types() :: [String.t()]
  def activating_event_types, do: @activating_event_types

  @doc """
  Handle an inbound billing webhook end to end: verify the `raw_body` against
  its `signature` through the gateway, and — on a VALID event whose type
  activates a subscription — read `team_id`+`plan` from the (Stripe-SIGNED)
  event metadata and mark that team's subscription active.

  CRITICAL: `raw_body` MUST be the unparsed request bytes — the signature is
  computed over them. A forged or unsigned event fails verification and
  `{:error, :invalid_signature}` is returned, granting NOTHING.

  Idempotent: a repeated event for a team that already has an active
  subscription is a no-op success (`{:ok, :already_active}`) — it never inserts
  a second row (the one-active-per-team index is the backstop) and never errors.

  Returns:

    * `{:ok, %Subscription{}}`   — a new active subscription was landed.
    * `{:ok, :already_active}`   — the team was already subscribed (idempotent).
    * `{:ok, :ignored}`          — a valid event of a non-activating type.
    * `{:error, :invalid_signature}` — a bad/missing signature (grants nothing).
    * `{:error, term}`           — a malformed event or a persistence failure.
  """
  @spec handle_webhook(binary(), binary()) ::
          {:ok, Subscription.t() | :already_active | :ignored} | {:error, term}
  def handle_webhook(raw_body, signature) when is_binary(raw_body) and is_binary(signature) do
    with {:ok, event} <- verify_webhook(raw_body, signature) do
      dispatch_event(event, raw_body)
    end
  end

  # The gateway returns its decoded event. The StripeGateway decodes the raw JSON
  # straight into the Stripe event map; the StubGateway returns a wrapper
  # (`%{"verified" => true, "payload" => raw}`) — in that case the real event is
  # the raw JSON body we already hold, so parse it here. Either way we end up
  # with the Stripe-shaped event map and dispatch on its type.
  defp dispatch_event(%{"verified" => true} = _stub_wrapper, raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{} = event} -> activate_from_event(event)
      _ -> {:error, :invalid_payload}
    end
  end

  defp dispatch_event(%{} = event, _raw_body), do: activate_from_event(event)

  # Activate iff the event type is one of the activating set; read team_id+plan
  # from the SIGNED metadata (event.data.object.metadata) and subscribe. A
  # subscription.* event with a non-active status is ignored.
  defp activate_from_event(%{"type" => type} = event) when type in @activating_event_types do
    object = get_in(event, ["data", "object"]) || %{}
    metadata = Map.get(object, "metadata", %{})
    team_id = metadata["team_id"]
    plan = metadata["plan"]

    cond do
      not active_status?(type, object) ->
        {:ok, :ignored}

      is_binary(team_id) and is_binary(plan) ->
        activate_subscription(team_id, plan)

      true ->
        {:error, :missing_metadata}
    end
  end

  defp activate_from_event(%{}), do: {:ok, :ignored}

  # checkout.session.completed needs no status check (completion IS the signal);
  # a customer.subscription.* event only activates when its status is "active".
  defp active_status?("checkout.session.completed", _object), do: true
  defp active_status?(_type, object), do: Map.get(object, "status") == "active"

  @doc """
  Idempotently mark `team_id`'s subscription on `plan` active. If the team is
  already actively subscribed, this is a no-op (`{:ok, :already_active}`) — it
  never creates a second row. Otherwise it subscribes (the full gateway
  customer→subscription→persist flow). Used by `handle_webhook/2`; the team id
  and plan come from a SIGNED event, never a client.
  """
  @spec activate_subscription(binary(), String.t()) ::
          {:ok, Subscription.t() | :already_active} | {:error, term}
  def activate_subscription(team_id, plan) when is_binary(team_id) and is_binary(plan) do
    case active_subscription(team_id) do
      %Subscription{} ->
        {:ok, :already_active}

      nil ->
        subscribe(team_id, plan)
    end
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
