defmodule BarkparkCloud.Billing.Gateway do
  @moduledoc """
  The payments SEAM. Every billing side effect — creating a customer, charging
  it, opening a subscription, verifying an inbound webhook — goes through this
  behaviour, so the `BarkparkCloud.Billing` context never names a payment
  provider directly. The concrete gateway is selected from config
  (`Billing.gateway/0`), mirroring how `Registry.Vault`'s key source is config-
  selected: `StubGateway` in dev/test (in-memory, deterministic, €0), the Stripe
  skeleton in prod once a human wires live keys (cloud-17).

  This is what lets the entire pay-once go-live path be built and tested at €0
  spend: tests run the whole `create_customer → charge → create_subscription`
  flow through `StubGateway`, and the `StripeGateway` request shape is asserted
  without a network call ever leaving the box.

  ## Callbacks

    * `create_customer/1`     — register a billing customer; returns its id.
    * `update_customer/2`     — patch a customer (e.g. sync its email after a
      verified email change); returns its id.
    * `charge/4`              — one-off charge of `amount_cents` in `currency`
      (the pay-once go-live charge); returns a charge id.
    * `create_subscription/2` — open a recurring subscription on a `plan`;
      returns a subscription id.
    * `create_checkout_session/3` — open a hosted Checkout Session for a team to
      pay for `plan` in a browser; returns the URL the customer opens. This is
      the customer-initiated subscription path (the browser pays), as distinct
      from `charge/4`'s server-initiated one-off charge.
    * `create_billing_portal_session/2` — open a Stripe Customer Portal session
      so the customer self-manages their subscription (update card, view
      invoices, cancel) in a browser; returns the portal URL. Coolify-anchor:
      `getStripeCustomerPortalSession` (`bootstrap/helpers/subscriptions.php`).
    * `cancel_subscription/2`  — cancel a subscription, either at period end
      (reversible grace) or immediately. Returns the gateway's updated sub map.
      Coolify-anchor: `app/Actions/Subscriptions/CancelSubscription.php`.
    * `verify_webhook/2`      — verify an inbound webhook's signature and return
      the decoded event. Verify ONLY — event handling/dispatch is out of scope
      (YAGNI).

  Every callback returns an `{:ok, _} | {:error, term}` tuple so call sites
  pattern-match instead of rescuing.
  """

  @typedoc "Opaque gateway-side customer reference (e.g. `cus_…`)."
  @type customer_id :: String.t()

  @typedoc "Opaque gateway-side charge reference (e.g. `ch_…`)."
  @type charge_id :: String.t()

  @typedoc "Opaque gateway-side subscription reference (e.g. `sub_…`)."
  @type subscription_id :: String.t()

  @typedoc "The browser URL a customer opens to complete a hosted checkout."
  @type checkout_url :: String.t()

  @typedoc "Opaque gateway-side team reference (the control plane's team id)."
  @type team_id :: String.t()

  @typedoc "An ISO-4217 currency code, lower- or upper-case (e.g. `\"eur\"`)."
  @type currency :: String.t()

  @typedoc "Free-form metadata attached to a charge (line item, team id, …)."
  @type meta :: map()

  @typedoc "A subscription plan tier (see `Subscription.plans/0`)."
  @type plan :: String.t() | atom()

  @doc "Create a billing customer from `attrs`. Returns its gateway id."
  @callback create_customer(attrs :: map()) ::
              {:ok, customer_id} | {:error, term}

  @doc """
  Update an existing billing customer's attributes (currently `:email` only —
  keeps the gateway's customer record in sync after a verified email change).
  Returns the customer id on success. Called inline + fail-soft (no job runner in
  `cloud/`): a sync error is logged, never rolls back the committed email change.
  """
  @callback update_customer(customer_id :: customer_id, attrs :: map()) ::
              {:ok, customer_id} | {:error, term}

  @doc """
  Charge `customer_id` `amount_cents` (a positive integer of minor units) in
  `currency`, tagging the charge with `meta`. Returns the gateway charge id.
  This is the pay-once go-live charge.
  """
  @callback charge(
              customer_id :: customer_id,
              amount_cents :: pos_integer(),
              currency :: currency,
              meta :: meta
            ) :: {:ok, charge_id} | {:error, term}

  @doc "Open a recurring subscription for `customer_id` on `plan`. Returns the sub id."
  @callback create_subscription(customer_id :: customer_id, plan :: plan) ::
              {:ok, subscription_id} | {:error, term}

  @doc """
  Open a hosted Checkout Session so a team can pay for `plan` in a browser. The
  caller passes the control plane's `team_id` (the AUTHED team — never a
  client-supplied value) and `plan`; `opts` carries the resolved gateway-side
  `price_id` plus the `success_url` / `cancel_url`. Returns the `checkout_url`
  the customer opens. The `team_id` and `plan` are stamped into the session's
  metadata so the inbound webhook can read them back from a Stripe-signed event.
  """
  @callback create_checkout_session(team_id :: team_id, plan :: plan, opts :: keyword()) ::
              {:ok, checkout_url} | {:error, term}

  @typedoc "The browser URL a customer opens to self-manage their subscription."
  @type portal_url :: String.t()

  @doc """
  Open a Stripe Customer Portal session for `customer_id` (the gateway-side
  customer reference) so the customer can self-manage their subscription in a
  browser. `opts` may carry a `:return_url` the portal sends the customer back
  to. Returns `{:ok, portal_url}` — the URL the customer opens.
  """
  @callback create_billing_portal_session(customer_id :: customer_id, opts :: keyword()) ::
              {:ok, portal_url} | {:error, term}

  @doc """
  Cancel `subscription_id`. `opts[:at_period_end]` true (the default) schedules
  the cancel at the current period end (reversible grace — the subscription
  stays live until Stripe later posts `customer.subscription.deleted`); false
  cancels immediately. Returns the gateway's updated subscription map.
  """
  @callback cancel_subscription(subscription_id :: subscription_id, opts :: keyword()) ::
              {:ok, map()} | {:error, term}

  @doc """
  Verify an inbound webhook `payload` against its `signature`. Returns
  `{:ok, event}` (the decoded event term) on a valid signature, `{:error, term}`
  otherwise. Verification only — no event dispatch.
  """
  @callback verify_webhook(payload :: binary(), signature :: binary()) ::
              {:ok, event :: term} | {:error, term}
end
