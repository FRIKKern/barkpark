defmodule BarkparkCloud.Billing.HttpClientTest do
  # Pure-mapping + injection tests for the cloud-17 :httpc transport. NEVER hits
  # the real Stripe API — `to_httpc/1` is asserted directly, and the gateway
  # routing test injects a stub http_client fun.
  use ExUnit.Case, async: false

  alias BarkparkCloud.Billing.HttpClient
  alias BarkparkCloud.Billing.StripeGateway

  describe "to_httpc/1 — pure request-map → :httpc tuple mapping" do
    test "a POST pulls Content-Type out and charlist-encodes url + remaining headers" do
      req = %{
        method: :post,
        url: "https://api.stripe.com/v1/checkout/sessions",
        headers: [
          {"Authorization", "Bearer sk_test_x"},
          {"Content-Type", "application/x-www-form-urlencoded"}
        ],
        body: "a=b"
      }

      {request_arg, http_opts, opts} = HttpClient.to_httpc(req)

      assert {url_cl, header_cls, content_type_cl, body} = request_arg

      # url + headers are charlists for :httpc.
      assert url_cl == ~c"https://api.stripe.com/v1/checkout/sessions"

      # Content-Type is pulled OUT of the header list into its own arg…
      assert content_type_cl == ~c"application/x-www-form-urlencoded"
      refute Enum.any?(header_cls, fn {k, _v} -> k == ~c"Content-Type" end)

      # …and the Authorization header survives, as a charlist pair.
      assert {~c"Authorization", ~c"Bearer sk_test_x"} in header_cls

      # Body is preserved verbatim (binary).
      assert body == "a=b"

      # Verified TLS + bounded timeouts ride in http_opts; binary body in opts.
      ssl = Keyword.fetch!(http_opts, :ssl)
      assert ssl[:verify] == :verify_peer
      assert is_list(ssl[:cacerts]) and ssl[:cacerts] != []
      assert is_function(get_in(ssl, [:customize_hostname_check, :match_fun]))
      assert Keyword.fetch!(http_opts, :timeout) == 15_000
      assert Keyword.fetch!(http_opts, :connect_timeout) == 10_000
      assert Keyword.fetch!(opts, :body_format) == :binary
    end

    test "a POST with no explicit Content-Type defaults to form-urlencoded" do
      req = %{
        method: :post,
        url: "https://api.stripe.com/v1/customers",
        headers: [{"Authorization", "Bearer sk_test_x"}],
        body: "email=a%40b.com"
      }

      {{_url, header_cls, content_type_cl, _body}, _http_opts, _opts} = HttpClient.to_httpc(req)

      assert content_type_cl == ~c"application/x-www-form-urlencoded"
      # The lone header is left intact (no Content-Type to pop).
      assert header_cls == [{~c"Authorization", ~c"Bearer sk_test_x"}]
    end

    test "a GET uses the {url, headers} 2-tuple form" do
      req = %{
        method: :get,
        url: "https://api.stripe.com/v1/customers/cus_1",
        headers: [{"Authorization", "Bearer sk_test_x"}],
        body: ""
      }

      {{url_cl, header_cls}, http_opts, opts} = HttpClient.to_httpc(req)

      assert url_cl == ~c"https://api.stripe.com/v1/customers/cus_1"
      assert header_cls == [{~c"Authorization", ~c"Bearer sk_test_x"}]
      assert Keyword.fetch!(http_opts, :ssl)[:verify] == :verify_peer
      assert Keyword.fetch!(opts, :body_format) == :binary
    end
  end

  describe "gateway routing with http_client: &HttpClient.request/1 injected" do
    # Inject the real client REFERENCE but a stub fun in its place so the gateway
    # routes correctly without any network. The shape of the injected fun is
    # exactly what HttpClient.request/1 returns: {:ok, %{status, body}}.
    setup do
      prev = Application.get_env(:barkpark_cloud, StripeGateway)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark_cloud, StripeGateway, prev),
          else: Application.delete_env(:barkpark_cloud, StripeGateway)
      end)

      :ok
    end

    test "an injected client returning a 2xx → the gateway extracts the field" do
      stub = fn %{method: :post, url: url, headers: headers, body: _body} ->
        assert url == "https://api.stripe.com/v1/customers"
        assert {"Authorization", "Bearer " <> _} = List.keyfind(headers, "Authorization", 0)
        {:ok, %{status: 200, body: Jason.encode!(%{"id" => "cus_live_1"})}}
      end

      put_gateway_config(http_client: stub)

      assert {:ok, "cus_live_1"} = StripeGateway.create_customer(%{email: "x@y.com"})
    end

    test "an injected client returning a non-2xx → {:error, {:stripe_http_error, ...}}" do
      stub = fn _req -> {:ok, %{status: 402, body: ~s({"error":"card_declined"})}} end
      put_gateway_config(http_client: stub)

      assert {:error, {:stripe_http_error, 402, _body}} =
               StripeGateway.create_customer(%{email: "x@y.com"})
    end

    test "an injected client returning {:error, reason} → that error propagates" do
      stub = fn _req -> {:error, {:http_client, :nxdomain}} end
      put_gateway_config(http_client: stub)

      assert {:error, {:http_client, :nxdomain}} =
               StripeGateway.create_customer(%{email: "x@y.com"})
    end

    # Sanity: the real reference is a valid 1-arity fun the gateway accepts.
    test "&HttpClient.request/1 is the expected 1-arity client shape" do
      assert is_function(&HttpClient.request/1, 1)
    end

    defp put_gateway_config(overrides) do
      base = Application.get_env(:barkpark_cloud, StripeGateway, [])
      Application.put_env(:barkpark_cloud, StripeGateway, Keyword.merge(base, overrides))
    end
  end
end
