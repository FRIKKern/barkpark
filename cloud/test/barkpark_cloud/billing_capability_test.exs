defmodule BarkparkCloud.BillingCapabilityTest do
  @moduledoc """
  The control plane's PRE-HOC billing declaration (D554) and the pre-flight
  refusal that makes it honest (D553).

  Two defects, one contract:

    * `Billing.checkout/2` used to branch SOLELY on `price_id/1`. With prices
      wired and NO webhook signing secret a real hosted Checkout Session opened
      — the card was charged — while `StripeGateway.verify_webhook/2` returns
      `{:error, :no_secret}` forever, so the activation event could never be
      trusted. The state-C behaviour arm below is the assertion that keeps that
      path shut, and deleting the pre-flight clause MUST red it.
    * `GET /v1/subscription` said nothing about whether checkout could work, so
      the console could only find out AFTER the click. It now carries
      `billing_capability` as a TOP-LEVEL sibling, present in the
      `{subscription: nil}` arm the unsubscribed owner receives.

  NO SOURCE-TEXT SCAN anywhere in this file: every expectation is produced by
  CALLING the context (`checkout_capability/0`, `priced_plans/0`,
  `price_id/1`, `checkout_plans/0`) or by decoding a real response from
  `Router.call/2`. `async: false` because the config states are driven with
  `Application.put_env` over the gateway/prices/secret triple.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing}
  alias BarkparkCloud.Billing.StripeGateway
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # The FIVE config states, each a {prices, webhook_secret} pair driven against
  # the REAL StripeGateway (the StubGateway needs no config and is always
  # :available, so it could never express these states).
  #
  #   A  nothing wired                     — the dead button
  #   B  secret only                       — still the dead button
  #   C  priced, NO secret                 — THE HOLE: a card would be charged
  #                                          against a webhook that can never verify
  #   D  fully wired                       — checkout may proceed
  #   PARTIAL  one paid tier priced        — the mode a boolean cannot express:
  #                                          available, but not for every plan
  @states [
    {:a, %{}, nil},
    {:b, %{}, "whsec_test"},
    {:c, %{"supporter" => "price_supporter"}, nil},
    {:d, %{"supporter" => "price_supporter", "support_plus" => "price_plus"}, "whsec_test"},
    {:partial, %{"supporter" => "price_supporter"}, "whsec_test"}
  ]

  setup do
    billing_env = Application.get_env(:barkpark_cloud, Billing)
    stripe_env = Application.get_env(:barkpark_cloud, StripeGateway)

    on_exit(fn ->
      restore(Billing, billing_env)
      restore(StripeGateway, stripe_env)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark_cloud, key)
  defp restore(key, env), do: Application.put_env(:barkpark_cloud, key, env)

  # Put the process into one of the five states. `secret_key` is always set so a
  # regression that reaches the gateway fails with a gateway error rather than a
  # raise — the mutant's answer stays legible.
  defp put_state(prices, webhook_secret) do
    base = Application.get_env(:barkpark_cloud, Billing, [])

    Application.put_env(
      :barkpark_cloud,
      Billing,
      base |> Keyword.put(:gateway, StripeGateway) |> Keyword.put(:prices, prices)
    )

    Application.put_env(:barkpark_cloud, StripeGateway,
      secret_key: "sk_test_never_used",
      webhook_secret: webhook_secret
    )
  end

  defp user_with_team do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "owner-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  defp call(method, path, body, token) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # The declaration as the wire actually carries it, for the given state.
  defp capability_payload(prices, secret) do
    {_user, _team, token} = user_with_team()
    put_state(prices, secret)
    conn = call(:get, "/v1/subscription", nil, token)
    assert conn.status == 200
    json_body(conn)
  end

  describe "the wire declares what the server can do (D554)" do
    test "billing_capability.checkout equals Billing.checkout_capability() in every state" do
      for {label, prices, secret} <- @states do
        body = capability_payload(prices, secret)
        cap = body["billing_capability"]

        assert is_map(cap), "state #{label}: billing_capability missing from #{inspect(body)}"

        # Read the expectation by CALLING, never by matching source text.
        assert cap["checkout"] == Atom.to_string(Billing.checkout_capability()),
               "state #{label}: wire said #{inspect(cap["checkout"])}, server says #{inspect(Billing.checkout_capability())}"
      end
    end

    test "it is a TOP-LEVEL sibling, present in the {subscription: nil} arm" do
      {_user, _team, token} = user_with_team()
      put_state(%{"supporter" => "price_supporter"}, "whsec_test")

      body = json_body(call(:get, "/v1/subscription", nil, token))

      # The unsubscribed owner — the arm that actually stares at "Subscribe".
      assert body["subscription"] == nil
      assert body["billing_capability"] == %{"checkout" => "available", "plans" => ["supporter"]}
      assert Map.has_key?(body, "billing_capability")
    end

    test "the arm WITH a subscription carries it too" do
      {_user, team, token} = user_with_team()
      {:ok, _sub} = Billing.subscribe(team, "supporter")
      put_state(%{"supporter" => "price_supporter"}, "whsec_test")

      body = json_body(call(:get, "/v1/subscription", nil, token))

      assert body["subscription"]["plan"] == "supporter"
      assert body["billing_capability"]["checkout"] == "available"
    end

    test "BOTH-WAYS plan join: the payload's plan set is exactly the plans whose price resolves" do
      for {label, prices, secret} <- @states do
        body = capability_payload(prices, secret)
        listed = body["billing_capability"]["plans"]

        # The universe is enumerated SERVER-side, never read back off the
        # payload — that is what makes this lose in the DELETE direction.
        universe = Billing.checkout_plans()
        expected = Enum.filter(universe, &(Billing.price_id(&1) != nil))

        assert MapSet.new(listed) == MapSet.new(expected),
               "state #{label}: payload plans #{inspect(listed)} != server-derived #{inspect(expected)}"

        # Direction 1 — nothing listed that cannot be checked out.
        for plan <- listed do
          assert Billing.price_id(plan) != nil,
                 "state #{label}: payload listed #{plan} with no resolvable price"
        end

        # Direction 2 — nothing checkout-able silently omitted.
        for plan <- universe -- listed do
          assert Billing.price_id(plan) == nil,
                 "state #{label}: #{plan} has a price but is missing from the payload"
        end
      end
    end

    test "PARTIAL: one priced tier is available, and the payload names only that tier" do
      body = capability_payload(%{"supporter" => "price_supporter"}, "whsec_test")

      # The mode a boolean cannot express: configured? is true, yet support_plus
      # cannot be checked out — the console must blame the deploy, not the user.
      assert Billing.configured?()
      assert body["billing_capability"]["checkout"] == "available"
      assert body["billing_capability"]["plans"] == ["supporter"]
      assert Billing.price_id("support_plus") == nil
    end

    test "NON-VACUITY: the five states collectively produce ALL THREE enum values" do
      produced =
        for {_label, prices, secret} <- @states, into: MapSet.new() do
          body = capability_payload(prices, secret)
          body["billing_capability"]["checkout"]
        end

      assert produced == MapSet.new(["unconfigured", "unverifiable", "available"]),
             "the state matrix produced only #{inspect(MapSet.to_list(produced))} — a predicate matching nothing would pass green"
    end
  end

  describe "checkout_capability/0 and its projection" do
    test "the enum names each failure mode, and configured?/0 is exactly (== :available)" do
      expected = %{
        a: :unconfigured,
        b: :unconfigured,
        c: :unverifiable,
        d: :available,
        partial: :available
      }

      for {label, prices, secret} <- @states do
        put_state(prices, secret)

        assert Billing.checkout_capability() == expected[label],
               "state #{label}: got #{inspect(Billing.checkout_capability())}"

        assert Billing.configured?() == (Billing.checkout_capability() == :available),
               "state #{label}: the boolean drifted from the enum"
      end
    end

    test "priced_plans/0 is DERIVED — it tracks price_id/1, never a constant" do
      put_state(%{}, "whsec_test")
      assert Billing.priced_plans() == []

      put_state(%{"support_plus" => "price_plus"}, "whsec_test")
      assert Billing.priced_plans() == ["support_plus"]

      # free/trial never open a checkout, so a price on them changes nothing.
      put_state(%{"free" => "price_free", "trial" => "price_trial"}, "whsec_test")
      assert Billing.priced_plans() == []
      refute "free" in Billing.checkout_plans()
      refute "trial" in Billing.checkout_plans()
    end

    test "the StubGateway (dev/test) is always :available — it moves no money" do
      Application.put_env(
        :barkpark_cloud,
        Billing,
        Application.get_env(:barkpark_cloud, Billing, [])
        |> Keyword.put(:gateway, BarkparkCloud.Billing.StubGateway)
      )

      assert Billing.checkout_capability() == :available
      assert Billing.configured?()
    end
  end

  describe "STATE C — priced but unverifiable: no card is charged (D553)" do
    # THE assertion of this file. Delete the pre-flight clause in
    # Billing.checkout/2 and this reds: the call reaches StripeGateway and comes
    # back {:error, :http_client_not_configured} (in prod, a REAL session and a
    # REAL charge) instead of refusing.
    test "Billing.checkout/2 refuses BEFORE the gateway is called" do
      {_user, team, _token} = user_with_team()
      put_state(%{"supporter" => "price_supporter"}, nil)

      # The price DOES resolve — this is not a plan_invalid case.
      assert Billing.price_id("supporter") == "price_supporter"
      assert Billing.checkout_capability() == :unverifiable

      assert Billing.checkout(team, "supporter") == {:error, :billing_not_configured}
    end

    test "POST /v1/billing/checkout 422s billing_not_configured in state C" do
      {_user, _team, token} = user_with_team()
      put_state(%{"supporter" => "price_supporter"}, nil)

      conn = call(:post, "/v1/billing/checkout", %{plan: "supporter"}, token)

      assert conn.status == 422
      assert json_body(conn)["error"] == "billing_not_configured"
    end

    test "an UNPRICED plan still answers plan_invalid — the refusal fires only in the hole" do
      {_user, team, _token} = user_with_team()
      put_state(%{"supporter" => "price_supporter"}, nil)

      assert Billing.checkout(team, "support_plus") == {:error, :plan_invalid}
      assert Billing.checkout(team, "free") == {:error, :plan_invalid}
    end

    test "state D still opens a session — the refusal is not a blanket block" do
      {_user, team, _token} = user_with_team()

      # The StubGateway is the only gateway that returns a url at €0; the point
      # here is that an :available capability does NOT refuse.
      Application.put_env(
        :barkpark_cloud,
        Billing,
        Application.get_env(:barkpark_cloud, Billing, [])
        |> Keyword.put(:gateway, BarkparkCloud.Billing.StubGateway)
        |> Keyword.put(:prices, %{"supporter" => "price_supporter"})
      )

      assert {:ok, "https://checkout.stub/" <> _} = Billing.checkout(team, "supporter")
    end
  end
end
