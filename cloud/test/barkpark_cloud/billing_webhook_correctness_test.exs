defmodule BarkparkCloud.BillingWebhookCorrectnessTest do
  @moduledoc """
  Four billing-state defects from the r2c control-plane audit (2026-09-30):

    * task-731eb98d2a7f7097 — a redelivered checkout.session.completed for a
      subscription that has since been canceled resurrected it: a fresh active
      row, billing_lapsed lifted, the team entitled with nothing paying.
    * task-8b4a4776ba35a9cd — a team that already PAYS could open a second
      Checkout (billed twice), and the second completion was a silent
      :already_active.
    * task-30d4058bf64c317b — a verified event with no team_id/plan metadata
      was {:error, :missing_metadata}, which the route answers 400: Stripe
      retries for days and may disable the endpoint.
    * task-722ae49c93fe55d0 — reconcile_plan_limit restored EVERY quota-suspended
      box whenever the live fleet fit, not at most the headroom.
  """
  use BarkparkCloud.DataCase, async: false

  import ExUnit.CaptureLog

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Billing.{StubGateway, Subscription}
  alias BarkparkCloud.Registry.Barkpark

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp sig, do: StubGateway.test_signature()

  defp event(type, object) do
    Jason.encode!(%{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => type,
      "data" => %{"object" => object}
    })
  end

  defp completed(team_id, plan, cus, sub) do
    event("checkout.session.completed", %{
      "metadata" => %{"team_id" => team_id, "plan" => plan},
      "customer" => cus,
      "subscription" => sub
    })
  end

  describe "stale / redelivered checkout sessions (task-731eb98d2a7f7097)" do
    test "completed -> deleted -> the SAME completed again does not resurrect the subscription" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      raw = completed(team.id, "supporter", "cus_stale", "sub_stale")

      assert {:ok, %Subscription{status: "active"}} = Billing.handle_webhook(raw, sig())

      assert {:ok, %Subscription{status: "canceled"}} =
               Billing.handle_webhook(
                 event("customer.subscription.deleted", %{"customer" => "cus_stale"}),
                 sig()
               )

      assert Repo.get!(Barkpark, bp.id).suspended

      capture_log(fn -> assert {:ok, :ignored} = Billing.handle_webhook(raw, sig()) end)

      refute Billing.entitled?(team)
      assert Repo.get!(Barkpark, bp.id).suspended
      assert is_nil(Billing.active_subscription(team))
    end

    test "CONTROL: a resubscribe through a NEW subscription still activates" do
      team = team_fixture()
      _ = Billing.handle_webhook(completed(team.id, "supporter", "cus_a", "sub_a"), sig())

      _ =
        Billing.handle_webhook(
          event("customer.subscription.deleted", %{"customer" => "cus_a"}),
          sig()
        )

      assert {:ok, %Subscription{status: "active"}} =
               Billing.handle_webhook(completed(team.id, "supporter", "cus_b", "sub_b"), sig())

      assert Billing.entitled?(team)
    end
  end

  describe "double checkout (task-8b4a4776ba35a9cd)" do
    test "checkout/2 refuses a team that already pays" do
      team = team_fixture()
      {:ok, _} = Billing.handle_webhook(completed(team.id, "supporter", "cus_p", "sub_p"), sig())

      assert {:error, :already_subscribed} = Billing.checkout(team, "support_plus")
    end

    test "a second completed checkout on a DIFFERENT subscription is logged loudly, not silent" do
      team = team_fixture()
      {:ok, _} = Billing.handle_webhook(completed(team.id, "supporter", "cus_1", "sub_1"), sig())

      log =
        capture_log(fn ->
          assert {:ok, :already_active} =
                   Billing.handle_webhook(
                     completed(team.id, "support_plus", "cus_2", "sub_2"),
                     sig()
                   )
        end)

      assert log =~ "DUPLICATE PAID SUBSCRIPTION"
      assert log =~ "sub_1" and log =~ "sub_2"
    end
  end

  describe "verified events without metadata (task-30d4058bf64c317b)" do
    test "customer.subscription.created{active} with no metadata is acknowledged, not an error" do
      team = team_fixture()
      {:ok, sub} = Billing.subscribe(team, "supporter")

      raw =
        event("customer.subscription.created", %{
          "customer" => sub.gateway_customer_id,
          "status" => "active"
        })

      capture_log(fn -> assert {:ok, :ignored} = Billing.handle_webhook(raw, sig()) end)
      assert Repo.get!(Subscription, sub.id).status == "active"
    end
  end

  describe "quota restore headroom (task-722ae49c93fe55d0)" do
    test "restores at most limit - live quota-suspended boxes" do
      team = team_fixture()
      {:ok, _} = Billing.subscribe(team, "support_plus")
      bps = for _ <- 1..4, do: barkpark_fixture(team)

      # Downgrade the live row to a 3-box plan and quota-suspend the newest box,
      # then ALSO quota-suspend one more by hand: 2 live, 2 quota-suspended.
      sub = Billing.active_subscription(team)
      {:ok, _} = sub |> Subscription.changeset(%{plan: "supporter"}) |> Repo.update()

      [_, _, third, fourth] = Enum.sort_by(bps, & &1.inserted_at, {:asc, DateTime})

      for bp <- [third, fourth] do
        {:ok, _} = Registry.suspend_barkpark(bp, Billing.quota_suspended_reason())
      end

      Billing.reconcile_plan_limit(team)

      live = Registry.list_barkparks(team) |> Enum.reject(& &1.suspended)

      assert length(live) == 3,
             "a 3-box plan with 2 live has headroom for exactly 1; got #{length(live)} live"
    end
  end
end
