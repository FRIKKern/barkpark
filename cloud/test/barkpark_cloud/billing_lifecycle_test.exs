defmodule BarkparkCloud.BillingLifecycleTest do
  @moduledoc """
  subscription-billing — the lifecycle past `active`: dunning (past_due),
  cancellation, recovery, the suspend/resume teeth, self-serve cancel + portal,
  and the grace-aware entitlement gate. All €0 through StubGateway — no live
  Stripe, no network.
  """
  use BarkparkCloud.DataCase, async: true
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Billing.{StripeGateway, StubGateway, Subscription}
  alias BarkparkCloud.Registry.Barkpark

  ## Fixtures

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  # A team with a live `active` subscription on `plan`. Returns {team, sub}.
  defp subscribed_team(plan \\ "supporter") do
    team = team_fixture()
    {:ok, sub} = Billing.subscribe(team, plan)
    {team, sub}
  end

  # Stripe-shaped lifecycle events keyed on the gateway customer id.
  defp event(type, customer_id, extra \\ %{}) do
    object = Map.merge(%{"customer" => customer_id}, extra)

    Jason.encode!(%{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => type,
      "data" => %{"object" => object}
    })
  end

  defp sig, do: StubGateway.test_signature()

  defp reload(%Subscription{id: id}), do: Repo.get!(Subscription, id)
  defp reload_bp(%Barkpark{id: id}), do: Repo.get!(Barkpark, id)

  ## ── Webhook lifecycle ──

  describe "handle_webhook/2 — invoice.payment_failed → past_due (grace, no suspend)" do
    test "marks the live sub past_due and does NOT suspend within grace" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      future = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.to_unix()

      raw =
        event("invoice.payment_failed", sub.gateway_customer_id, %{"current_period_end" => future})

      assert {:ok, %Subscription{status: "past_due", past_due: true}} =
               Billing.handle_webhook(raw, sig())

      # Still entitled (in grace) and the box is NOT suspended.
      assert Billing.entitled?(team)
      refute reload_bp(bp).suspended
    end

    test "past_due past the grace window suspends the team's managed boxes" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.to_unix()

      raw =
        event("invoice.payment_failed", sub.gateway_customer_id, %{"current_period_end" => past})

      assert {:ok, %Subscription{status: "past_due"}} = Billing.handle_webhook(raw, sig())

      refute Billing.entitled?(team)
      assert %Barkpark{suspended: true, suspended_reason: "billing_past_due"} = reload_bp(bp)
    end
  end

  describe "handle_webhook/2 — customer.subscription.deleted → canceled + suspend" do
    test "cancels the sub, stamps canceled_at, and suspends every managed box" do
      {team, sub} = subscribed_team()
      bp1 = barkpark_fixture(team)
      bp2 = barkpark_fixture(team)

      raw = event("customer.subscription.deleted", sub.gateway_customer_id)

      assert {:ok, %Subscription{status: "canceled"} = canceled} =
               Billing.handle_webhook(raw, sig())

      assert canceled.canceled_at
      refute Billing.entitled?(team)

      for bp <- [bp1, bp2] do
        assert %Barkpark{suspended: true, suspended_reason: "billing_lapsed"} = reload_bp(bp)
      end
    end

    test "is idempotent — a replay finds no live sub, no double-suspend, no crash" do
      {team, sub} = subscribed_team()
      _bp = barkpark_fixture(team)
      raw = event("customer.subscription.deleted", sub.gateway_customer_id)

      assert {:ok, %Subscription{status: "canceled"}} = Billing.handle_webhook(raw, sig())
      # Replay: the row is already canceled (excluded from the live lookup).
      assert {:ok, :ignored} = Billing.handle_webhook(raw, sig())

      # Still exactly one subscription row.
      assert 1 == Repo.aggregate(from(s in Subscription, where: s.team_id == ^team.id), :count)
    end
  end

  describe "handle_webhook/2 — recovery" do
    test "invoice.paid after past_due → back to active, past_due cleared, boxes resumed" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      # Lapse hard first (past grace → suspended).
      past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.to_unix()

      {:ok, _} =
        Billing.handle_webhook(
          event("invoice.payment_failed", sub.gateway_customer_id, %{"current_period_end" => past}),
          sig()
        )

      assert reload_bp(bp).suspended

      # Recover.
      assert {:ok, %Subscription{status: "active", past_due: false}} =
               Billing.handle_webhook(event("invoice.paid", sub.gateway_customer_id), sig())

      assert Billing.entitled?(team)
      refute reload_bp(bp).suspended
    end

    test "invoice.paid for an already-active sub is a no-op {:ok, :ignored}" do
      {_team, sub} = subscribed_team()

      assert {:ok, :ignored} =
               Billing.handle_webhook(event("invoice.paid", sub.gateway_customer_id), sig())
    end
  end

  describe "handle_webhook/2 — customer.subscription.updated dual membership" do
    test "status=canceled drives a cancel (lifecycle owns it, not activation)" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      raw =
        event("customer.subscription.updated", sub.gateway_customer_id, %{"status" => "canceled"})

      assert {:ok, %Subscription{status: "canceled"}} = Billing.handle_webhook(raw, sig())
      assert reload_bp(bp).suspended
    end

    test "status=active after past_due recovers" do
      {team, sub} = subscribed_team()
      {:ok, _} = Billing.mark_past_due(sub)
      assert Repo.get!(Subscription, sub.id).status == "past_due"

      raw =
        event("customer.subscription.updated", sub.gateway_customer_id, %{"status" => "active"})

      assert {:ok, %Subscription{status: "active"}} = Billing.handle_webhook(raw, sig())
      assert Billing.entitled?(team)
    end
  end

  describe "handle_webhook/2 — safety" do
    test "a forged signature on a lifecycle event changes nothing" do
      {_team, sub} = subscribed_team()
      raw = event("customer.subscription.deleted", sub.gateway_customer_id)

      assert {:error, :invalid_signature} = Billing.handle_webhook(raw, "forged")
      assert reload(sub).status == "active"
    end

    test "a lifecycle event for an unknown customer is ignored, nothing written" do
      raw = event("customer.subscription.deleted", "cus_stub_does_not_exist")
      assert {:ok, :ignored} = Billing.handle_webhook(raw, sig())
    end
  end

  ## ── Entitlement ──

  describe "entitled?/1" do
    test "active → true; no sub → false" do
      {team, _sub} = subscribed_team()
      assert Billing.entitled?(team)
      refute Billing.entitled?(team_fixture())
    end

    test "past_due within grace → true; past grace → false" do
      {team, sub} = subscribed_team()

      {:ok, _} =
        Billing.mark_past_due(sub, %{
          current_period_end: DateTime.add(DateTime.utc_now(), 3, :day)
        })

      assert Billing.entitled?(team)

      sub = reload(sub)

      {:ok, _} =
        Billing.mark_past_due(sub, %{
          current_period_end: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      refute Billing.entitled?(team)
    end
  end

  ## ── Self-serve ──

  describe "billing_portal_url/2" do
    test "returns the stub portal url for a subscribed team" do
      {team, sub} = subscribed_team()

      assert {:ok, "https://portal.stub/" <> _digest} = Billing.billing_portal_url(team)
      # Keyed to the gateway customer id.
      assert {:ok, url} = StubGateway.create_billing_portal_session(sub.gateway_customer_id)
      assert {:ok, ^url} = Billing.billing_portal_url(team)
    end

    test "no subscription → {:error, :no_subscription}" do
      assert {:error, :no_subscription} = Billing.billing_portal_url(team_fixture())
    end
  end

  describe "request_cancel/2" do
    test "grace (default) marks cancel_at_period_end and STAYS entitled" do
      {team, _sub} = subscribed_team()

      assert {:ok, %Subscription{cancel_at_period_end: true, status: "active"}} =
               Billing.request_cancel(team, true)

      assert Billing.entitled?(team)
    end

    test "immediate cancels now, drops entitlement, suspends boxes" do
      {team, _sub} = subscribed_team()
      bp = barkpark_fixture(team)

      assert {:ok, %Subscription{status: "canceled"}} = Billing.request_cancel(team, false)
      refute Billing.entitled?(team)
      assert reload_bp(bp).suspended
    end

    test "no subscription → {:error, :no_subscription}" do
      assert {:error, :no_subscription} = Billing.request_cancel(team_fixture(), true)
    end
  end

  ## ── Registry suspension primitives ──

  describe "Registry.suspend_team_barkparks/2 + resume_team_barkparks/1" do
    test "suspends only managed rows, leaves self_hosted/byo untouched, idempotent" do
      team = team_fixture()
      managed = barkpark_fixture(team, %{mode: "managed"})
      self_hosted = barkpark_fixture(team, %{mode: "self_hosted"})
      byo = barkpark_fixture(team, %{mode: "byo"})

      assert {:ok, 1} = Registry.suspend_team_barkparks(team, "billing_lapsed")
      assert reload_bp(managed).suspended
      refute reload_bp(self_hosted).suspended
      refute reload_bp(byo).suspended

      # Idempotent: a second call suspends nothing.
      assert {:ok, 0} = Registry.suspend_team_barkparks(team, "billing_lapsed")

      assert {:ok, 1} = Registry.resume_team_barkparks(team)
      refute reload_bp(managed).suspended
      assert {:ok, 0} = Registry.resume_team_barkparks(team)
    end

    test "is team-scoped — never touches another team's boxes" do
      team_a = team_fixture()
      team_b = team_fixture()
      bp_a = barkpark_fixture(team_a)
      bp_b = barkpark_fixture(team_b)

      {:ok, _} = Registry.suspend_team_barkparks(team_a, "billing_lapsed")
      assert reload_bp(bp_a).suspended
      refute reload_bp(bp_b).suspended
    end
  end

  ## ── Gateway request shapes (pure builder, never sent) ──

  describe "StripeGateway — portal + cancel request shapes" do
    test "create_billing_portal_session posts to /billing_portal/sessions with customer + return_url" do
      req =
        StripeGateway.build_request("/billing_portal/sessions", :post, %{
          "customer" => "cus_123",
          "return_url" => "https://barkpark.cloud/?billing=portal"
        })

      assert req.method == :post
      assert req.url == "https://api.stripe.com/v1/billing_portal/sessions"

      assert req.body ==
               "customer=cus_123&return_url=https%3A%2F%2Fbarkpark.cloud%2F%3Fbilling%3Dportal"
    end

    test "cancel at period end posts cancel_at_period_end=true to /subscriptions/:id" do
      req =
        StripeGateway.build_request("/subscriptions/sub_123", :post, %{
          "cancel_at_period_end" => true
        })

      assert req.method == :post
      assert req.url == "https://api.stripe.com/v1/subscriptions/sub_123"
      assert req.body == "cancel_at_period_end=true"
    end

    test "immediate cancel is a DELETE to /subscriptions/:id" do
      req = StripeGateway.build_request("/subscriptions/sub_123", :delete, %{})

      assert req.method == :delete
      assert req.url == "https://api.stripe.com/v1/subscriptions/sub_123"
      assert req.body == ""
    end

    test "the live portal/cancel paths fail closed with no injected client (no spend)" do
      assert {:error, :http_client_not_configured} =
               StripeGateway.create_billing_portal_session("cus_123")

      assert {:error, :http_client_not_configured} =
               StripeGateway.cancel_subscription("sub_123", at_period_end: true)
    end
  end
end
