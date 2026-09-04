defmodule BarkparkCloud.Billing.StripeGateway do
  @moduledoc """
  The Stripe `BarkparkCloud.Billing.Gateway`. It builds the REAL Stripe
  API request shape — method, `https://api.stripe.com/v1/...` url, Bearer auth
  header, and `application/x-www-form-urlencoded` body — and the live HTTP
  transport is wired in prod (`BarkparkCloud.Billing.HttpClient`, #281).

  ## HUMAN task cloud-17 — live keys + price/plan ids

  This gateway is selected in prod (when `STRIPE_SECRET_KEY` is set), but the
  pieces only a human should touch are deliberately deferred to **cloud-17**:

    * the LIVE `STRIPE_SECRET_KEY` (a test key works against the same shape);
    * the per-plan Stripe PRICE ids — `create_subscription/2` resolves the
      plan→`price_…` id through `Billing.price_id/1` (the `STRIPE_PRICE_*` config
      seam) and fails closed on an unpriced plan, so it can NEVER send a plan
      name as the price (BILL-3). Wiring the real `price_…` ids for each paid
      tier (`supporter`/`support_plus`) remains the human task cloud-17.

  Until then this module is exercised only through its pure request-builder
  (`build_request/3`), which tests assert; the live HTTP call is NEVER made in
  the test suite.

  ## Pinned API version — `2025-02-24.acacia`

  Every request `build_request/3` builds carries `Stripe-Version:
  2025-02-24.acacia` (the `@api_version` attribute, echoed by `api_version/0`).
  Before cch-w57-bl it sent exactly two headers and NO
  `Stripe-Version`, so both the API response shape AND — because Stripe versions
  webhook payloads off the same account default — the WEBHOOK payload shape were
  whatever the Stripe DASHBOARD happened to be set to. That is a decision made
  outside this repo, changeable by anyone with dashboard access, that silently
  reshapes the objects `Billing.handle_webhook/2` destructures. Pinning it makes
  the shape a decision this tree makes.

  ### Why this version, field by field

  The webhook path reads exactly five things off an event, and this pin is the
  newest version on which ALL FIVE are where the code looks:

    * `type` — envelope, version-invariant.
    * `data.object.customer` (Invoice, Checkout Session, Subscription) — a
      top-level id on all three objects in `acacia`.
    * `data.object.status` (Subscription) — top level.
    * `data.object.cancel_at_period_end` (Subscription) — top level; the ONLY
      Subscription field the tree lifts (`Billing.sync_cancel_flag/2`).
    * `data.object.subscription` + `data.object.metadata` (Checkout Session) —
      top level.

  `2025-03-31.basil` is deliberately NOT the pin: it MOVES `current_period_end`
  off the Subscription object onto its items, and reparents the Invoice's
  subscription reference under `parent.subscription_details`. This tree refuses
  to read `current_period_end` off any payload at all (charter D672 / cch-w57-bl
  — the grace anchor is now its own `grace_ends_at` column), so the first of
  those costs it nothing today; the pin is what guarantees the SECOND one cannot
  arrive as a dashboard flip. Moving the pin forward is a deliberate change with
  a re-derivation of the five fields above, which is the point.

  Nothing here reads the version at runtime to branch on it — it is an assertion
  about the wire shape, not a feature switch.

  ## Webhook verification — IMPLEMENTED (real Stripe v1 scheme)

  `verify_webhook/2` is NOT a skeleton: it implements Stripe's documented
  signature scheme exactly — parse the `Stripe-Signature` header (`t=<ts>` +
  one-or-more `v1=<hex>`), recompute `HMAC-SHA256(secret, "<t>.<payload>")`,
  hex-encode it, and constant-time-compare against the `v1` values, with a
  ±300s replay window (`@signature_tolerance_seconds`). The verification
  ALGORITHM is deterministic and fully tested against a TEST secret. The only
  HUMAN piece is the LIVE `STRIPE_WEBHOOK_SECRET` (the `whsec_…` signing secret,
  distinct from the API key), supplied at Gate 4 / cloud-17; with it unset the
  function fails closed (`{:error, :no_secret}`).

  ## Injectable HTTP client — no new dep, €0 in tests

  Rather than pull an HTTP library into the tree, the transport is INJECTED. The
  `request/2` helper resolves a 1-arity client function from config
  (`config :barkpark_cloud, #{inspect(__MODULE__)}, http_client: &mod.fun/1`)
  and calls it with the `%{method, url, headers, body}` request map. In prod the
  client is `BarkparkCloud.Billing.HttpClient` (Erlang `:httpc` with verified TLS,
  wired in `runtime.exs`, #281); in dev/test there is no client configured and any
  callback that would hit the wire returns `{:error, :http_client_not_configured}`
  — so tests can't silently spend money. Tests assert `build_request/3`'s output directly and never call
  `request/2`.
  """
  @behaviour BarkparkCloud.Billing.Gateway

  require Logger

  @api_base "https://api.stripe.com/v1"

  # The PINNED Stripe API version. See the moduledoc section "Pinned API version"
  # for why this exact string and what depends on it. Sent as `Stripe-Version` on
  # every request `build_request/3` builds, and asserted by
  # `stripe_gateway_test.exs` so a silent edit reds.
  @api_version "2025-02-24.acacia"

  # Replay-protection window for webhook signatures: reject an event whose
  # `t=<timestamp>` is more than this many seconds away from now (in either
  # direction). 300s is Stripe's documented default tolerance.
  @signature_tolerance_seconds 300

  @impl true
  def create_customer(attrs) when is_map(attrs) do
    "/customers"
    |> build_request(:post, customer_params(attrs))
    |> request(:id)
  end

  @impl true
  def update_customer(customer_id, attrs) when is_binary(customer_id) and is_map(attrs) do
    # POST /v1/customers/{id} with the changed fields — Stripe's customer-update
    # shape. Narrow on purpose: only the email is synced (after a verified email
    # change). The pure builder is the assertion seam; request/2 never fires in
    # tests.
    "/customers/#{customer_id}"
    |> build_request(:post, customer_params(attrs))
    |> request(:id)
  end

  @impl true
  def charge(customer_id, amount_cents, currency, meta)
      when is_binary(customer_id) and is_integer(amount_cents) and amount_cents > 0 and
             is_binary(currency) and is_map(meta) do
    params =
      %{
        "amount" => amount_cents,
        "currency" => String.downcase(currency),
        "customer" => customer_id,
        # off_session: this is a server-initiated pay-once charge, not a
        # browser checkout — mirrors how the go-live charge actually fires.
        "off_session" => true,
        "confirm" => true
      }
      |> merge_metadata(meta)

    "/payment_intents"
    |> build_request(:post, params)
    |> request(:id)
  end

  @impl true
  def create_subscription(customer_id, plan) when is_binary(customer_id) do
    # BILL-3: a real Stripe subscription takes a `price_…` id, NEVER a plan name.
    # Resolve plan→price through the SAME config seam the checkout path uses
    # (`Billing.price_id/1`, the per-plan `STRIPE_PRICE_*` map). This closes the
    # bug where the plan name (e.g. "supporter") was POSTed as the price and
    # Stripe rejected it: an unpriced/unknown plan now fails closed here rather
    # than ever sending a plan name as a price.
    case BarkparkCloud.Billing.price_id(to_string(plan)) do
      price_id when is_binary(price_id) ->
        params = %{
          "customer" => customer_id,
          "items[0][price]" => price_id
        }

        "/subscriptions"
        |> build_request(:post, params)
        |> request(:id)

      _ ->
        {:error, :plan_invalid}
    end
  end

  @impl true
  def create_checkout_session(team_id, plan, opts \\ [])
      when is_binary(team_id) and is_list(opts) do
    # The REAL Stripe Checkout Session request shape: POST /v1/checkout/sessions,
    # mode=subscription, a single line item on the resolved price, success/cancel
    # urls, and the team_id+plan stamped into metadata. The price id is the
    # gateway-side `price_…` resolved by the context from config (cloud-17 wires
    # the real ids); we send it as `line_items[0][price]`.
    price_id = Keyword.get(opts, :price_id)
    # Return to the dashboard SPA root (served at /) with a ?checkout= flag — the
    # SPA is hash-routed so a query on / lands cleanly (the old /billing/success
    # path had no route and 404'd a paying customer; see #282). Config-driven so
    # a non-prod deploy returns to ITS OWN host, not always prod.
    success_url = Keyword.get(opts, :success_url, default_success_url())
    cancel_url = Keyword.get(opts, :cancel_url, default_cancel_url())

    params =
      %{
        "mode" => "subscription",
        "line_items[0][price]" => to_string(price_id),
        "line_items[0][quantity]" => 1,
        "success_url" => success_url,
        "cancel_url" => cancel_url,
        # team_id+plan ride in metadata so the inbound webhook reads them back
        # from a Stripe-SIGNED event — never trusting attacker-supplied input.
        "metadata[team_id]" => team_id,
        "metadata[plan]" => to_string(plan)
      }

    "/checkout/sessions"
    |> build_request(:post, params)
    |> request(:url)
  end

  @impl true
  def create_billing_portal_session(customer_id, opts \\ []) when is_binary(customer_id) do
    # The REAL Stripe Customer Portal request shape: POST /v1/billing_portal/sessions
    # with the customer + a return_url. Stripe responds with a `url` the customer
    # opens to self-manage (update card, view invoices, cancel). Config-driven
    # return url so a non-prod deploy returns to ITS OWN host (same pattern as
    # the Checkout success/cancel urls).
    params = %{
      "customer" => customer_id,
      "return_url" => Keyword.get(opts, :return_url, default_portal_return_url())
    }

    "/billing_portal/sessions"
    |> build_request(:post, params)
    |> request(:url)
  end

  @impl true
  def cancel_subscription(subscription_id, opts \\ []) when is_binary(subscription_id) do
    if Keyword.get(opts, :at_period_end, true) do
      # Reversible grace: POST /v1/subscriptions/:id with cancel_at_period_end=true.
      # The subscription stays live until the period end; Stripe posts
      # customer.subscription.deleted when it actually lapses.
      "/subscriptions/#{subscription_id}"
      |> build_request(:post, %{"cancel_at_period_end" => true})
      |> request(:id)
    else
      # Immediate: DELETE /v1/subscriptions/:id.
      "/subscriptions/#{subscription_id}"
      |> build_request(:delete, %{})
      |> request(:id)
    end
  end

  @impl true
  def verify_webhook(payload, signature_header)
      when is_binary(payload) and is_binary(signature_header) do
    # Stripe signs webhooks with the endpoint's signing secret (`whsec_…`), a
    # SEPARATE secret from the API key, set by a human at Gate 4 / cloud-17.
    # Without it there is nothing to verify against — fail closed rather than
    # trust. The verification ALGORITHM below is Stripe's documented v1 scheme,
    # fully implemented and tested against a TEST secret.
    case webhook_secret() do
      secret when is_binary(secret) and secret != "" ->
        verify_signature(payload, signature_header, secret)

      _ ->
        {:error, :no_secret}
    end
  end

  @doc """
  Pure builder for a Stripe API request — NO network. Returns a request map:

      %{
        method:  :post,
        url:     "https://api.stripe.com/v1/customers",
        headers: [
          {"Authorization", "Bearer sk_…"},
          {"Content-Type", "…"},
          {"Stripe-Version", "2025-02-24.acacia"}
        ],
        body:    "email=a%40b.com&name=Acme"   # URL-encoded form
      }

  This is the assertion seam: tests check the method / url / auth header / encoded
  body without anything leaving the box. `path` is appended to the Stripe API
  base; `params` is form-encoded (Stripe's API is form-encoded, not JSON).
  """
  @doc """
  The pinned Stripe API version this gateway sends on every request. Public so a
  test can assert the SHIPPED constant rather than a re-typed copy of it.
  """
  @spec api_version() :: String.t()
  def api_version, do: @api_version

  @spec build_request(String.t(), :get | :post | :delete, map()) :: %{
          method: :get | :post | :delete,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: String.t()
        }
  def build_request(path, method, params) when is_binary(path) and is_map(params) do
    %{
      method: method,
      url: @api_base <> path,
      headers: [
        {"Authorization", "Bearer " <> secret_key()},
        {"Content-Type", "application/x-www-form-urlencoded"},
        {"Stripe-Version", @api_version}
      ],
      body: encode_form(params)
    }
  end

  ## Internals

  # Map raw customer attrs onto Stripe's customer params. Narrow on purpose —
  # only the fields the go-live path needs.
  defp customer_params(attrs) do
    %{}
    |> maybe_put("email", attrs[:email] || attrs["email"])
    |> maybe_put("name", attrs[:name] || attrs["name"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, to_string(value))

  # Stripe flattens metadata as metadata[key]=value form fields.
  defp merge_metadata(params, meta) do
    Enum.reduce(meta, params, fn {k, v}, acc ->
      Map.put(acc, "metadata[#{k}]", to_string(v))
    end)
  end

  # Stable, sorted, percent-encoded form body so the request shape is
  # deterministic and assertable.
  defp encode_form(params) do
    params
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("&", fn {k, v} ->
      URI.encode_www_form(k) <> "=" <> URI.encode_www_form(to_string(v))
    end)
  end

  # Resolve the injected HTTP client and perform the request, pulling `field`
  # out of the decoded JSON response. NEVER called in tests — there is no client
  # configured in dev/test, so it fails closed instead of spending money. The
  # real client is a human task (cloud-17).
  defp request(req, field) do
    case http_client() do
      fun when is_function(fun, 1) ->
        with {:ok, %{status: status, body: body}} when status in 200..299 <- fun.(req),
             {:ok, %{} = decoded} <- Jason.decode(body),
             %{^field => id} <- atomize_key(decoded, field) do
          {:ok, id}
        else
          {:ok, %{status: status, body: body}} ->
            # Belt: keep the FULL Stripe diagnostic server-side (status + raw
            # body) so operators can debug. The raw body can carry customer/PII
            # internals (cus_… ids, request echoes), so it is redacted before it
            # reaches the client — see `billing_reason/1` at the router. The tuple
            # itself stays intact (http_client_test pins it); redaction is at the
            # router seam only.
            Logger.error("Stripe HTTP #{status} error: #{inspect(body)}")
            {:error, {:stripe_http_error, status, body}}

          {:error, reason} ->
            {:error, reason}

          other ->
            {:error, {:unexpected_stripe_response, other}}
        end

      _ ->
        {:error, :http_client_not_configured}
    end
  end

  defp atomize_key(map, field) when is_atom(field) do
    Map.put(map, field, map[to_string(field)] || map[field])
  end

  # Stripe's documented signature scheme. The `Stripe-Signature` header is a
  # comma-separated list of `k=v` pairs — one `t=<unix-timestamp>` plus one or
  # more `v1=<hex>` HMACs (Stripe sends multiple when rotating signing secrets).
  # The signed payload is the literal string "<t>.<raw-body>"; the expected
  # signature is HMAC-SHA256(secret, that string), lowercase hex. The header is
  # valid iff `expected` constant-time-equals ANY of the v1 values AND the
  # timestamp is within the replay window. Total: any malformed input returns
  # {:error, _} rather than raising — the webhook route stays a clean 400.
  defp verify_signature(payload, signature_header, secret) do
    with {:ok, timestamp, v1_signatures} <- parse_signature_header(signature_header),
         :ok <- check_timestamp(timestamp),
         :ok <- check_signatures(payload, timestamp, v1_signatures, secret) do
      decode_event(payload)
    end
  end

  # Parse "t=123,v1=abc,v1=def" into {:ok, 123, ["abc", "def"]}. A missing/
  # non-integer timestamp or a complete absence of v1 values is a malformed
  # header. Unknown schemes (e.g. the legacy `v0=`) are ignored.
  defp parse_signature_header(header) do
    pairs =
      header
      |> String.split(",")
      |> Enum.flat_map(fn item ->
        case String.split(String.trim(item), "=", parts: 2) do
          [k, v] -> [{k, v}]
          _ -> []
        end
      end)

    timestamp =
      case List.keyfind(pairs, "t", 0) do
        {"t", value} -> parse_integer(value)
        _ -> :error
      end

    v1_signatures = for {"v1", v} <- pairs, do: v

    case {timestamp, v1_signatures} do
      {:error, _} -> {:error, :malformed_header}
      {_t, []} -> {:error, :malformed_header}
      {t, sigs} -> {:ok, t, sigs}
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> :error
    end
  end

  # Replay protection: the event's timestamp must be within the tolerance window
  # of now, in either direction. Uses wall-clock seconds.
  defp check_timestamp(timestamp) do
    now = System.system_time(:second)

    if abs(now - timestamp) <= @signature_tolerance_seconds do
      :ok
    else
      {:error, :timestamp_out_of_tolerance}
    end
  end

  # Recompute the expected HMAC over "<t>.<payload>" and constant-time-compare it
  # against every offered v1 value. Valid iff ANY matches. Never `==` on the hex.
  defp check_signatures(payload, timestamp, v1_signatures, secret) do
    signed_payload = "#{timestamp}.#{payload}"

    expected =
      :crypto.mac(:hmac, :sha256, secret, signed_payload) |> Base.encode16(case: :lower)

    if Enum.any?(v1_signatures, &secure_compare(&1, expected)) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp decode_event(payload) do
    case Jason.decode(payload) do
      {:ok, event} -> {:ok, event}
      {:error, _} -> {:error, :invalid_payload}
    end
  end

  # Constant-time comparison — inlined to avoid pulling in Plug.Crypto for one
  # call. Equal length AND every byte equal, in time independent of where the
  # first mismatch is (no early return on the byte loop).
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and constant_time_equal?(a, b, 0)
  end

  defp constant_time_equal?(<<x, rest_a::binary>>, <<y, rest_b::binary>>, acc) do
    constant_time_equal?(rest_a, rest_b, Bitwise.bor(acc, Bitwise.bxor(x, y)))
  end

  defp constant_time_equal?(<<>>, <<>>, acc), do: acc === 0

  # ── config resolvers (read at call time so runtime.exs overrides win) ──

  defp secret_key do
    config()[:secret_key] ||
      raise """
      #{inspect(__MODULE__)} has no :secret_key. Set STRIPE_SECRET_KEY (wired in
      runtime.exs) — the LIVE key is HUMAN task cloud-17.
      """
  end

  defp webhook_secret, do: config()[:webhook_secret]
  defp http_client, do: config()[:http_client]

  # Stripe Checkout return URLs. The customer is redirected here after paying /
  # cancelling. Read at call time from config so a non-prod deploy returns to ITS
  # OWN domain — a hardcoded prod URL would strand staging/dev customers on the
  # wrong host post-checkout. runtime.exs wires STRIPE_SUCCESS_URL /
  # STRIPE_CANCEL_URL in prod; unset → fall back to the prod domain.
  defp default_success_url,
    do: config()[:success_url] || "https://barkpark.cloud/?checkout=success"

  defp default_cancel_url,
    do: config()[:cancel_url] || "https://barkpark.cloud/?checkout=cancel"

  # Where the Customer Portal sends the customer back to after they're done
  # managing their subscription. Same config-at-call-time + prod-domain-fallback
  # shape as the Checkout return urls; runtime.exs wires STRIPE_PORTAL_RETURN_URL.
  defp default_portal_return_url,
    do: config()[:portal_return_url] || "https://barkpark.cloud/?billing=portal"

  defp config, do: Application.get_env(:barkpark_cloud, __MODULE__, [])
end
