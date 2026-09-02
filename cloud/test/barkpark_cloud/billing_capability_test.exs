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

  # The two key shapes the capability distinguishes. Neither is a credential:
  # both are refused by Stripe on sight, and no test here reaches the network.
  @live_key "sk_live_never_used"
  @test_key "sk_test_never_used"

  # A fully-wired state, so the ONLY variable in the test-mode block is the key.
  @wired_prices %{"supporter" => "price_supporter"}
  @wired_secret "whsec_test"

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
  #
  # cch-w50-bl MOVED THIS KEY from `sk_test_never_used` to a LIVE-shaped one, and
  # the move is the point rather than housekeeping. `checkout_capability/0` now
  # reads the key's prefix: a `sk_test_…` key answers `:test_mode`, so under the
  # old fixture every state below that used to read `:available` would read
  # `:test_mode` and the five-state matrix would be asserting the new state
  # everywhere instead of the ones it was written for. The states here mean
  # "prices × webhook secret, key not in question"; the key axis gets its own
  # states in the TEST-MODE describe block, driven BOTH ways.
  defp put_state(prices, webhook_secret) do
    put_state(prices, webhook_secret, @live_key)
  end

  defp put_state(prices, webhook_secret, secret_key) do
    base = Application.get_env(:barkpark_cloud, Billing, [])

    Application.put_env(
      :barkpark_cloud,
      Billing,
      base |> Keyword.put(:gateway, StripeGateway) |> Keyword.put(:prices, prices)
    )

    Application.put_env(:barkpark_cloud, StripeGateway,
      secret_key: secret_key,
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

  # The declaration as the wire actually carries it, with the key axis explicit.
  defp capability_payload_with_key(prices, secret, key) do
    {_user, _team, token} = user_with_team()
    put_state(prices, secret, key)
    conn = call(:get, "/v1/subscription", nil, token)
    assert conn.status == 200
    json_body(conn)
  end

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

  describe "TEST MODE — a sk_test_ key is not :available (cch-w50-bl)" do
    # MEASURED, NOT HYPOTHETICAL. On the serving control plane
    # (cloud-control_plane_green-1, re-read read-only 2026-09-02):
    # STRIPE_SECRET_KEY begins `sk_test_`, STRIPE_PRICE_SUPPORTER is
    # `price_1TnEHC…` and STRIPE_WEBHOOK_SECRET is `whsec_…`. That is exactly
    # the state below: everything D553/D554 check is satisfied, and until this
    # slice `checkout_capability/0` answered :available on it — so the console
    # rendered a live Subscribe that opened a REAL hosted Checkout Session no
    # real card can pay.
    #
    # THE MUTATION THIS BLOCK EXISTS FOR: delete the `test_mode_key?() ->
    # :test_mode` arm from `checkout_capability/0` (collapse it into
    # :available) and every test here reds BY NAME.

    test "the SAME wiring answers :test_mode on a test key and :available on a live key" do
      # Both directions in one test, because a one-way assertion cannot tell a
      # working distinction from a function that answers :test_mode always.
      put_state(@wired_prices, @wired_secret, @test_key)
      assert Billing.checkout_capability() == :test_mode
      refute Billing.configured?(), "a plane that cannot take money is not configured?"

      put_state(@wired_prices, @wired_secret, @live_key)
      assert Billing.checkout_capability() == :available
      assert Billing.configured?()
    end

    test "the two no-price / no-secret states OUTRANK the key — a test key never hides them" do
      # Ordering matters: :unconfigured and :unverifiable name a MORE specific
      # deploy fault than the key's mode, and both already refuse. A test key
      # must not relabel them.
      put_state(%{}, @wired_secret, @test_key)
      assert Billing.checkout_capability() == :unconfigured

      put_state(@wired_prices, nil, @test_key)
      assert Billing.checkout_capability() == :unverifiable
    end

    test "Billing.checkout/2 refuses BEFORE the gateway is called, with its own reason" do
      {_user, team, _token} = user_with_team()
      put_state(@wired_prices, @wired_secret, @test_key)

      # The price DOES resolve and the webhook secret IS wired — this is not a
      # plan_invalid case and not the D553 hole. Nothing but the key refuses it.
      assert Billing.price_id("supporter") == "price_supporter"
      assert Billing.checkout(team, "supporter") == {:error, :billing_test_mode}
    end

    test "POST /v1/billing/checkout 422s billing_test_mode and states the reason" do
      {_user, _team, token} = user_with_team()
      put_state(@wired_prices, @wired_secret, @test_key)

      conn = call(:post, "/v1/billing/checkout", %{plan: "supporter"}, token)

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "billing_test_mode"

      assert body["reason"] == Billing.test_mode_disclosure(),
             "the server's reason must BE the disclosure, not a paraphrase of it"

      # The sentence itself: plain words, and no future tense anywhere in it.
      assert body["reason"] =~ "test mode"
      refute body["reason"] =~ ~r/\bwill\b/i
    end

    test "an UNPRICED plan still answers plan_invalid on a test-mode plane" do
      # The BILL-2 arm reads the enum now, not `configured?/0`. Under :test_mode
      # the prices resolve, so a bad plan name really is the caller's problem
      # and must not be relabelled a deploy fault.
      {_user, _team, token} = user_with_team()
      put_state(@wired_prices, @wired_secret, @test_key)

      conn = call(:post, "/v1/billing/checkout", %{plan: "support_plus"}, token)

      assert conn.status == 422
      assert json_body(conn)["error"] == "plan_invalid"
    end

    test "the declaration on the wire carries test_mode — the console can read it before the click" do
      body = capability_payload_with_key(@wired_prices, @wired_secret, @test_key)

      assert body["billing_capability"]["checkout"] == "test_mode"
      assert body["billing_capability"]["plans"] == ["supporter"]
    end
  end
end
