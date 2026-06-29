defmodule BarkparkCloud.Billing do
  @moduledoc """
  The billing context — the pay-once go-live path, built and tested at €0 spend.

  Every payment side effect routes through a config-selected
  `BarkparkCloud.Billing.Gateway`: `StubGateway` in dev/test (in-memory,
  deterministic, no network), the real Stripe gateway in prod (its HTTP transport
  is wired; live keys + price ids remain the cloud-17 human gate). The context
  never names a provider — it calls
  `gateway()` and the behaviour. This is the same config-driven-adapter seam as
  `Registry.Vault`'s key source.

  Scope is deliberately narrow (YAGNI). What ships:

    * `checkout/2`           — resolve a plan's price id and open a hosted
      Checkout Session so the customer pays in a browser. "free"/unknown/unpriced
      → `{:error, :plan_invalid}`.
    * `handle_webhook/2`     — verify a Stripe-signed webhook over the RAW body
      and dispatch it: an ACTIVATING event marks the team's subscription active;
      a LIFECYCLE event (payment failed / sub deleted / invoice paid) drives the
      status state machine past `active` (→ `past_due` / `canceled` / recovery).
      Idempotent; a forged event grants nothing.
    * `subscribe/2`          — create a gateway customer, open a subscription on
      a plan, and PERSIST a `Subscription` row in one go.
    * `charge_go_live/2`     — the one-off pay-once charge (legacy; the launch
      gate now requires ENTITLEMENT instead).
    * `live_subscription/1`  — a Team's live subscription (active OR past_due).
    * `entitled?/1`          — is the team entitled to managed resources right
      now? Active, or past_due within its grace window.
    * `active_subscription/1` — a Team's current active subscription, or nil.
    * `mark_past_due/1` · `cancel_subscription/1` · `recover_subscription/1` —
      the status transitions the webhook lifecycle drives. The cancel transition
      SUSPENDS the team's managed instances; recovery RESUMES them.
    * `billing_portal_url/2` — open a Stripe Customer Portal session for a team.
    * `request_cancel/2`     — customer-initiated cancel (grace or immediate).

  NOT here (still deferred): invoices, proration / quantity changes, refunds,
  per-tier quotas, and the nightly reconciliation sweep (designed as an Oban
  `ReconcileWorker`, blocked on the missing `cloud/` Oban substrate). The plan
  tiers (`free` / `supporter` / `support_plus`) are a `validate_inclusion` list
  on `Subscription`, not a pricing engine — real prices/price-ids are the human
  task cloud-17.
  """
  import Ecto.Query, warn: false

  alias BarkparkCloud.Repo
  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.Registry

  # The currency the control plane bills in. Single value (not a per-team
  # setting) — multi-currency is out of scope (YAGNI).
  @currency "usd"

  # The dunning grace window: how long a `past_due` team stays entitled after a
  # failed payment before its managed boxes are suspended. Anchored deterministically
  # at `mark_past_due` time (the Stripe Invoice object carries no period end), so the
  # grace is payload-shape-independent (Coolify keeps a past_due team running ~3 days).
  @grace_days 3

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

  # The webhook event types that drive the lifecycle past `active`. Keyed on the
  # gateway customer id (NOT metadata — a deleted/failed event carries no team
  # metadata we control). `customer.subscription.updated` is in BOTH sets: an
  # update flipping status TO active activates (handled by the activating path);
  # an update flipping to canceled/unpaid lapses (handled here).
  @lifecycle_event_types ~w(
    invoice.payment_failed
    invoice.paid
    customer.subscription.deleted
    customer.subscription.updated
  )

  @doc "The webhook event types that mark a subscription active. For the router/tests."
  @spec activating_event_types() :: [String.t()]
  def activating_event_types, do: @activating_event_types

  @doc "The webhook event types that drive the lifecycle past `active`. For tests."
  @spec lifecycle_event_types() :: [String.t()]
  def lifecycle_event_types, do: @lifecycle_event_types

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

  # Dispatch a verified event. An ACTIVATING event in its active state reads the
  # SIGNED metadata and subscribes; a LIFECYCLE event drives the state machine
  # past `active` keyed on the gateway customer id. A `customer.subscription.updated`
  # is checked against the activating path FIRST (active-flip wins); if it's not
  # an active flip it falls through to the lifecycle path (which owns the
  # canceled/unpaid transitions).
  defp activate_from_event(%{"type" => type} = event) do
    object = get_in(event, ["data", "object"]) || %{}

    cond do
      # customer.subscription.updated is dual-purpose (it can be an active-flip
      # OR a canceled/recovery transition), so it gets its own resolver that
      # disambiguates on the customer's CURRENT live row.
      type == "customer.subscription.updated" ->
        handle_subscription_updated(event, object)

      type in @activating_event_types and active_status?(type, object) ->
        activate_from_metadata(object)

      type in @lifecycle_event_types ->
        handle_lifecycle(event)

      true ->
        {:ok, :ignored}
    end
  end

  defp activate_from_event(%{}), do: {:ok, :ignored}

  # Resolve a customer.subscription.updated against the customer's current live
  # row: a canceled/unpaid status lapses it; an active status RECOVERS a past_due
  # row, no-ops an already-active one, or (no live row + signed metadata) lands a
  # fresh activation (the active-flip-from-new case). Anything else is ignored.
  defp handle_subscription_updated(event, object) do
    cus = customer_id(event)

    case Map.get(object, "status") do
      status when status in ["canceled", "unpaid"] ->
        case subscription_by_customer(cus) do
          %Subscription{} = sub -> cancel_subscription(sub)
          _ -> {:ok, :ignored}
        end

      "active" ->
        case subscription_by_customer(cus) do
          %Subscription{status: "past_due"} = sub -> recover_subscription(sub)
          %Subscription{status: "active"} -> {:ok, :ignored}
          _ -> activate_from_metadata(object)
        end

      _ ->
        {:ok, :ignored}
    end
  end

  # Read team_id+plan from the SIGNED metadata and subscribe (idempotently).
  defp activate_from_metadata(object) do
    metadata = Map.get(object, "metadata", %{})
    team_id = metadata["team_id"]
    plan = metadata["plan"]

    if is_binary(team_id) and is_binary(plan) do
      activate_subscription(team_id, plan)
    else
      {:error, :missing_metadata}
    end
  end

  # checkout.session.completed needs no status check (completion IS the signal);
  # a customer.subscription.* event only activates when its status is "active".
  defp active_status?("checkout.session.completed", _object), do: true
  defp active_status?(_type, object), do: Map.get(object, "status") == "active"

  # ── Lifecycle dispatch (keyed on gateway_customer_id) ──

  # invoice.payment_failed → dunning. Coolify-anchor:
  # SubscriptionInvoiceFailedJob + the stripe_past_due flag.
  defp handle_lifecycle(%{"type" => "invoice.payment_failed"} = event) do
    case subscription_by_customer(customer_id(event)) do
      # The Invoice object carries no period end (that's on the Subscription), so
      # let mark_past_due anchor the grace window itself — deterministic, not
      # payload-shaped.
      %Subscription{} = sub -> mark_past_due(sub)
      _ -> {:ok, :ignored}
    end
  end

  # customer.subscription.deleted → end of life. Coolify-anchor:
  # Team::subscriptionEnded(). Idempotent: a replay finds no LIVE sub (the row is
  # already `canceled`, excluded from the live lookup) → {:ok, :ignored}.
  defp handle_lifecycle(%{"type" => "customer.subscription.deleted"} = event) do
    case subscription_by_customer(customer_id(event)) do
      %Subscription{} = sub -> cancel_subscription(sub)
      _ -> {:ok, :ignored}
    end
  end

  # invoice.paid → recovery (clears past_due, resumes suspended boxes).
  # (customer.subscription.updated is resolved upstream by
  # handle_subscription_updated/2, so it never reaches here.)
  defp handle_lifecycle(%{"type" => "invoice.paid"} = event), do: recover_or_ignore(event)

  defp handle_lifecycle(_), do: {:ok, :ignored}

  # Recover only a sub that is actually in dunning; an already-active (or absent)
  # sub is a no-op so a duplicate invoice.paid never double-resumes.
  defp recover_or_ignore(event) do
    case subscription_by_customer(customer_id(event)) do
      %Subscription{status: "past_due"} = sub -> recover_subscription(sub)
      _ -> {:ok, :ignored}
    end
  end

  # ── Status transitions (the public lifecycle API) ──

  @doc """
  Mark `sub` past-due (a payment failed). Sets `status: "past_due"` +
  `past_due: true`, and anchors the grace window: `attrs` MAY carry an explicit
  `current_period_end`, but when it doesn't (the real `invoice.payment_failed`
  Invoice object has no period end — only the Subscription object does) we anchor
  grace at `now + #{@grace_days}d` so a past_due team is NOT entitled forever. A
  past_due sub is STILL entitled within grace (Coolify keeps a past_due team
  running and emails admins) — `maybe_enforce/1` only suspends the team's managed
  boxes once the grace window has elapsed.
  """
  @spec mark_past_due(Subscription.t(), map()) :: {:ok, Subscription.t()} | {:error, term}
  def mark_past_due(%Subscription{} = sub, attrs \\ %{}) do
    attrs = Map.put_new_lazy(attrs, :current_period_end, &default_grace_anchor/0)

    with {:ok, sub} <- update_status(sub, Map.merge(%{status: "past_due", past_due: true}, attrs)) do
      _ = maybe_enforce(sub)
      {:ok, sub}
    end
  end

  # A fixed grace anchor `@grace_days` in the future — deterministic and
  # independent of the webhook payload shape (the Invoice carries no period end).
  defp default_grace_anchor do
    DateTime.utc_now() |> DateTime.add(@grace_days, :day) |> DateTime.truncate(:microsecond)
  end

  @doc """
  Cancel `sub` — terminal. Sets `status: "canceled"` + `canceled_at`, and
  SUSPENDS every managed Barkpark the team owns (the teeth — Coolify-anchor:
  Team::subscriptionEnded()). The row is retained (data retained, access
  revoked); re-subscribing later inserts a fresh `active` row.
  """
  @spec cancel_subscription(Subscription.t()) :: {:ok, Subscription.t()} | {:error, term}
  def cancel_subscription(%Subscription{} = sub) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    with {:ok, sub} <-
           update_status(sub, %{status: "canceled", canceled_at: now, past_due: false}) do
      {:ok, _count} = Registry.suspend_team_barkparks(sub.team_id, "billing_lapsed")
      {:ok, sub}
    end
  end

  @doc """
  Recover `sub` from dunning back to `active` (a failed invoice was paid). Clears
  `past_due` and RESUMES the team's suspended Barkparks.
  """
  @spec recover_subscription(Subscription.t()) :: {:ok, Subscription.t()} | {:error, term}
  def recover_subscription(%Subscription{} = sub) do
    with {:ok, sub} <-
           update_status(sub, %{status: "active", past_due: false, canceled_at: nil}) do
      {:ok, _count} = Registry.resume_team_barkparks(sub.team_id)
      {:ok, sub}
    end
  end

  # past_due is entitled while inside the grace window; past it (or with no known
  # period end set explicitly in the past) the team's managed boxes are
  # suspended with the softer "billing_past_due" reason. The nightly reconcile
  # sweep (deferred, §6) is the belt-and-braces for a grace that elapses with no
  # further webhook.
  defp maybe_enforce(%Subscription{status: "past_due", current_period_end: pe, team_id: tid}) do
    if is_nil(pe) or DateTime.compare(pe, DateTime.utc_now()) == :gt do
      :ok
    else
      {:ok, _count} = Registry.suspend_team_barkparks(tid, "billing_past_due")
      :ok
    end
  end

  defp maybe_enforce(_sub), do: :ok

  defp update_status(%Subscription{} = sub, attrs) do
    sub |> Subscription.changeset(attrs) |> Repo.update()
  end

  # ── Self-serve management ──

  @doc """
  Open a Stripe Customer Portal session for `team`'s live subscription so the
  customer self-manages (update card, view invoices, cancel) in a browser.
  Returns `{:ok, portal_url}` or `{:error, :no_subscription}` when the team has
  none. `opts` may carry a `:return_url`.
  """
  @spec billing_portal_url(Team.t() | binary(), keyword()) ::
          {:ok, String.t()} | {:error, :no_subscription | term}
  def billing_portal_url(team, opts \\ []) do
    case live_subscription(team) do
      %Subscription{gateway_customer_id: cus} when is_binary(cus) ->
        gateway().create_billing_portal_session(cus, opts)

      _ ->
        {:error, :no_subscription}
    end
  end

  @doc """
  Customer-initiated cancellation of `team`'s live subscription. `at_period_end?`
  true (the default) schedules cancel-at-period-end through the gateway and marks
  the row `cancel_at_period_end: true` — the team STAYS entitled until Stripe
  later posts `customer.subscription.deleted` (which ends it via the lifecycle
  path). `false` cancels immediately at the gateway AND locally
  (`cancel_subscription/1` → suspend). Returns `{:ok, %Subscription{}}` or
  `{:error, :no_subscription | term}`.
  """
  @spec request_cancel(Team.t() | binary(), boolean()) ::
          {:ok, Subscription.t()} | {:error, :no_subscription | term}
  def request_cancel(team, at_period_end? \\ true) do
    case live_subscription(team) do
      %Subscription{gateway_subscription_id: sid} = sub when is_binary(sid) ->
        with {:ok, _gw} <- gateway().cancel_subscription(sid, at_period_end: at_period_end?) do
          if at_period_end? do
            update_status(sub, %{cancel_at_period_end: true})
          else
            cancel_subscription(sub)
          end
        end

      _ ->
        {:error, :no_subscription}
    end
  end

  @doc """
  Idempotently mark `team_id`'s subscription on `plan` active. Dedupes on the
  team's LIVE row (active OR past_due), mirroring `handle_subscription_updated/2`:

    * an `active` live row → no-op (`{:ok, :already_active}`).
    * a `past_due` live row → RECOVER it (a fresh Checkout during dunning is a
      successful payment) — NOT a second INSERT, which would collide with the
      one-LIVE-per-team unique index and 400 the webhook (Stripe then retries for
      ~3 days and the recovery payment never reflects).
    * no live row → subscribe (the full gateway customer→subscription→persist flow).

  Used by `handle_webhook/2`; the team id and plan come from a SIGNED event,
  never a client.
  """
  @spec activate_subscription(binary(), String.t()) ::
          {:ok, Subscription.t() | :already_active} | {:error, term}
  def activate_subscription(team_id, plan) when is_binary(team_id) and is_binary(plan) do
    case live_subscription(team_id) do
      %Subscription{status: "active"} ->
        {:ok, :already_active}

      %Subscription{status: "past_due"} = sub ->
        recover_subscription(sub)

      nil ->
        subscribe(team_id, plan)
    end
  end

  @doc """
  Grant a Team a FOREVER comp licence — an admin override that bypasses billing.

  Writes (or converts an existing live sub into) an `active` `forever`
  subscription row carrying NO gateway ids, so the Stripe lifecycle webhooks
  (keyed on customer id) can never lapse it and `entitled?/1` stays true
  indefinitely. Idempotent: a team already on `forever` returns
  `{:ok, :already_forever}`.

  NOT reachable from any client path — granted only by
  `mix barkpark_cloud.grant_forever` or an operator IEx session.

  Caveat: if the team had a REAL paid Stripe subscription, converting it here
  detaches our row only — the operator must cancel the Stripe-side subscription
  separately so the customer is no longer charged.
  """
  @spec grant_forever(Team.t() | binary()) ::
          {:ok, Subscription.t() | :already_forever} | {:error, term}
  def grant_forever(team) do
    tid = team_id(team)

    case live_subscription(tid) do
      %Subscription{plan: "forever"} ->
        {:ok, :already_forever}

      %Subscription{} = sub ->
        # An existing live sub (free or paid) is converted to the comp tier —
        # admin override wins. Gateway ids are cleared so no Stripe event lapses it.
        sub
        |> Subscription.changeset(%{
          plan: "forever",
          status: "active",
          gateway_customer_id: nil,
          gateway_subscription_id: nil,
          past_due: false,
          cancel_at_period_end: false,
          canceled_at: nil,
          current_period_end: nil
        })
        |> Repo.update()

      nil ->
        %Subscription{}
        |> Subscription.changeset(%{team_id: tid, plan: "forever", status: "active"})
        |> Repo.insert()
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

  @doc """
  A Team's LIVE subscription — `active` OR `past_due`, or nil. The
  one-live-per-team partial unique index guarantees at most one. This is the row
  the lifecycle webhooks and the self-serve surface operate on.
  """
  @spec live_subscription(Team.t() | binary()) :: Subscription.t() | nil
  def live_subscription(team) do
    tid = team_id(team)

    Subscription
    |> where([s], s.team_id == ^tid and s.status in ["active", "past_due"])
    |> Repo.one()
  end

  @doc """
  Is `team` entitled to managed resources right now? True for an `active`
  subscription, and for a `past_due` one still inside its grace window
  (`current_period_end` in the future, or unset). False otherwise — no live sub,
  or past_due past grace. The launch gate reads this instead of the old binary
  active-subscription check, so a paying customer in a transient dunning window
  is not locked out (Coolify-anchor: isSubscriptionActive() stays true through
  stripe_past_due).
  """
  @spec entitled?(Team.t() | binary()) :: boolean()
  def entitled?(team) do
    case live_subscription(team) do
      # An admin `forever` comp is always entitled, by definition.
      %Subscription{plan: "forever"} ->
        true

      %Subscription{status: "active"} ->
        true

      %Subscription{status: "past_due", current_period_end: pe} ->
        is_nil(pe) or DateTime.compare(pe, DateTime.utc_now()) == :gt

      _ ->
        false
    end
  end

  ## Helpers

  defp team_id(%Team{id: id}), do: id
  defp team_id(id) when is_binary(id), do: id

  # The gateway customer id off a Stripe event object.
  defp customer_id(event), do: get_in(event, ["data", "object", "customer"])

  # The LIVE subscription for a gateway customer id (active OR past_due). nil for
  # a non-binary id (an event with no customer) or a customer with only a
  # terminal/absent row — both route the lifecycle clause to {:ok, :ignored}.
  defp subscription_by_customer(cus) when is_binary(cus) do
    Subscription
    |> where([s], s.gateway_customer_id == ^cus and s.status in ["active", "past_due"])
    |> Repo.one()
  end

  defp subscription_by_customer(_), do: nil
end
