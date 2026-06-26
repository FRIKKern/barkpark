defmodule BarkparkCloud.Billing.StripeGateway do
  @moduledoc """
  The Stripe `BarkparkCloud.Billing.Gateway` SKELETON. It builds the REAL Stripe
  API request shape — method, `https://api.stripe.com/v1/...` url, Bearer auth
  header, and `application/x-www-form-urlencoded` body — but ships before any
  live call is wired.

  ## HUMAN task cloud-17 — live keys + price/plan ids

  This gateway is selected in prod (when `STRIPE_SECRET_KEY` is set), but the
  pieces only a human should touch are deliberately deferred to **cloud-17**:

    * the LIVE `STRIPE_SECRET_KEY` (a test key works against the same shape);
    * the per-plan Stripe PRICE ids — `create_subscription/2` currently sends a
      `plan` placeholder, NOT a real `price_…`. Mapping each roadmap tier
      (`free`/`starter`/`pro`/`business`/`dedicated`) to its Stripe price id is
      part of cloud-17, alongside the actual prices.

  Until then this module is exercised only through its pure request-builder
  (`build_request/3`), which tests assert; the live HTTP call is NEVER made in
  the test suite.

  ## Injectable HTTP client — no new dep, €0 in tests

  Rather than pull an HTTP library into the tree, the transport is INJECTED. The
  `request/2` helper resolves a 1-arity client function from config
  (`config :barkpark_cloud, #{inspect(__MODULE__)}, http_client: &mod.fun/1`)
  and calls it with the `%{method, url, headers, body}` request map. In prod a
  human wires a real client (Finch/Req/:httpc) in cloud-17; in dev/test there is
  no client configured and any callback that would hit the wire returns
  `{:error, :http_client_not_configured}` — so the skeleton can't silently spend
  money. Tests assert `build_request/3`'s output directly and never call
  `request/2`.
  """
  @behaviour BarkparkCloud.Billing.Gateway

  @api_base "https://api.stripe.com/v1"

  @impl true
  def create_customer(attrs) when is_map(attrs) do
    "/customers"
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
    # NOTE (cloud-17): a real Stripe subscription takes a `price_…` id, not a
    # plan name. The plan→price-id mapping is a HUMAN task; here we send the
    # plan placeholder so the request SHAPE is right and tests can assert it.
    params = %{
      "customer" => customer_id,
      "items[0][price]" => to_string(plan)
    }

    "/subscriptions"
    |> build_request(:post, params)
    |> request(:id)
  end

  @impl true
  def verify_webhook(payload, signature) when is_binary(payload) and is_binary(signature) do
    # Stripe signs webhooks with the endpoint's signing secret (`whsec_…`), a
    # SEPARATE secret from the API key, set by a human in cloud-17. Without it
    # there is nothing to verify against — fail closed rather than trust.
    case webhook_secret() do
      secret when is_binary(secret) ->
        verify_signature(payload, signature, secret)

      _ ->
        {:error, :webhook_secret_not_configured}
    end
  end

  @doc """
  Pure builder for a Stripe API request — NO network. Returns a request map:

      %{
        method:  :post,
        url:     "https://api.stripe.com/v1/customers",
        headers: [{"Authorization", "Bearer sk_…"}, {"Content-Type", "…"}],
        body:    "email=a%40b.com&name=Acme"   # URL-encoded form
      }

  This is the assertion seam: tests check the method / url / auth header / encoded
  body without anything leaving the box. `path` is appended to the Stripe API
  base; `params` is form-encoded (Stripe's API is form-encoded, not JSON).
  """
  @spec build_request(String.t(), :get | :post, map()) :: %{
          method: :get | :post,
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
        {"Content-Type", "application/x-www-form-urlencoded"}
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
          {:ok, %{status: status, body: body}} -> {:error, {:stripe_http_error, status, body}}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_stripe_response, other}}
        end

      _ ->
        {:error, :http_client_not_configured}
    end
  end

  defp atomize_key(map, field) when is_atom(field) do
    Map.put(map, field, map[to_string(field)] || map[field])
  end

  defp verify_signature(payload, signature, secret) do
    expected =
      :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)

    if secure_compare(signature, expected) do
      case Jason.decode(payload) do
        {:ok, event} -> {:ok, event}
        _ -> {:error, :invalid_payload}
      end
    else
      {:error, :invalid_signature}
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

  defp config, do: Application.get_env(:barkpark_cloud, __MODULE__, [])
end
