defmodule BarkparkCloud.BillingReconcileIsolationTest do
  @moduledoc """
  wbq-cloud-billing-reconcile-isolation: `reconcile_plan_limit/1` hard-matched
  `{:ok, bp} = Registry.suspend_barkpark/unsuspend_barkpark` inside its
  `Enum.map`. Both are typed `{:ok, Barkpark.t()} | {:error,
  Ecto.Changeset.t()}` (`Registry.suspend_barkpark/2`,
  `Registry.unsuspend_barkpark/1`) and reachable from the Stripe webhook path
  (`activate_from_session/4` → `reconcile_plan_limit/1`), so ONE row's
  changeset failure raised a `MatchError` and sank the WHOLE team's
  suspend/restore batch.

  Under Billing's OWN call sites the changeset can't actually fail today (the
  reason is a fixed, short constant) — this is defensive debt, guarding a
  future validation change, not a live bug. To exercise the isolation for
  real, this test swaps in a fake registry (via the `:registry` test-only
  config key `Billing.registry/0` reads, mirroring the `gateway/0` test-swap
  seam already in this file) that forces exactly ONE barkpark's
  suspend/unsuspend to return `{:error, changeset}` while delegating every
  OTHER barkpark to the real `BarkparkCloud.Registry` — so the surrounding
  rows transition for real, not a stub of the whole reconcile.
  """
  # async: false — the FailingRegistry below IS process-scoped (it delegates to
  # the real Registry unless the CALLING process opts in), but the `Billing`
  # config swap further down is not: that one is ONE value for the whole node.
  # Ratchet: scripts/async_env_seam_scan.exs.
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.Registry.Barkpark

  defmodule FailingRegistry do
    @moduledoc """
    Delegates to the REAL `Registry` for every barkpark except the one whose id
    matches the CALLING PROCESS's `:billing_reconcile_isolation_fail_id`
    dictionary entry — that one gets a genuine `{:error, %Ecto.Changeset{}}`
    instead of touching the DB. Scoped via the process dictionary (not a
    shared/global id) so this is safe even if another async test's
    `reconcile_plan_limit/1` call happens to run while this module is
    globally configured — a process with no such key set always delegates.
    """
    def suspend_barkpark(%Barkpark{id: id} = bp, reason) do
      if id == fail_id() do
        {:error, failing_changeset(bp)}
      else
        Registry.suspend_barkpark(bp, reason)
      end
    end

    def unsuspend_barkpark(%Barkpark{id: id} = bp) do
      if id == fail_id() do
        {:error, failing_changeset(bp)}
      else
        Registry.unsuspend_barkpark(bp)
      end
    end

    defp fail_id, do: Process.get(:billing_reconcile_isolation_fail_id)

    defp failing_changeset(bp) do
      bp
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:suspended_reason, "forced failure for isolation test")
    end
  end

  ## Fixtures (mirrors billing_limits_test.exs)

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp team_on(plan) do
    team = team_fixture()
    {:ok, _sub} = Billing.subscribe(team, plan)
    team
  end

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

  # Swap the real Registry for FailingRegistry for the duration of `fun`,
  # scoped to THIS test process only (see FailingRegistry's moduledoc) and
  # restored afterward even if `fun` raises.
  defp with_forced_failure(barkpark, fun) do
    original = Application.get_env(:barkpark_cloud, Billing, [])
    Process.put(:billing_reconcile_isolation_fail_id, barkpark.id)

    Application.put_env(
      :barkpark_cloud,
      Billing,
      Keyword.put(original, :registry, FailingRegistry)
    )

    try do
      fun.()
    after
      Application.put_env(:barkpark_cloud, Billing, original)
      Process.delete(:billing_reconcile_isolation_fail_id)
    end
  end

  describe "reconcile_plan_limit/1 suspend-branch isolation" do
    test "one barkpark's suspend failure is logged and skipped — the rest still suspend" do
      # support_plus (limit 10) so all 4 can be REGISTERED before the downgrade.
      team = team_on("support_plus")
      # Ascending inserted_at: oldest → second → third → newest.
      [oldest, second, third, newest] = insert_barkparks(team, 4)

      set_plan(team, "free")

      # 4 live, limit 1 → overflow 3 → the three MOST RECENT are candidates
      # (newest, third, second); `oldest` is never a candidate at all.
      # BEFORE the fix, forcing `second`'s suspend to fail raised MatchError
      # and sank `third`/`newest` too. AFTER the fix it isolates `second`.
      result =
        with_forced_failure(second, fn ->
          Billing.reconcile_plan_limit(team)
        end)

      assert %{suspended: 2, restored: 0} = result

      refute reload(oldest).suspended
      refute reload(second).suspended
      assert reload(third).suspended
      assert reload(newest).suspended
      assert reload(newest).suspended_reason == "quota_exceeded"
    end
  end

  describe "reconcile_plan_limit/1 restore-branch isolation" do
    test "one barkpark's unsuspend failure is logged and skipped — the rest still restore" do
      team = team_on("supporter")
      [oldest, mid, newest] = insert_barkparks(team, 3)

      set_plan(team, "free")
      # Quota-suspends `mid` and `newest` (limit 1, overflow 2); `oldest` stays live.
      assert %{suspended: 2} = Billing.reconcile_plan_limit(team)

      set_plan(team, "supporter")

      # Both `mid`/`newest` are now quota-suspended and candidates to restore.
      # BEFORE the fix, forcing `mid`'s unsuspend to fail raised MatchError and
      # sank `newest`'s restore too. AFTER the fix it isolates `mid`'s failure.
      result =
        with_forced_failure(mid, fn ->
          Billing.reconcile_plan_limit(team)
        end)

      assert %{suspended: 0, restored: 1} = result

      refute reload(oldest).suspended
      assert reload(mid).suspended
      refute reload(newest).suspended
    end
  end
end
