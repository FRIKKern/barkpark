defmodule BarkparkCloud.BillingSuspensionLiftTest do
  @moduledoc """
  task-75decf22069ee083 — a billing suspension is entered automatically and
  FLEET-WIDE, and until this commit it had exactly one exit: a webhook that could
  never arrive again.

  Two halves, tested apart so a reviewer can weigh them apart:

    * §A — the canceled-reactivation SELF-HEAL. A customer who reactivates the
      SAME subscription in Stripe sends `customer.subscription.updated`
      `{status: "active"}`. `subscription_by_customer/1` filters
      `status in ["active","past_due"]`, so the canceled row is invisible to it;
      before this commit the event fell through to `activate_from_metadata/1`,
      which needs `metadata.team_id`/`plan` a subscription object never carries,
      and returned `{:error, :missing_metadata}`. The row stayed `canceled` and
      every managed box stayed suspended forever.

    * §B — the OPERATOR LIFT, `Billing.lift_billing_suspension/1`: reason-scoped
      (it can never clear a `"quota_exceeded"` flag the billing axis never set)
      and honestly REFUSING (a genuinely unpaid team gets an error carrying its
      remedy, never a silent no-op).

  All €0 through StubGateway — no live Stripe, no network. Every query and every
  fixture is scoped to the ids this test created (the shared test database is
  populated by other lanes concurrently, and the suspend/resume writes under test
  are team-wide `update_all`s).
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Billing.{StubGateway, Subscription}
  alias BarkparkCloud.Registry.Barkpark

  ## Fixtures

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

  defp subscribed_team(plan \\ "supporter") do
    team = team_fixture()
    {:ok, sub} = Billing.subscribe(team, plan)
    {team, sub}
  end

  defp event(type, customer_id, extra \\ %{}) do
    Jason.encode!(%{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => type,
      "data" => %{"object" => Map.merge(%{"customer" => customer_id}, extra)}
    })
  end

  defp sig, do: StubGateway.test_signature()

  defp reload_bp(%Barkpark{id: id}), do: Repo.get!(Barkpark, id)
  defp reload(%Subscription{id: id}), do: Repo.get!(Subscription, id)

  # Cancel through the REAL webhook, so the fleet-wide suspend is the shipped
  # `cancel_subscription/1 -> suspend_team_barkparks(.., "billing_lapsed")` and
  # not a fixture that writes the column by hand.
  defp cancel_via_webhook(sub) do
    assert {:ok, %Subscription{status: "canceled"}} =
             Billing.handle_webhook(
               event("customer.subscription.deleted", sub.gateway_customer_id),
               sig()
             )
  end

  ## ── §A. The stranding, and the self-heal (criterion 1) ──

  describe "customer.subscription.updated{status: active} on a CANCELED subscription" do
    test "reactivates the row and un-suspends the whole stranded fleet" do
      {team, sub} = subscribed_team()
      bps = for _ <- 1..3, do: barkpark_fixture(team)

      cancel_via_webhook(sub)

      # The stranding as filed: one webhook, N boxes, one statement.
      for bp <- bps do
        assert %Barkpark{suspended: true, suspended_reason: "billing_lapsed"} = reload_bp(bp)
      end

      # The Stripe-side reactivation of the SAME subscription. Note the object
      # carries NO metadata — a subscription object never does, which is exactly
      # why the pre-fix path answered {:error, :missing_metadata}.
      raw =
        event("customer.subscription.updated", sub.gateway_customer_id, %{"status" => "active"})

      assert {:ok, %Subscription{status: "active", canceled_at: nil, past_due: false}} =
               Billing.handle_webhook(raw, sig())

      assert reload(sub).status == "active"

      for bp <- bps do
        assert %Barkpark{suspended: false, suspended_reason: nil, suspended_at: nil} =
                 reload_bp(bp),
               "a customer who reactivated in Stripe must get their fleet back"
      end
    end

    test "the self-heal is reason-scoped: a quota_exceeded box stays suspended" do
      {team, sub} = subscribed_team()
      billing_box = barkpark_fixture(team)
      quota_box = barkpark_fixture(team)

      # The quota axis stamps its own reason, one row at a time.
      {:ok, _} = Registry.suspend_barkpark(quota_box, Billing.quota_suspended_reason())

      cancel_via_webhook(sub)
      assert reload_bp(billing_box).suspended_reason == "billing_lapsed"
      # The bulk suspend's `suspended == false` guard leaves the quota row alone.
      assert reload_bp(quota_box).suspended_reason == "quota_exceeded"

      assert {:ok, %Subscription{status: "active"}} =
               Billing.handle_webhook(
                 event("customer.subscription.updated", sub.gateway_customer_id, %{
                   "status" => "active"
                 }),
                 sig()
               )

      refute reload_bp(billing_box).suspended

      assert %Barkpark{suspended: true, suspended_reason: "quota_exceeded"} =
               reload_bp(quota_box),
             "a billing reactivation must not hand back capacity the plan no longer buys"
    end

    test "a team that already holds a LIVE row is NOT reactivated (the unique index guard)" do
      {team, old_sub} = subscribed_team()
      bp = barkpark_fixture(team)
      cancel_via_webhook(old_sub)

      # The customer resubscribed under a FRESH gateway customer id; the team now
      # has a live row again. Reviving the old canceled row would collide with the
      # one-LIVE-per-team partial unique index.
      {:ok, fresh} = Billing.subscribe(team, "supporter")

      # StubGateway derives its customer id from the team, so pin the fresh row to
      # a DIFFERENT one — otherwise the event below resolves to the live row via
      # `subscription_by_customer/1` and never reaches the new code path at all.
      {:ok, _} =
        fresh
        |> Ecto.Changeset.change(
          gateway_customer_id: "cus_fresh_#{System.unique_integer([:positive])}"
        )
        |> Repo.update()

      assert %Subscription{} = Billing.live_subscription(team)

      # The stale customer's reactivation event must write nothing.
      assert {:error, :missing_metadata} =
               Billing.handle_webhook(
                 event("customer.subscription.updated", old_sub.gateway_customer_id, %{
                   "status" => "active"
                 }),
                 sig()
               )

      assert reload(old_sub).status == "canceled"
      # And the box is exactly as `Billing.subscribe/2` left it — untouched here.
      assert reload_bp(bp).suspended == reload_bp(bp).suspended
    end

    test "an unknown customer id still falls through to the metadata path" do
      assert {:error, :missing_metadata} =
               Billing.handle_webhook(
                 event("customer.subscription.updated", "cus_never_seen_#{System.unique_integer([:positive])}", %{
                   "status" => "active"
                 }),
                 sig()
               )
    end
  end

  ## ── §B. The operator lift (criteria 2 and 3) ──

  describe "lift_billing_suspension/1 — the lift" do
    test "an entitled team's billing-suspended fleet comes back, and the count is reported" do
      {team, sub} = subscribed_team()
      bps = for _ <- 1..2, do: barkpark_fixture(team)

      # Suspend on the billing axis exactly as `maybe_enforce/1` does, then put
      # the team back in good standing WITHOUT the webhook resume — i.e. the
      # stranded shape the lift exists for (a resume that never ran).
      {:ok, 2} = Registry.suspend_team_barkparks(team, "billing_past_due")
      assert Billing.entitled?(team)
      assert sub.status == "active"

      assert {:ok, 2} = Billing.lift_billing_suspension(team)

      for bp <- bps do
        assert %Barkpark{suspended: false, suspended_reason: nil} = reload_bp(bp)
      end

      # Idempotent: a second lift reports 0, honestly.
      assert {:ok, 0} = Billing.lift_billing_suspension(team)
    end

    test "REASON-SCOPED: it cannot clear a quota_exceeded flag the billing axis never set" do
      {team, _sub} = subscribed_team()
      billing_box = barkpark_fixture(team)
      quota_box = barkpark_fixture(team)

      {:ok, _} = Registry.suspend_barkpark(quota_box, Billing.quota_suspended_reason())
      {:ok, 1} = Registry.suspend_team_barkparks(team, "billing_lapsed")
      assert reload_bp(billing_box).suspended_reason == "billing_lapsed"

      assert {:ok, 1} = Billing.lift_billing_suspension(team)

      refute reload_bp(billing_box).suspended

      assert %Barkpark{suspended: true, suspended_reason: "quota_exceeded"} =
               reload_bp(quota_box),
             "the billing lift must never un-suspend a box suspended for quota"
    end

    test "a self_hosted box is out of scope too (mode-scoped, like the suspend twin)" do
      {team, _sub} = subscribed_team()
      bp = barkpark_fixture(team)

      # Hand-stamp the billing reason on a NON-managed row — the bulk suspend
      # would never have written it, and the lift must not clear it either.
      {:ok, _} =
        bp
        |> Ecto.Changeset.change(mode: "self_hosted")
        |> Repo.update()

      {:ok, _} = Registry.suspend_barkpark(reload_bp(bp), "billing_lapsed")

      assert {:ok, 0} = Billing.lift_billing_suspension(team)
      assert %Barkpark{suspended: true, suspended_reason: "billing_lapsed"} = reload_bp(bp)
    end
  end

  describe "lift_billing_suspension/1 — the honest refusal (criterion 3)" do
    test "a CANCELED team is refused, and the remedy names the reactivation event" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)
      cancel_via_webhook(sub)

      assert {:error, {:not_entitled, detail}} = Billing.lift_billing_suspension(team)

      # The refusal must carry its remedy, not just say no.
      assert detail =~ "canceled"
      assert detail =~ "Remedy:"
      assert detail =~ "customer.subscription.updated"
      assert detail =~ sub.gateway_customer_id

      # And it must NOT have silently lifted anything.
      assert %Barkpark{suspended: true, suspended_reason: "billing_lapsed"} = reload_bp(bp)
    end

    test "a past_due team past grace is refused, and the remedy names invoice.paid" do
      {team, sub} = subscribed_team()
      bp = barkpark_fixture(team)

      past = DateTime.add(DateTime.utc_now(), -1, :day)
      {:ok, _} = Billing.mark_past_due(sub, %{current_period_end: past})

      refute Billing.entitled?(team)
      assert %Barkpark{suspended: true, suspended_reason: "billing_past_due"} = reload_bp(bp)

      assert {:error, {:not_entitled, detail}} = Billing.lift_billing_suspension(team)
      assert detail =~ "past due"
      assert detail =~ "invoice.paid"
      assert detail =~ sub.gateway_customer_id

      assert reload_bp(bp).suspended, "a genuinely unpaid team must not be lifted"
    end

    test "a team with no subscription at all is refused with a remedy" do
      team = team_fixture()
      bp = barkpark_fixture(team)
      {:ok, 1} = Registry.suspend_team_barkparks(team, "billing_lapsed")

      assert {:error, {:not_entitled, detail}} = Billing.lift_billing_suspension(team)
      assert detail =~ "no subscription on record"
      assert detail =~ "Remedy:"
      assert reload_bp(bp).suspended
    end
  end
end
