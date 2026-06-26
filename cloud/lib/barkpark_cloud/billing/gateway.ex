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
    * `charge/4`              — one-off charge of `amount_cents` in `currency`
      (the pay-once go-live charge); returns a charge id.
    * `create_subscription/2` — open a recurring subscription on a `plan`;
      returns a subscription id.
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
  Verify an inbound webhook `payload` against its `signature`. Returns
  `{:ok, event}` (the decoded event term) on a valid signature, `{:error, term}`
  otherwise. Verification only — no event dispatch.
  """
  @callback verify_webhook(payload :: binary(), signature :: binary()) ::
              {:ok, event :: term} | {:error, term}
end
