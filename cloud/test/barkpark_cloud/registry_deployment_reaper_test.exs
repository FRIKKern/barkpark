defmodule BarkparkCloud.RegistryDeploymentReaperTest do
  @moduledoc """
  oban-substrate — the deploy-queue stale-claim sweep
  (`Registry.reap_stale_deployments/0`) + its `StaleDeploymentReaper` worker.

  Proves, against the real Sandbox, the epoch-fencing lease the claim docstrings
  already promise:

  * a stale "building" row (crashed off-box builder) under budget is REQUEUED,
    and — the fence — a second worker re-claims it while the OLD worker's stale
    epoch fails `transition_deployment_fenced/4`;
  * a stale "building" row at the claim budget is FAILED (terminal), not looped;
  * a stale "pushing" row (crashed on-box agent) has its claim RELEASED (status
    stays "pushing") and becomes re-claimable via the agent claim path;
  * a FRESH claim (live worker) is NEVER yanked.

  `async: true` is safe because Oban runs in `:manual` mode (config/test.exs) —
  `perform_job/2` runs the worker synchronously inside this test's transaction.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Workers.StaleDeploymentReaper

  ## Fixtures (mirror RouterAgentRuntimeTest)

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

  defp site_fixture(barkpark) do
    n = System.unique_integer([:positive])
    {:ok, site} = Registry.create_site(barkpark, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # {barkpark, site} — the minimum tree a Deployment hangs off.
  defp setup_site do
    bp = team_fixture() |> barkpark_fixture()
    {bp, site_fixture(bp)}
  end

  # Backdate a deployment's claimed_at past the staleness threshold so the reaper
  # treats its claim as abandoned.
  defp backdate(deployment_id) do
    stale_at =
      DateTime.add(DateTime.utc_now(), -(Registry.deployment_stale_after_seconds() + 60), :second)
      |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(d in Deployment, where: d.id == ^deployment_id),
      set: [claimed_at: stale_at]
    )
  end

  ## 1. Cron wiring — the worker is scheduled every minute on the maintenance queue.

  test "reaper is registered every minute on the maintenance queue" do
    crontab =
      Application.fetch_env!(:barkpark_cloud, Oban)[:plugins]
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> opts[:crontab]
        _ -> nil
      end)

    assert {"* * * * *", StaleDeploymentReaper} in crontab
    assert Ecto.Changeset.get_field(StaleDeploymentReaper.new(%{}), :queue) == "maintenance"
  end

  ## 2. (a) Requeue + fence — a stale building row is re-queued, and the old
  ##        worker's stale-epoch write is fenced out after a fresh re-claim.

  test "stale building deployment is requeued, and the old builder's epoch is fenced" do
    {_bp, site} = setup_site()
    {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})

    {:ok, claimed} = Registry.claim_next_deployment("builder-1")
    assert claimed.status == "building"
    old_epoch = claimed.claim_epoch
    backdate(claimed.id)

    assert {:ok, %{failed: 0, requeued: 1, released: 0}} =
             perform_job(StaleDeploymentReaper, %{})

    requeued = Repo.get(Deployment, claimed.id)
    assert requeued.status == "queued"
    assert is_nil(requeued.claim_worker)
    assert is_nil(requeued.claimed_at)
    # claim_epoch untouched by the sweep — the next claim bumps it.
    assert requeued.claim_epoch == old_epoch

    # A fresh worker re-claims (bumping the epoch past the old worker's view)...
    {:ok, reclaimed} = Registry.claim_next_deployment("builder-2")
    assert reclaimed.id == claimed.id
    assert reclaimed.claim_epoch == old_epoch + 1

    # ...so the resurrected old builder's fenced write is rejected.
    assert {:error, :stale_epoch} =
             Registry.transition_deployment_fenced(
               claimed.id,
               "builder-1",
               old_epoch,
               %{status: "pushing"}
             )
  end

  ## 3. (b) Attempt budget — a stale building row at the claim cap is failed.

  test "stale building deployment at the claim budget is failed, not requeued" do
    {_bp, site} = setup_site()
    {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, claimed} = Registry.claim_next_deployment("builder-1")

    # Pin claim_epoch at the cap so the sweep fails (not requeues) it.
    Repo.update_all(
      from(d in Deployment, where: d.id == ^claimed.id),
      set: [claim_epoch: Registry.max_deploy_claims()]
    )

    backdate(claimed.id)

    assert {:ok, %{failed: 1, requeued: 0, released: 0}} =
             perform_job(StaleDeploymentReaper, %{})

    failed = Repo.get(Deployment, claimed.id)
    assert failed.status == "failed"
    assert failed.failure_reason =~ "exceeded max deploy claim attempts"
    assert is_nil(failed.claim_worker)
    assert is_nil(failed.claimed_at)
  end

  ## 4. (c) Agent claim release — a stale pushing row is released (status stays
  ##        "pushing") and re-claimable via the agent claim path.

  test "stale pushing deployment has its agent claim released and is re-claimable" do
    {bp, site} = setup_site()
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, _d} = Registry.transition_deployment(d, %{status: "pushing", image_tag: "img-1"})

    {:ok, claimed} = Registry.claim_pending_deployment_for_barkpark(bp, "agent-1")
    refute is_nil(claimed.claim_worker)
    backdate(claimed.id)

    assert {:ok, %{failed: 0, requeued: 0, released: 1}} =
             perform_job(StaleDeploymentReaper, %{})

    released = Repo.get(Deployment, claimed.id)
    assert released.status == "pushing"
    assert is_nil(released.claim_worker)
    assert is_nil(released.claimed_at)

    # A fresh agent re-claims the released row.
    assert {:ok, reclaimed} = Registry.claim_pending_deployment_for_barkpark(bp, "agent-2")
    assert reclaimed.id == claimed.id
  end

  ## 5. (d) Fresh claim — a live worker is never yanked.

  test "a fresh (non-stale) claim is left untouched" do
    {_bp, site} = setup_site()
    {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, claimed} = Registry.claim_next_deployment("builder-live")

    assert {:ok, %{failed: 0, requeued: 0, released: 0}} =
             perform_job(StaleDeploymentReaper, %{})

    fresh = Repo.get(Deployment, claimed.id)
    assert fresh.status == "building"
    assert fresh.claim_worker == "builder-live"
  end
end
