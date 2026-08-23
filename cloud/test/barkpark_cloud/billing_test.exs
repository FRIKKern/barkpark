defmodule BarkparkCloud.BillingTest do
  use BarkparkCloud.DataCase, async: true
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Billing
  alias BarkparkCloud.Billing.{StripeGateway, StubGateway, Subscription}

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  describe "gateway/0 — config-selected adapter" do
    test "defaults to the StubGateway in dev/test (no network, €0)" do
      assert Billing.gateway() == StubGateway
    end
  end

  describe "StubGateway — deterministic, in-memory pay-once path" do
    test "create_customer → charge → create_subscription return deterministic ids" do
      assert {:ok, customer_id} = StubGateway.create_customer(%{team_id: "team-abc"})
      assert {:ok, customer_id_again} = StubGateway.create_customer(%{team_id: "team-abc"})

      # Same input → same id. Deterministic, prefixed.
      assert customer_id == customer_id_again
      assert String.starts_with?(customer_id, "cus_stub_")

      assert {:ok, charge_id} =
               StubGateway.charge(customer_id, 4900, "usd", %{reason: "go_live"})

      assert {:ok, charge_id_again} =
               StubGateway.charge(customer_id, 4900, "usd", %{reason: "go_live"})

      assert charge_id == charge_id_again
      assert String.starts_with?(charge_id, "ch_stub_")

      assert {:ok, sub_id} = StubGateway.create_subscription(customer_id, "supporter")
      assert {:ok, sub_id_again} = StubGateway.create_subscription(customer_id, "supporter")

      assert sub_id == sub_id_again
      assert String.starts_with?(sub_id, "sub_stub_")

      # Different inputs → different ids (no collisions across the three calls).
      assert customer_id != charge_id
      assert charge_id != sub_id
    end

    test "verify_webhook accepts the fixed test signature and rejects a bad one" do
      assert {:ok, %{"verified" => true}} =
               StubGateway.verify_webhook("{\"id\":\"evt_1\"}", StubGateway.test_signature())

      assert {:error, :invalid_signature} =
               StubGateway.verify_webhook("{\"id\":\"evt_1\"}", "wrong-sig")
    end

    test "create_checkout_session returns a deterministic checkout.stub url keyed to team+plan" do
      assert {:ok, url} =
               StubGateway.create_checkout_session("team-abc", "supporter", price_id: "price_x")

      assert {:ok, url_again} = StubGateway.create_checkout_session("team-abc", "supporter")
      assert url == url_again

      # The url is exactly https://checkout.stub/<sha256(team_id<>plan)>.
      expected = :crypto.hash(:sha256, "team-abc" <> "supporter") |> Base.encode16(case: :lower)
      assert url == "https://checkout.stub/" <> expected

      # A different team OR a different plan → a different url.
      assert {:ok, other} = StubGateway.create_checkout_session("team-xyz", "supporter")
      assert other != url
      assert {:ok, other_plan} = StubGateway.create_checkout_session("team-abc", "support_plus")
      assert other_plan != url
    end
  end

  describe "subscribe/2 — persists an active subscription via the gateway" do
    test "subscribe(team, :supporter) creates and persists an active Subscription" do
      team = team_fixture()

      assert {:ok, %Subscription{} = sub} = Billing.subscribe(team, :supporter)

      assert sub.team_id == team.id
      assert sub.plan == "supporter"
      assert sub.status == "active"
      # Gateway handed back deterministic stub ids — persisted on the row.
      assert String.starts_with?(sub.gateway_customer_id, "cus_stub_")
      assert String.starts_with?(sub.gateway_subscription_id, "sub_stub_")

      # It is the team's active subscription.
      assert %Subscription{id: id} = Billing.active_subscription(team)
      assert id == sub.id
    end

    test "every tier is accepted" do
      for plan <- ~w(free supporter support_plus) do
        team = team_fixture()
        assert {:ok, %Subscription{plan: ^plan, status: "active"}} = Billing.subscribe(team, plan)
      end
    end

    test "an unknown plan is rejected by the changeset (validate_inclusion)" do
      team = team_fixture()
      assert {:error, changeset} = Billing.subscribe(team, "enterprise")
      assert "is invalid" in errors_on(changeset).plan
    end

    test "active_subscription/1 is team-scoped and nil when none" do
      team_a = team_fixture()
      team_b = team_fixture()

      assert is_nil(Billing.active_subscription(team_a))

      {:ok, _} = Billing.subscribe(team_a, :supporter)

      assert %Subscription{} = Billing.active_subscription(team_a)
      # B has no subscription — A's does not leak across.
      assert is_nil(Billing.active_subscription(team_b))
    end

    test "a team cannot hold two live subscriptions (one-live-per-team index)" do
      team = team_fixture()
      assert {:ok, _} = Billing.subscribe(team, :supporter)
      assert {:error, changeset} = Billing.subscribe(team, :support_plus)
      assert "already has a live subscription" in errors_on(changeset).team_id
    end
  end

  describe "charge_go_live/2 — the pay-once charge" do
    test "succeeds and returns a deterministic stub charge id" do
      team = team_fixture()
      assert {:ok, charge_id} = Billing.charge_go_live(team, 4900)
      assert String.starts_with?(charge_id, "ch_stub_")
    end

    test "rejects a non-positive amount at the boundary" do
      team = team_fixture()
      assert_raise FunctionClauseError, fn -> Billing.charge_go_live(team, 0) end
    end
  end

  describe "verify_webhook/2 — context pass-through to the gateway" do
    test "accepts the stub's test signature and rejects a bad one" do
      assert {:ok, %{"verified" => true}} =
               Billing.verify_webhook("{}", StubGateway.test_signature())

      assert {:error, :invalid_signature} = Billing.verify_webhook("{}", "nope")
    end
  end

  describe "price_id/1 — config-resolved plan → gateway price id" do
    test "a priced plan resolves to its placeholder price id" do
      assert Billing.price_id("supporter") == "price_PLACEHOLDER_supporter"
      assert Billing.price_id("support_plus") == "price_PLACEHOLDER_support_plus"
    end

    test "free has no price; an unknown plan resolves to nil" do
      assert is_nil(Billing.price_id("free"))
      assert is_nil(Billing.price_id("enterprise"))
    end
  end

  describe "checkout/2 — resolve price + open a hosted Checkout Session" do
    test "a priced plan → {:ok, checkout_url} keyed to the team's id" do
      team = team_fixture()
      assert {:ok, url} = Billing.checkout(team, "supporter")

      expected = :crypto.hash(:sha256, team.id <> "supporter") |> Base.encode16(case: :lower)
      assert url == "https://checkout.stub/" <> expected
    end

    test "free → {:error, :plan_invalid} (free needs no checkout)" do
      team = team_fixture()
      assert {:error, :plan_invalid} = Billing.checkout(team, "free")
    end

    test "an unknown plan → {:error, :plan_invalid}" do
      team = team_fixture()
      assert {:error, :plan_invalid} = Billing.checkout(team, "enterprise")
    end

    test "checkout does NOT persist a subscription — that happens on the webhook" do
      team = team_fixture()
      assert {:ok, _url} = Billing.checkout(team, "supporter")
      # No active subscription yet — the customer hasn't paid; the webhook lands it.
      assert is_nil(Billing.active_subscription(team))
    end
  end

  describe "handle_webhook/2 — verify + activate from signed metadata" do
    defp completed_event(team_id, plan) do
      Jason.encode!(%{
        "id" => "evt_1",
        "type" => "checkout.session.completed",
        "data" => %{"object" => %{"metadata" => %{"team_id" => team_id, "plan" => plan}}}
      })
    end

    test "a valid checkout.session.completed event activates the team's subscription" do
      team = team_fixture()
      raw = completed_event(team.id, "supporter")

      assert {:ok, %Subscription{} = sub} =
               Billing.handle_webhook(raw, StubGateway.test_signature())

      assert sub.team_id == team.id
      assert sub.plan == "supporter"
      assert sub.status == "active"
      assert %Subscription{} = Billing.active_subscription(team)
    end

    test "an invalid signature → {:error, :invalid_signature} and NO subscription" do
      team = team_fixture()
      raw = completed_event(team.id, "supporter")

      assert {:error, :invalid_signature} = Billing.handle_webhook(raw, "forged")
      assert is_nil(Billing.active_subscription(team))
    end

    test "a repeated event is idempotent → {:ok, :already_active}, one row only" do
      team = team_fixture()
      raw = completed_event(team.id, "supporter")
      sig = StubGateway.test_signature()

      assert {:ok, %Subscription{}} = Billing.handle_webhook(raw, sig)
      assert {:ok, :already_active} = Billing.handle_webhook(raw, sig)

      count =
        from(s in Subscription, where: s.team_id == ^team.id)
        |> BarkparkCloud.Repo.aggregate(:count)

      assert count == 1
    end

    test "a valid event of a non-activating type is ignored, grants nothing" do
      team = team_fixture()

      raw =
        Jason.encode!(%{
          "id" => "evt_2",
          "type" => "invoice.paid",
          "data" => %{"object" => %{"metadata" => %{"team_id" => team.id, "plan" => "supporter"}}}
        })

      assert {:ok, :ignored} = Billing.handle_webhook(raw, StubGateway.test_signature())
      assert is_nil(Billing.active_subscription(team))
    end

    test "a customer.subscription.updated event only activates when status is active" do
      team = team_fixture()

      not_active =
        Jason.encode!(%{
          "type" => "customer.subscription.updated",
          "data" => %{
            "object" => %{
              "status" => "incomplete",
              "metadata" => %{"team_id" => team.id, "plan" => "supporter"}
            }
          }
        })

      assert {:ok, :ignored} = Billing.handle_webhook(not_active, StubGateway.test_signature())
      assert is_nil(Billing.active_subscription(team))

      active =
        Jason.encode!(%{
          "type" => "customer.subscription.updated",
          "data" => %{
            "object" => %{
              "status" => "active",
              "metadata" => %{"team_id" => team.id, "plan" => "supporter"}
            }
          }
        })

      assert {:ok, %Subscription{}} = Billing.handle_webhook(active, StubGateway.test_signature())
      assert %Subscription{} = Billing.active_subscription(team)
    end
  end

  describe "StripeGateway — request-builder shape (NEVER sent)" do
    test "build_request/3 produces the expected Stripe API call shape" do
      req =
        StripeGateway.build_request("/customers", :post, %{"email" => "a@b.com", "name" => "Acme"})

      assert req.method == :post
      assert req.url == "https://api.stripe.com/v1/customers"

      # Bearer auth from the (fake) configured secret key + form content type.
      assert {"Authorization", "Bearer sk_test_FAKE_cloud5"} in req.headers
      assert {"Content-Type", "application/x-www-form-urlencoded"} in req.headers

      # Body is sorted, percent-encoded form data — deterministic and assertable.
      assert req.body == "email=a%40b.com&name=Acme"
    end

    test "the live HTTP path fails closed when no client is injected (no spend in tests)" do
      # No http_client configured in test → any callback that would hit the wire
      # returns an error instead of sending. The live key + client are cloud-17.
      assert {:error, :http_client_not_configured} =
               StripeGateway.create_customer(%{email: "x@y.com"})
    end

    test "update_customer posts to /customers/{id} with only the changed email" do
      req = StripeGateway.build_request("/customers/cus_123", :post, %{"email" => "new@b.com"})

      assert req.method == :post
      assert req.url == "https://api.stripe.com/v1/customers/cus_123"
      assert req.body == "email=new%40b.com"

      # The live call fails closed in tests (no client) — it never spends.
      assert {:error, :http_client_not_configured} =
               StripeGateway.update_customer("cus_123", %{email: "new@b.com"})
    end

    test "StubGateway.update_customer echoes the id back (€0 inline sync path)" do
      assert {:ok, "cus_abc"} = StubGateway.update_customer("cus_abc", %{email: "x@y.com"})
    end

    test "a charge request carries amount, currency, customer and flattened metadata" do
      req =
        StripeGateway.build_request("/payment_intents", :post, %{
          "amount" => 4900,
          "currency" => "usd",
          "customer" => "cus_123",
          "metadata[team_id]" => "team-9"
        })

      assert req.url == "https://api.stripe.com/v1/payment_intents"
      # Sorted form encoding: amount, currency, customer, metadata[team_id].
      assert req.body ==
               "amount=4900&currency=usd&customer=cus_123&metadata%5Bteam_id%5D=team-9"
    end

    test "a Checkout Session request has mode=subscription, the price line item, urls + metadata" do
      # Build the same params create_checkout_session/3 sends, then assert the
      # request SHAPE through the public builder — no network leaves the box.
      req =
        StripeGateway.build_request("/checkout/sessions", :post, %{
          "mode" => "subscription",
          "line_items[0][price]" => "price_PLACEHOLDER_supporter",
          "line_items[0][quantity]" => 1,
          "success_url" => "https://barkpark.cloud/?checkout=success",
          "cancel_url" => "https://barkpark.cloud/?checkout=cancel",
          "metadata[team_id]" => "team-9",
          "metadata[plan]" => "supporter"
        })

      assert req.method == :post
      assert req.url == "https://api.stripe.com/v1/checkout/sessions"

      # Sorted, percent-encoded form body — mode=subscription, a single line item
      # on the resolved price, the success/cancel urls, and team_id+plan metadata.
      assert req.body ==
               "cancel_url=https%3A%2F%2Fbarkpark.cloud%2F%3Fcheckout%3Dcancel" <>
                 "&line_items%5B0%5D%5Bprice%5D=price_PLACEHOLDER_supporter" <>
                 "&line_items%5B0%5D%5Bquantity%5D=1" <>
                 "&metadata%5Bplan%5D=supporter&metadata%5Bteam_id%5D=team-9" <>
                 "&mode=subscription" <>
                 "&success_url=https%3A%2F%2Fbarkpark.cloud%2F%3Fcheckout%3Dsuccess"
    end

    test "create_checkout_session fails closed when no client is injected (no spend in tests)" do
      assert {:error, :http_client_not_configured} =
               StripeGateway.create_checkout_session("team-9", "supporter", price_id: "price_x")
    end
  end

  describe "StripeGateway.verify_webhook/2 — real Stripe v1 signature scheme" do
    # The TEST signing secret (config/test.exs). This is the HMAC KEY, not a real
    # Stripe secret — the verification algorithm is deterministic and testable
    # without ever touching Stripe.
    @webhook_secret "whsec_test_FAKE_cloud5"

    # Build a real Stripe-Signature header: HMAC-SHA256 over "<t>.<payload>",
    # lowercase hex, in the documented `t=<ts>,v1=<hex>` shape.
    defp sign(payload, timestamp, secret \\ @webhook_secret) do
      v1 =
        :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{payload}")
        |> Base.encode16(case: :lower)

      "t=#{timestamp},v1=#{v1}"
    end

    test "a freshly-signed valid header verifies and returns the decoded event" do
      payload = ~s({"id":"evt_1","type":"checkout.session.completed"})
      now = System.system_time(:second)
      header = sign(payload, now)

      assert {:ok, event} = StripeGateway.verify_webhook(payload, header)
      assert event == %{"id" => "evt_1", "type" => "checkout.session.completed"}
    end

    test "a header with a WRONG v1 hex is rejected as :invalid_signature" do
      payload = ~s({"id":"evt_1"})
      now = System.system_time(:second)
      # Correctly-shaped header, correct timestamp, but a bogus (well-formed-hex)
      # signature → must fail closed, NOT crash.
      header = "t=#{now},v1=#{String.duplicate("0", 64)}"

      assert {:error, :invalid_signature} = StripeGateway.verify_webhook(payload, header)
    end

    test "a correctly-signed but OLD timestamp is rejected as :timestamp_out_of_tolerance" do
      payload = ~s({"id":"evt_1"})
      old = System.system_time(:second) - 600
      # The v1 is a VALID hmac for that (old) timestamp — so only the replay
      # window, not the signature, can reject it.
      header = sign(payload, old)

      assert {:error, :timestamp_out_of_tolerance} =
               StripeGateway.verify_webhook(payload, header)
    end

    test "a malformed header (no t=, junk) returns {:error, _} without crashing" do
      payload = ~s({"id":"evt_1"})

      # No t= at all.
      assert {:error, :malformed_header} =
               StripeGateway.verify_webhook(payload, "v1=deadbeef")

      # Pure junk.
      assert {:error, _} = StripeGateway.verify_webhook(payload, "not-a-stripe-header")

      # t= present but non-integer.
      assert {:error, :malformed_header} =
               StripeGateway.verify_webhook(payload, "t=notanint,v1=deadbeef")

      # Empty header.
      assert {:error, _} = StripeGateway.verify_webhook(payload, "")
    end

    test "multiple v1 values verify when ANY one is correct (secret rotation)" do
      payload = ~s({"id":"evt_1"})
      now = System.system_time(:second)

      good =
        :crypto.mac(:hmac, :sha256, @webhook_secret, "#{now}.#{payload}")
        |> Base.encode16(case: :lower)

      # First v1 is bogus, second is the correct one — Stripe sends multiple
      # during a signing-secret rotation; any match is sufficient.
      header = "t=#{now},v1=#{String.duplicate("a", 64)},v1=#{good}"

      assert {:ok, %{"id" => "evt_1"}} = StripeGateway.verify_webhook(payload, header)
    end
  end

  describe "grant_forever/1 — admin comp tier" do
    test "grants a never-lapsing active forever sub to a team with no subscription" do
      team = team_fixture()
      refute Billing.entitled?(team)

      assert {:ok, %Subscription{} = sub} = Billing.grant_forever(team)
      assert sub.plan == "forever"
      assert sub.status == "active"
      # No gateway ids → no Stripe lifecycle event can ever lapse it.
      assert is_nil(sub.gateway_customer_id)
      assert is_nil(sub.gateway_subscription_id)
      assert Billing.entitled?(team)
    end

    test "is idempotent — a team already on forever is a loud no-op" do
      team = team_fixture()
      assert {:ok, %Subscription{}} = Billing.grant_forever(team)
      assert {:ok, :already_forever} = Billing.grant_forever(team)
      # Exactly one live sub, still forever.
      assert %Subscription{plan: "forever"} = Billing.live_subscription(team)
    end

    test "converts an existing paid subscription to the comp tier, detaching gateway ids" do
      team = team_fixture()
      assert {:ok, %Subscription{plan: "support_plus"}} = Billing.subscribe(team, "support_plus")

      assert {:ok, %Subscription{} = sub} = Billing.grant_forever(team)
      assert sub.plan == "forever"
      assert sub.status == "active"
      assert is_nil(sub.gateway_subscription_id)
      assert Billing.entitled?(team)
    end

    test "forever is NOT purchasable via the customer checkout (unpriced → plan_invalid)" do
      team = team_fixture()
      assert {:error, :plan_invalid} = Billing.checkout(team, "forever")
    end
  end
end
