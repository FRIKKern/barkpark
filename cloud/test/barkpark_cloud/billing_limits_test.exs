defmodule BarkparkCloud.BillingLimitsTest do
  @moduledoc """
  usage-limits-quotas: the QUOTA half of go-live — the per-plan managed-instance
  ceiling (Coolify's `Team::serverLimit` / `serverLimitReached`) and the reversible
  downgrade reconciler (Coolify's `ServerLimitCheckJob`), rebased onto main's
  suspension model (`suspended` boolean + `suspended_reason`), NOT the candidate's
  standalone `suspended_at` marker.

  Limits come from `config/config.exs`'s `:limits` map (free 1, supporter 3,
  support_plus 10, trial 1, forever ~unlimited, none 0). The StubGateway makes
  `Billing.subscribe/2` deterministic and network-free.

  These are SECURITY tests: each asserts a guard/gate that FAILS if the enforcement
  is removed (a quota can be routed around, or the two suspension axes cross-talk).
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Billing.Subscription
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

  defp team_on(plan) do
    team = team_fixture()
    {:ok, _sub} = Billing.subscribe(team, plan)
    team
  end

  # Register `n` managed barkparks for `team` via the REAL go-live path
  # (register_managed_barkpark/3), returned OLDEST-first with strictly increasing
  # `inserted_at` so newest-first suspension order is deterministic.
  defp insert_barkparks(team, n) do
    base = DateTime.truncate(DateTime.utc_now(), :microsecond)

    for i <- 1..n do
      u = System.unique_integer([:positive])
      {:ok, bp} = Registry.register_managed_barkpark(team, "BP #{u}", "bp-#{u}")

      bp
      |> Ecto.Changeset.change(inserted_at: DateTime.add(base, i, :second))
      |> Repo.update!()
    end
  end

  defp set_plan(team, plan) do
    sub = Billing.active_subscription(team)

    {:ok, _} =
      sub
      |> Subscription.changeset(%{plan: plan, status: "active", team_id: team.id})
      |> Repo.update()

    :ok
  end

  defp reload(%Barkpark{id: id}), do: Repo.get(Barkpark, id)

  ## barkpark_limit/1

  describe "barkpark_limit/1" do
    test "resolves the team's active plan against the config :limits map" do
      assert Billing.barkpark_limit(team_on("free")) == 1
      assert Billing.barkpark_limit(team_on("supporter")) == 3
      assert Billing.barkpark_limit(team_on("support_plus")) == 10
    end

    test "a team with no active subscription resolves to the 'none' ceiling (0)" do
      assert Billing.barkpark_limit(team_fixture()) == 0
    end

    test "a trial team has a real ceiling (not 0) — the signup grant can still go live" do
      # REGRESSION GUARD: main's signup grants a `trial` active sub. If `trial`
      # were absent from :limits it would resolve to 0 and 403 every trial go-live.
      assert Billing.barkpark_limit(team_on("trial")) == 1
    end
  end

  ## barkpark_limit_reached?/1

  describe "barkpark_limit_reached?/1 (inclusive >=, subscribed teams only)" do
    test "false below the ceiling, true AT it" do
      team = team_on("supporter")
      insert_barkparks(team, 2)
      refute Billing.barkpark_limit_reached?(team)

      insert_barkparks(team, 1)
      assert Billing.barkpark_limit_reached?(team)
    end

    test "an unsubscribed team is NOT quota-blocked (the 402 entitlement gate handles it)" do
      refute Billing.barkpark_limit_reached?(team_fixture())
    end

    test "reconciler-suspended instances STILL count toward the ceiling (main's suspended model)" do
      team = team_on("supporter")
      [a, _b, _c] = insert_barkparks(team, 3)
      {:ok, suspended} = Registry.suspend_barkpark(a, Billing.quota_suspended_reason())
      assert suspended.suspended == true

      # 3 held (one suspended) >= 3 → at the ceiling, the next create is blocked.
      assert Billing.barkpark_limit_reached?(team)
    end
  end

  ## register_barkpark/2 + register_managed_barkpark/3 guard (un-bypassable)

  describe "quota backstop on the create paths" do
    test "register_managed_barkpark/3 (the REAL go-live path) is quota-blocked at the ceiling" do
      team = team_on("free")
      assert {:ok, _} = Registry.register_managed_barkpark(team, "a", "a")

      # A clean {:error, :limit_reached} tuple — NOT a raise/500. This is the exact
      # branch the router's go_live `with/else` maps to a 403 in a create race.
      assert {:error, :limit_reached} = Registry.register_managed_barkpark(team, "b", "b")
      assert length(Registry.list_barkparks(team)) == 1
    end

    test "register_barkpark/2 direct is quota-blocked at the ceiling" do
      team = team_on("free")
      assert {:ok, _} = Registry.register_barkpark(team, %{name: "a", slug: "a"})

      assert {:error, :limit_reached} =
               Registry.register_barkpark(team, %{name: "b", slug: "b"})
    end

    test "the internal/agent upsert_barkpark NEW-ROW path is also quota-blocked" do
      team = team_on("free")
      {:ok, bp} = Registry.register_barkpark(team, %{name: "a", slug: "a"})

      # A NEW slug through upsert routes to register_barkpark → blocked at ceiling.
      assert {:error, :limit_reached} =
               Registry.upsert_barkpark(team, %{name: "b", slug: "b-new"})

      # But an upsert of the EXISTING slug is an UPDATE, never a new instance → OK.
      assert {:ok, bp2} = Registry.upsert_barkpark(team, %{name: "a renamed", slug: "a"})
      assert bp2.id == bp.id
      assert bp2.name == "a renamed"
    end
  end

  ## reconcile_plan_limit/1 (reversible, newest-first, quota axis only)

  describe "reconcile_plan_limit/1" do
    test "suspends the newest (count - limit) instances on a downgrade" do
      team = team_on("supporter")
      [oldest, mid, newest] = insert_barkparks(team, 3)

      set_plan(team, "free")
      assert %{suspended: 2, restored: 0} = Billing.reconcile_plan_limit(team)

      refute reload(oldest).suspended
      assert reload(mid).suspended
      assert reload(newest).suspended
      assert reload(newest).suspended_reason == "quota_exceeded"
    end

    test "re-upgrade restores exactly the QUOTA-suspended instances" do
      team = team_on("supporter")
      [oldest, mid, newest] = insert_barkparks(team, 3)

      set_plan(team, "free")
      assert %{suspended: 2} = Billing.reconcile_plan_limit(team)

      set_plan(team, "supporter")
      assert %{suspended: 0, restored: 2} = Billing.reconcile_plan_limit(team)

      refute reload(oldest).suspended
      refute reload(mid).suspended
      refute reload(newest).suspended
    end

    test "a reconcile NEVER restores a BILLING-LAPSED box (the model-clash bug)" do
      # SECURITY: the two suspension axes must not cross-talk. A billing lapse
      # suspends with reason "billing_lapsed"; a quota reconcile that is AT/UNDER
      # limit must leave those boxes suspended.
      team = team_on("supporter")
      insert_barkparks(team, 3)
      {:ok, 3} = Registry.suspend_team_barkparks(team, "billing_lapsed")

      # Under the supporter ceiling now (0 live), so reconcile is in its restore
      # branch — but it must touch ONLY quota_exceeded rows, of which there are none.
      assert %{suspended: 0, restored: 0} = Billing.reconcile_plan_limit(team)

      # All three stay suspended, reason untouched.
      still = Registry.list_barkparks(team)
      assert Enum.all?(still, & &1.suspended)
      assert Enum.all?(still, &(&1.suspended_reason == "billing_lapsed"))
    end

    test "idempotent no-op when count <= limit" do
      team = team_on("supporter")
      insert_barkparks(team, 2)
      assert %{suspended: 0, restored: 0} = Billing.reconcile_plan_limit(team)
    end
  end
end
