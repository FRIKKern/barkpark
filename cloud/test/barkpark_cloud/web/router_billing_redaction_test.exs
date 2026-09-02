defmodule BarkparkCloud.Web.RouterBillingRedactionTest do
  @moduledoc """
  SECURITY REGRESSION — the raw Stripe HTTP response body must NEVER reach the
  client. The Stripe gateway binds the raw response body into
  `{:stripe_http_error, status, body}` (StripeGateway.request/2); that body can
  carry customer/PII internals (`cus_…` ids). Before the fix the billing routes
  echoed it verbatim via `reason: inspect(reason)`, so an authenticated
  PRIMARY-TEAM OWNER driving POST /v1/billing/checkout received the raw Stripe
  internals in the error response. `billing_reason/1` now redacts it to a
  generic, status-keyed message while the gateway logs the full detail
  server-side.

  This test drives the REAL authenticated owner path with an injected http_client
  stub whose response body carries a `cus_SENSITIVE_SENTINEL`, and asserts that
  sentinel NEVER appears in the client response. It REDS on the unfixed tree
  (where `inspect(reason)` echoes the whole tuple, sentinel and all) and GREENS
  with the redaction fix. `async: false` because it mutates application env
  (Billing gateway + StripeGateway http_client) for the duration of the test.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing}
  alias BarkparkCloud.Billing.StripeGateway
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @sentinel "cus_SENSITIVE_SENTINEL"

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp user_with_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  defp call(method, path, body, token) do
    conn =
      conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Swap Billing to the real StripeGateway with a priced plan, a webhook secret
  # and a LIVE-shaped secret key (so checkout_capability/0 is :available and the
  # route reaches the gateway),
  # and inject an http_client stub that returns a NON-2xx Stripe response whose
  # body carries the sentinel. Restore the prior env on exit.
  defp put_leaky_gateway do
    prev_billing = Application.get_env(:barkpark_cloud, Billing)
    prev_gateway = Application.get_env(:barkpark_cloud, StripeGateway)

    on_exit(fn ->
      if prev_billing,
        do: Application.put_env(:barkpark_cloud, Billing, prev_billing),
        else: Application.delete_env(:barkpark_cloud, Billing)

      if prev_gateway,
        do: Application.put_env(:barkpark_cloud, StripeGateway, prev_gateway),
        else: Application.delete_env(:barkpark_cloud, StripeGateway)
    end)

    stub = fn _req ->
      {:ok,
       %{
         status: 402,
         body:
           ~s({"error":{"type":"card_error","code":"card_declined","message":"Your card was declined.","customer":"#{@sentinel}"}})
       }}
    end

    Application.put_env(
      :barkpark_cloud,
      Billing,
      Keyword.merge(prev_billing || [],
        gateway: StripeGateway,
        prices: %{"supporter" => "price_test_123"}
      )
    )

    Application.put_env(
      :barkpark_cloud,
      StripeGateway,
      Keyword.merge(prev_gateway || [],
        # cch-w50-bl: was "sk_test_x". A `sk_test_` prefix now answers
        # :test_mode, and Billing.checkout/2 refuses that BEFORE the gateway —
        # which would make this redaction test vacuous (its own non-vacuity
        # guard, `error == "checkout_failed"`, catches exactly that and is why
        # the move was forced rather than discovered late). The key shape is
        # incidental to what this file proves; reaching the gateway is not.
        secret_key: "sk_live_x",
        webhook_secret: "whsec_test",
        http_client: stub
      )
    )
  end

  describe "POST /v1/billing/checkout — raw Stripe body redaction" do
    test "the raw Stripe response body (and its cus_ id) NEVER reaches the owner" do
      put_leaky_gateway()
      {_owner, _team, token} = user_with_team()

      conn = call(:post, "/v1/billing/checkout", %{plan: "supporter"}, token)

      # Non-vacuous guard FIRST: prove we actually reached the gateway-error arm
      # of the OWNER checkout path (not a 401/403/422 no_team short-circuit that
      # would make the redaction assertion vacuously pass).
      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "checkout_failed"

      # THE SEAL: the sentinel from the raw Stripe body must not appear ANYWHERE
      # in the client response — neither the redacted `reason` nor the full body.
      refute conn.resp_body =~ @sentinel
      refute body["reason"] =~ @sentinel

      # …and the client gets the generic, status-keyed message instead.
      assert body["reason"] == "billing provider returned an error (HTTP 402)"
    end
  end
end
