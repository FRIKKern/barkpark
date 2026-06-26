defmodule BarkparkCloud.BillingTest do
  use BarkparkCloud.DataCase, async: true

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
               StubGateway.charge(customer_id, 4900, "eur", %{reason: "go_live"})

      assert {:ok, charge_id_again} =
               StubGateway.charge(customer_id, 4900, "eur", %{reason: "go_live"})

      assert charge_id == charge_id_again
      assert String.starts_with?(charge_id, "ch_stub_")

      assert {:ok, sub_id} = StubGateway.create_subscription(customer_id, "pro")
      assert {:ok, sub_id_again} = StubGateway.create_subscription(customer_id, "pro")

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
  end

  describe "subscribe/2 — persists an active subscription via the gateway" do
    test "subscribe(team, :pro) creates and persists an active Subscription" do
      team = team_fixture()

      assert {:ok, %Subscription{} = sub} = Billing.subscribe(team, :pro)

      assert sub.team_id == team.id
      assert sub.plan == "pro"
      assert sub.status == "active"
      # Gateway handed back deterministic stub ids — persisted on the row.
      assert String.starts_with?(sub.gateway_customer_id, "cus_stub_")
      assert String.starts_with?(sub.gateway_subscription_id, "sub_stub_")

      # It is the team's active subscription.
      assert %Subscription{id: id} = Billing.active_subscription(team)
      assert id == sub.id
    end

    test "every roadmap tier is accepted" do
      for plan <- ~w(free starter pro business dedicated) do
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

      {:ok, _} = Billing.subscribe(team_a, :starter)

      assert %Subscription{} = Billing.active_subscription(team_a)
      # B has no subscription — A's does not leak across.
      assert is_nil(Billing.active_subscription(team_b))
    end

    test "a team cannot hold two active subscriptions (one-active-per-team index)" do
      team = team_fixture()
      assert {:ok, _} = Billing.subscribe(team, :pro)
      assert {:error, changeset} = Billing.subscribe(team, :business)
      assert "this team already has an active subscription" in errors_on(changeset).team_id
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

    test "a charge request carries amount, currency, customer and flattened metadata" do
      req =
        StripeGateway.build_request("/payment_intents", :post, %{
          "amount" => 4900,
          "currency" => "eur",
          "customer" => "cus_123",
          "metadata[team_id]" => "team-9"
        })

      assert req.url == "https://api.stripe.com/v1/payment_intents"
      # Sorted form encoding: amount, currency, customer, metadata[team_id].
      assert req.body ==
               "amount=4900&currency=eur&customer=cus_123&metadata%5Bteam_id%5D=team-9"
    end
  end
end
