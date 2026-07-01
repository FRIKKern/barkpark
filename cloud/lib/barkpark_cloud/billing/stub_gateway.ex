defmodule BarkparkCloud.Billing.StubGateway do
  @moduledoc """
  The in-memory `BarkparkCloud.Billing.Gateway` — the default in dev/test. No
  network, no card vault, €0 spend. Every id it returns is DETERMINISTIC: the
  same inputs always produce the same `cus_stub_…` / `ch_stub_…` / `sub_stub_…`
  id, so tests assert exact ids and the whole pay-once go-live path is
  reproducible.

  Determinism comes from hashing the inputs (SHA-256, truncated hex) rather than
  from any stored state — the "in-memory" store is therefore stateless and
  process-free: there is nothing to start, nothing to reset between tests. This
  is the same `hash_token/1`-style discipline as `Registry.AgentToken`, applied
  to fake payment ids.

  `verify_webhook/2` accepts exactly one fixed signature (`@test_signature`) and
  rejects everything else, so a webhook-verify test has a known-good and a
  known-bad case without any signing secret.
  """
  @behaviour BarkparkCloud.Billing.Gateway

  # The single signature `verify_webhook/2` accepts. A fixed, well-known value —
  # there is no signing secret in the stub. `expose`d via `test_signature/0` so
  # tests reference the constant instead of copy-pasting the literal.
  @test_signature "stub_sig_ok"

  @doc "The fixed signature `verify_webhook/2` accepts. For tests."
  @spec test_signature() :: String.t()
  def test_signature, do: @test_signature

  @impl true
  def create_customer(attrs) when is_map(attrs) do
    {:ok, "cus_stub_" <> digest(attrs)}
  end

  @impl true
  def update_customer(customer_id, attrs) when is_binary(customer_id) and is_map(attrs) do
    # No network, no stored state — echo the id back so the inline email-sync
    # path runs end to end in tests at €0. Stripe returns the same customer id on
    # an update; `attrs` is accepted for shape parity.
    {:ok, customer_id}
  end

  @impl true
  def charge(customer_id, amount_cents, currency, meta)
      when is_binary(customer_id) and is_integer(amount_cents) and amount_cents > 0 and
             is_binary(currency) and is_map(meta) do
    {:ok, "ch_stub_" <> digest({customer_id, amount_cents, currency, meta})}
  end

  @impl true
  def create_subscription(customer_id, plan) when is_binary(customer_id) do
    {:ok, "sub_stub_" <> digest({customer_id, to_string(plan)})}
  end

  @impl true
  def create_checkout_session(team_id, plan, opts \\ [])
      when is_binary(team_id) and is_list(opts) do
    # Deterministic fake checkout url: the SHA-256 of team_id<>plan, hex. The
    # same team+plan always yields the same url, so a test asserts the exact
    # value without any network or signing secret. `opts` (price_id, urls) is
    # accepted for behaviour-shape parity with StripeGateway but unused here.
    sha =
      :crypto.hash(:sha256, team_id <> to_string(plan))
      |> Base.encode16(case: :lower)

    {:ok, "https://checkout.stub/" <> sha}
  end

  @impl true
  def create_billing_portal_session(customer_id, opts \\ []) when is_binary(customer_id) do
    # Deterministic fake portal url: the SHA-256 digest of the customer id. Same
    # customer always yields the same url, so a test asserts the exact value
    # without any network. `opts` (return_url) is accepted for behaviour-shape
    # parity with StripeGateway but unused here.
    _ = opts
    {:ok, "https://portal.stub/" <> digest(customer_id)}
  end

  @impl true
  def cancel_subscription(subscription_id, opts \\ []) when is_binary(subscription_id) do
    # Mirror the gateway's returned-sub-map shape: the id, a canceled status, and
    # the cancel_at_period_end flag the caller asked for. Deterministic, no
    # network — the context only inspects {:ok, _}, so the map is for shape
    # parity / test assertions.
    {:ok,
     %{
       "id" => subscription_id,
       "status" => "canceled",
       "cancel_at_period_end" => Keyword.get(opts, :at_period_end, true)
     }}
  end

  @impl true
  def verify_webhook(payload, signature) when is_binary(payload) and is_binary(signature) do
    if signature == @test_signature do
      {:ok, %{"verified" => true, "payload" => payload}}
    else
      {:error, :invalid_signature}
    end
  end

  # Deterministic short hex digest of any term — the source of the stable ids.
  defp digest(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end
end
