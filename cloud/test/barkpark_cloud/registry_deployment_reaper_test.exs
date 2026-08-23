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

  ## 4b. (iii) Agent-claim budget — a stale pushing row at the claim cap is FAILED
  ##          (terminal, actionable reason), not re-released forever. This is the
  ##          eternal-spinner class: a permanently-down box the agent path keeps
  ##          re-claiming and never delivering.

  test "stale pushing deployment at the claim budget is failed with an actionable reason" do
    {bp, site} = setup_site()
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, _d} = Registry.transition_deployment(d, %{status: "pushing", image_tag: "img-1"})
    {:ok, claimed} = Registry.claim_pending_deployment_for_barkpark(bp, "agent-1")

    # Pin claim_epoch at the cap so the sweep fails (not releases) it.
    Repo.update_all(
      from(x in Deployment, where: x.id == ^claimed.id),
      set: [claim_epoch: Registry.max_deploy_claims()]
    )

    backdate(claimed.id)

    assert {:ok, %{pushing_failed: 1, released: 0}} = perform_job(StaleDeploymentReaper, %{})

    failed = Repo.get(Deployment, claimed.id)
    assert failed.status == "failed"
    assert failed.failure_reason =~ "instance unreachable"
    assert is_nil(failed.claim_worker)
    assert is_nil(failed.claimed_at)
  end

  ## 4c. (iv) Under budget still retries — a stale pushing row below the cap is
  ##          RELEASED (a transient blip must still be retried), never failed.

  test "stale pushing deployment under the claim budget is released, not failed" do
    {bp, site} = setup_site()
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, _d} = Registry.transition_deployment(d, %{status: "pushing", image_tag: "img-1"})
    {:ok, claimed} = Registry.claim_pending_deployment_for_barkpark(bp, "agent-1")

    # One claim → claim_epoch is 1, well under the budget.
    assert claimed.claim_epoch < Registry.max_deploy_claims()
    backdate(claimed.id)

    assert {:ok, %{pushing_failed: 0, released: 1}} = perform_job(StaleDeploymentReaper, %{})

    released = Repo.get(Deployment, claimed.id)
    assert released.status == "pushing"
    assert is_nil(released.claim_worker)
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

  ## 6. (iv) No build source — a queued row with no artifact whose site has no
  ##         connected repo can never build, so it is FAILED (not staleness-gated).

  test "a queued row with no artifact and no connected repo is failed" do
    {_bp, site} = setup_site()
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})
    assert d.status == "queued"

    assert {:ok, %{no_source_failed: 1}} = perform_job(StaleDeploymentReaper, %{})

    failed = Repo.get(Deployment, d.id)
    assert failed.status == "failed"
    assert failed.failure_reason =~ "no build source"
  end

  test "a queued row WITH an artifact_url is left untouched" do
    {_bp, site} = setup_site()
    {:ok, d} = Registry.create_deployment(site, %{artifact_url: "file:///tmp/a.tar.gz"})

    assert {:ok, %{no_source_failed: 0}} = perform_job(StaleDeploymentReaper, %{})

    kept = Repo.get(Deployment, d.id)
    assert kept.status == "queued"
  end

  test "a queued repo-backed row (no artifact) is left untouched" do
    {_bp, site} = setup_site()
    {:ok, site} = Registry.set_site_github(site, "owner/repo", "main", "shh")
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})

    assert {:ok, %{no_source_failed: 0}} = perform_job(StaleDeploymentReaper, %{})

    kept = Repo.get(Deployment, d.id)
    assert kept.status == "queued"
  end

  ## 7. (site-spawner D28) The no-build-source pass is KIND-SCOPED.
  ##
  ## A content-bound STATIC deploy is artifact-less AND repo-less — it builds from
  ## a Barkpark dataset. That is EXACTLY the shape the container pass matched, and
  ## this sweep runs every 60 seconds, so an unscoped pass terminally failed every
  ## static deploy within a minute of it being minted, mislabelled with copy about
  ## artifacts and GitHub repos. These three tests pin both halves of the fix: the
  ## legitimate row must SURVIVE, and the un-buildable one must still DIE (with an
  ## honest reason) rather than spinning `queued` forever.

  defp static_site_fixture(barkpark, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(
        barkpark,
        Enum.into(attrs, %{
          name: "S #{n}",
          slug: "s-#{n}",
          kind: "static",
          framework: "astro",
          bootstrap_workspace: "acme",
          bootstrap_project: "blog",
          bootstrap_dataset: "production"
        })
      )

    site
  end

  test "a content-bound STATIC queued row SURVIVES the sweep (the container predicate must not match it)" do
    bp = team_fixture() |> barkpark_fixture()
    site = static_site_fixture(bp)

    # The normal shape of a legitimate static deploy: no artifact, no repo, a
    # dataset binding. Un-scoped, the container pass fails this row within 60s.
    {:ok, d} = Registry.create_deployment(site, %{build_id: "b0", content_rev: "c0"})
    assert d.status == "queued"
    assert is_nil(site.github_repo)

    assert {:ok, %{no_source_failed: 0}} = perform_job(StaleDeploymentReaper, %{})

    kept = Repo.get(Deployment, d.id)
    assert kept.status == "queued"
    assert is_nil(kept.failure_reason)
  end

  test "an UNBOUND static queued row is still terminally failed — with the honest content-binding reason" do
    bp = team_fixture() |> barkpark_fixture()
    site = static_site_fixture(bp, %{bootstrap_dataset: nil})

    {:ok, d} = Registry.create_deployment(site, %{})

    # The trap the naive one-predicate kind-scope falls into: this row matches
    # NOTHING and spins queued forever. It must die, and say why.
    assert {:ok, %{no_source_failed: 1}} = perform_job(StaleDeploymentReaper, %{})

    failed = Repo.get(Deployment, d.id)
    assert failed.status == "failed"
    assert failed.failure_reason =~ "no content binding"
    assert failed.failure_reason =~ "--dataset"
    # And it is NOT told to upload an artifact or connect a GitHub repo — neither
    # is a thing a static site can do.
    refute failed.failure_reason =~ "no build source"
  end

  test "the two passes sum into ONE no_source_failed count (the worker's return shape is unchanged)" do
    bp = team_fixture() |> barkpark_fixture()
    container = site_fixture(bp)
    unbound_static = static_site_fixture(bp, %{bootstrap_dataset: nil})

    {:ok, c} = Registry.create_deployment(container, %{git_ref: "main"})
    {:ok, s} = Registry.create_deployment(unbound_static, %{})

    assert {:ok, %{no_source_failed: 2}} = perform_job(StaleDeploymentReaper, %{})

    assert Repo.get(Deployment, c.id).failure_reason =~ "no build source"
    assert Repo.get(Deployment, s.id).failure_reason =~ "no content binding"
  end

  ## 8. (site-spawner D22) The other half of crash safety: the sweep REQUEUES an
  ##    orphaned static row, and nothing in the fleet claims static rows — so the
  ##    reaper re-drives them itself, or the "recovery" would just be a slower
  ##    eternal spinner.

  test "a requeued (orphaned) static row is re-driven, and the container builder can never claim it" do
    bp = team_fixture() |> barkpark_fixture()
    site = static_site_fixture(bp)
    {:ok, d} = Registry.create_deployment(site, %{build_id: "b1", content_rev: "c1"})

    # It was claimed once by a driver that died with the control plane: the reaper
    # already swept it back to `queued`, leaving claim_epoch > 0 behind.
    Repo.update_all(
      from(x in Deployment, where: x.id == ^d.id),
      set: [claim_epoch: 1]
    )

    # The off-box CONTAINER builder must not be able to pick it up — it has no way
    # to build a static site, and a row it claimed would wedge `building` forever.
    assert {:error, :no_queued} = Registry.claim_next_deployment("container-builder-1")

    # The reaper re-drives it (the test starter is a no-op, so nothing runs —
    # what's proven is that the row is FOUND and handed on).
    assert {:ok, %{resumed: 1}} = perform_job(StaleDeploymentReaper, %{})
    assert [%Deployment{id: id}] = Registry.list_orphaned_static_deployments()
    assert id == d.id
  end

  ## 9. (search-template W6) NODE rows strand identically — W7 put node on the
  ##    same box relay, so a requeued node row also has no claimer. Live-caught
  ##    twice in one evening (a CP self-deploy, then a box self-deploy, each
  ##    killed an in-flight ember build). The orphan sweep must cover it.

  test "a requeued (orphaned) NODE row is re-driven too — same box relay, same recovery" do
    bp = team_fixture() |> barkpark_fixture()

    site =
      static_site_fixture(bp, %{
        kind: "node",
        framework: "nextjs",
        template: "search-starter"
      })

    {:ok, d} = Registry.create_deployment(site, %{build_id: "bn1", content_rev: "cn1"})

    Repo.update_all(
      from(x in Deployment, where: x.id == ^d.id),
      set: [claim_epoch: 1]
    )

    # The container builder is still fenced off node rows.
    assert {:error, :no_queued} = Registry.claim_next_deployment("container-builder-1")

    assert {:ok, %{resumed: 1}} = perform_job(StaleDeploymentReaper, %{})
    assert [%Deployment{id: id}] = Registry.list_orphaned_static_deployments()
    assert id == d.id
  end

  ## 9b. (site-spawner D22, box-scoped twin) task-349157180e91561e:
  ##     `claim_queued_deployment_for_barkpark/2` ANDs the same container guard
  ##     as `claim_next_deployment/1` (tested in 8/9 above) — narrowing the query
  ##     by box must not relax it. Every test site elsewhere in this suite (and
  ##     the router_builder_test.exs concurrency test that already drives this
  ##     function) defaults to kind "container" (Registry.Site's schema default),
  ##     so nothing but a differential against a NON-container site on the SAME
  ##     barkpark can catch the conjunct's deletion — and tests 8/9 above don't
  ##     catch it either, because they drive claim_next_deployment/1, not this
  ##     function.
  ##
  ##     Mutation-proof: delete `s.kind == "container"` from the subquery in
  ##     `Registry.claim_queued_deployment_for_barkpark/2` and the FIRST
  ##     assertion below reds (the static row becomes claimable); restore it and
  ##     the test is green again.
  test "claim_queued_deployment_for_barkpark fences a static row off the SAME box's container queue" do
    bp = team_fixture() |> barkpark_fixture()
    static = static_site_fixture(bp)
    {:ok, _d} = Registry.create_deployment(static, %{build_id: "b1", content_rev: "c1"})

    assert {:error, :no_queued} = Registry.claim_queued_deployment_for_barkpark(bp, "builder-1")

    # A container row ON THE SAME BOX IS claimable — proves the :no_queued
    # above is the kind guard doing its job, not an empty/broken queue or a
    # box-scoping bug hiding every row on this barkpark.
    container = site_fixture(bp)
    {:ok, d} = Registry.create_deployment(container, %{git_ref: "main"})

    assert {:ok, claimed} = Registry.claim_queued_deployment_for_barkpark(bp, "builder-1")
    assert claimed.id == d.id
  end

  ## 10. (deploy-reliability W17 S5) `resumed:` IS the recovery metric — the
  ##     reaper puts it straight into the Oban job meta. It used to be
  ##     `length(orphans)`, the count of rows FOUND, over a fire-and-forget
  ##     `Deploy.start/1` spec'd `:: :ok`. So a sweep in which every single
  ##     rescue was REFUSED still reported `resumed: N`: the recovery mechanism
  ##     failing was indistinguishable from it working.

  defmodule RefusingStarter do
    @moduledoc false
    @behaviour BarkparkCloud.Sites.Deploy.Starter

    @impl true
    def start(_deployment_id), do: {:error, :max_children}
  end

  test "a rescue the supervisor REFUSES is not counted resumed — the metric can lose" do
    bp = team_fixture() |> barkpark_fixture()

    # Two SITES — the `(site_id, environment)` active-deploy unique allows only
    # one live row per site, and two orphans is what makes "found" and
    # "restarted" tell different stories.
    for tag <- ["r1", "r2"] do
      site = static_site_fixture(bp)
      {:ok, d} = Registry.create_deployment(site, %{build_id: tag, content_rev: tag})
      Repo.update_all(from(x in Deployment, where: x.id == ^d.id), set: [claim_epoch: 1])
    end

    assert length(Registry.list_orphaned_static_deployments()) == 2

    # Nothing can be spawned. Two rows are found; ZERO are re-driven.
    Process.put(:site_deploy_starter, RefusingStarter)

    assert {:ok, %{resumed: 0}} = perform_job(StaleDeploymentReaper, %{})

    # They are still orphans, so the next sweep tries again — the honest state.
    assert length(Registry.list_orphaned_static_deployments()) == 2
  end
end
