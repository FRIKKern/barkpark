defmodule BarkparkCloud.SubscriptionStatusReaderAuditTest do
  @moduledoc """
  task-267f329679b38a00 — THE READER AUDIT, DRIVEN RATHER THAN ASSERTED IN PROSE.

  The row was filed when `TrialExpiryWorker` wrote NOTHING to `subscriptions`, so
  a lapsed trial kept `status "active"` FOREVER and every predicate reading that
  column answered "subscribed" for every team that had ever signed up. That half
  LANDED in 66391dd8c (2026-09-02, PR #14853): the worker now finalises the row
  (`Billing.expire_trial/2` → `canceled`) once the team has no boxes left. What
  this file measures is what is LEFT.

  TWO CLASSES OF READER, and the difference is the whole audit:

    * COLUMN READERS — `Billing.active_subscription/1` (`status == "active"`),
      `Billing.live_subscription/1` (`status IN ('active','past_due')`) and
      everything built on them (`barkpark_limit/1`, `Accounts.onboarding_status/1`'s
      `has_subscription`, `/v1/subscription`'s `live_subscription/1` lookup), plus
      `Registry.stale_online_barkparks/1`'s `s.status == "active"` join and the
      raw-SQL `EXISTS (… status IN ('active','past_due'))` prefilter in
      `Registry.provisioning_fqdn_claim/2`. These are TRUE for a lapsed trial
      that has not been finalised yet.
    * CLOCK READERS — `Billing.entitled?/1`, whose `plan: "trial"` clause answers
      off `current_period_end`. FALSE the instant the window closes, finalised or
      not. PR #14574 routed the ghost carve-out's `:active_subscription` leg
      through it; that is the one call site already corrected.

  THE RESIDUAL WINDOW IS NO LONGER UNBOUNDED — it is exactly "lapsed, boxes not
  yet gone", because finalisation is deliberately gated on the teardown having
  COMPLETED (that gate is the convert-just-after-expiry race guard). Both arms
  below pin that: with a box up the column still reads `active`; with no boxes
  the same pass reconciles it and every column reader flips in one step.

  UNMEASURED ON PROD. cch-w50 counted fifteen lapsed-`active` rows on 2026-08-07;
  this suite has no control-plane access, so today's count is UNKNOWN here. Every
  number below is a FIXTURE measurement.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Billing
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Repo
  alias BarkparkCloud.TrialFixtures
  alias BarkparkCloud.Workers.TrialExpiryWorker

  defp box(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp status(sub), do: Repo.get!(Subscription, sub.id).status

  # `Accounts.onboarding_status/1`'s subscription step — `has_subscription` is
  # `not is_nil(Billing.active_subscription(team))`, i.e. a pure column read.
  defp onboarding_subscribed?(team) do
    Accounts.onboarding_status(team).steps
    |> Enum.find(&(&1.key == "subscription"))
    |> Map.fetch!(:done)
  end

  describe "the fixture hole (c3) — create_team/1 grants nothing, the helper grants a real trial" do
    test "Accounts.create_team/1 leaves the team with NO subscription row at all" do
      {:ok, team} =
        Accounts.create_team(%{name: "Bare", slug: "bare-#{System.unique_integer([:positive])}"})

      assert is_nil(Billing.active_subscription(team)),
             "if this ever changes, the audit below stops being about the fixture hole"

      assert is_nil(Billing.live_subscription(team))
      refute Billing.entitled?(team)
    end

    test "TrialFixtures.team_with_live_trial/0 exercises the status-reading predicates" do
      {team, sub} = TrialFixtures.team_with_live_trial()

      assert sub.plan == "trial"
      assert sub.status == "active"
      # Column readers AND the clock reader agree while the window is open.
      assert %Subscription{} = Billing.active_subscription(team)
      assert %Subscription{} = Billing.live_subscription(team)
      assert Billing.entitled?(team)
    end
  end

  describe "c1 — the residual lie window: lapsed, boxes NOT yet gone" do
    test "the worker leaves status 'active' while a box is up, and the column readers say 'subscribed'" do
      {team, sub} = TrialFixtures.team_with_lapsed_trial()
      _bp = box(team)

      assert {:ok, %{expired: 1, teardowns: 1, finalized: 0}} =
               perform_job(TrialExpiryWorker, %{})

      # THE COLUMN STILL LIES — on purpose: finalising before the teardown
      # completes would break the convert-just-after-expiry race guard.
      assert status(sub) == "active"

      # COLUMN READERS — every one of these is WRONG about this team right now.
      assert %Subscription{} = Billing.active_subscription(team),
             "active_subscription/1 filters status == 'active' — the lapsed row passes"

      assert %Subscription{} = Billing.live_subscription(team),
             "live_subscription/1 filters status IN ('active','past_due') — same"

      assert Billing.barkpark_limit(team) == 1,
             "barkpark_limit/1 resolves the plan off active_subscription/1, so a lapsed trial keeps its ceiling"

      assert onboarding_subscribed?(team),
             "onboarding's has_subscription is not is_nil(active_subscription/1)"

      assert Enum.any?(
               Registry.stale_online_barkparks(DateTime.utc_now()),
               &(&1.team_id == team.id)
             ),
             "stale_online_barkparks/1 joins subscriptions on s.status == 'active'"

      # CLOCK READER — the only one that is right.
      refute Billing.entitled?(team),
             "entitled?/1 answers off current_period_end, so it is correct through the whole window"
    end
  end

  describe "c1 — the reconciled case: lapsed with ZERO boxes is finalised in the SAME pass" do
    test "every column reader flips in one step, and entitled?/1 never moves" do
      {team, sub} = TrialFixtures.team_with_lapsed_trial()

      # BEFORE: the column says subscribed, the clock says no.
      assert %Subscription{} = Billing.active_subscription(team)
      assert Billing.barkpark_limit(team) == 1
      refute Billing.entitled?(team)

      assert {:ok, %{expired: 1, teardowns: 0, finalized: 1}} =
               perform_job(TrialExpiryWorker, %{})

      # AFTER: the column is reconciled and every column reader agrees with the clock.
      assert status(sub) == "canceled"
      assert is_nil(Billing.active_subscription(team))
      assert is_nil(Billing.live_subscription(team))
      assert Billing.barkpark_limit(team) == 0, "the plan resolves to the 'none' ceiling"
      refute onboarding_subscribed?(team)

      refute Billing.entitled?(team), "UNCHANGED across the write — false before, false after"
    end

    test "the finalised row is gone from the hourly scan, so nothing re-reads it forever" do
      {_team, sub} = TrialFixtures.team_with_lapsed_trial()

      assert Enum.any?(Billing.active_trials(DateTime.utc_now()), &(&1.id == sub.id))
      assert {:ok, %{finalized: 1}} = perform_job(TrialExpiryWorker, %{})
      refute Enum.any?(Billing.active_trials(DateTime.utc_now()), &(&1.id == sub.id))
    end
  end
end
