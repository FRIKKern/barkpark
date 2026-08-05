defmodule BarkparkCloud.Sites.AutoDeployWorkerTest do
  @moduledoc """
  site-spawner W5 (charter D44/D48) — the CP-side debounce that turns a burst of
  content publishes into ONE re-deploy, and still re-deploys after an in-flight
  build. The two load-bearing properties, proven against real Oban rows:

    * a BURST of publishes before any build starts collapses to exactly ONE
      scheduled job (the `site_id` unique on `[:available, :scheduled]`);
    * a publish that lands WHILE a build is `:executing` finds NO conflict (that
      state is DROPPED from the unique states) → it mints exactly ONE trailing
      job. Keeping `:executing` would swallow it and serve stale content.

  And the provenance property (charter D48/D49): `perform` mints a Deployment with
  `trigger = "content-auto"` and a FORCE-fresh build_id distinct from a manual
  deploy of the same content.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Sites.{AutoDeployWorker, Deploy, FakeBoxRelay}

  @instance_url "https://acme.barkpark.cloud"
  @worker "BarkparkCloud.Sites.AutoDeployWorker"

  ## Fixtures

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: @instance_url,
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> Repo.update!()
  end

  defp static_site(bp, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(
        bp,
        Enum.into(attrs, %{
          name: "Blog #{n}",
          slug: "blog-#{n}",
          kind: "static",
          framework: "astro",
          bootstrap_workspace: "acme",
          bootstrap_project: "blog",
          bootstrap_dataset: "production",
          read_token: "bpt_read_#{n}"
        })
      )

    site
  end

  defp setup_site do
    bp = team_fixture() |> live_barkpark()
    {bp, static_site(bp)}
  end

  # Mark the site deployed with an UPLOADED current release — bytes this fleet
  # cannot reproduce.
  defp deployed_prebuilt(site, bp) do
    {:ok, marker} = Deploy.enqueue(site, bp, false, "manual", nil, "prebuilt")
    assert marker.source == "prebuilt"

    site
    |> Ecto.Changeset.change(current_deployment_id: went_live(marker).id)
    |> Repo.update!()
  end

  defp deployed_box_build(site, bp) do
    {:ok, marker} = Deploy.enqueue(site, bp, true, "manual")
    assert marker.source == "box-build"

    site
    |> Ecto.Changeset.change(current_deployment_id: went_live(marker).id)
    |> Repo.update!()
  end

  # A site's CURRENT release is a build that FINISHED — and since deploy-truth W1
  # re-keyed the active-deployment index on (site_id, environment), a marker left
  # `queued` would also (correctly) block the very auto-deploy these tests are
  # about. Walk it to `live`, the way the driver does.
  defp went_live(deployment) do
    Enum.reduce(~w(building pushing live), deployment, fn status, d ->
      {:ok, next} = Registry.transition_deployment(d, %{status: status})
      next
    end)
  end

  # Move a row out of the ACTIVE set: one build in flight per site.
  defp settle(deployment) do
    {:ok, settled} = Registry.transition_deployment(deployment, %{status: "failed"})
    settled
  end

  defp content_autos(site) do
    Registry.list_deployments(site, 20) |> Enum.filter(&(&1.trigger == "content-auto"))
  end

  # The box refuses a second concurrent deploy for a slug: 409 `already_running`,
  # NESTED, which is the shape `SiteDeployController` actually sends.
  defp program_busy_box(site) do
    FakeBoxRelay.program(
      start:
        {:ok, 409,
         %{
           "error" => %{
             "code" => "already_running",
             "message" => "a deploy for site '#{site.slug}' is already running"
           }
         }}
    )
  end

  defp pending_jobs(site_id) do
    Repo.all(
      from(j in Oban.Job,
        where:
          j.worker == ^@worker and
            fragment("?->>'site_id' = ?", j.args, ^site_id) and
            j.state in ["available", "scheduled"]
      )
    )
  end

  ## ---------------------------------------------------------------------------

  describe "debounce — the site_id unique job (charter D44)" do
    test "a burst of publishes coalesces to exactly ONE scheduled rebuild" do
      {_bp, site} = setup_site()

      # Ten publishes land in a burst before any build starts — a real content
      # edit session. Each fires the receiver, which calls enqueue/1.
      for _ <- 1..10 do
        assert {:ok, _job} = AutoDeployWorker.enqueue(site.id)
      end

      # ONE job, not ten: the `site_id` unique on [:available, :scheduled]
      # collapses the burst. A ~10s npm build must not run ten times.
      jobs = all_enqueued(worker: AutoDeployWorker)
      assert length(jobs) == 1
      assert hd(jobs).args == %{"site_id" => site.id}
    end

    test "two different sites each get their own job (the unique is keyed on site_id)" do
      {bp, site_a} = setup_site()
      site_b = static_site(bp, %{slug: "blog-b-#{System.unique_integer([:positive])}"})

      assert {:ok, _} = AutoDeployWorker.enqueue(site_a.id)
      assert {:ok, _} = AutoDeployWorker.enqueue(site_b.id)

      assert length(all_enqueued(worker: AutoDeployWorker)) == 2
    end

    test "a publish DURING a running build mints exactly ONE trailing rebuild" do
      {_bp, site} = setup_site()

      # A rebuild is scheduled and then STARTS — the build is now in flight.
      assert {:ok, job_a} = AutoDeployWorker.enqueue(site.id)

      # Simulate job A executing (the ~10s npm build). `:executing` is deliberately
      # NOT in the unique states, so it is invisible to the next enqueue's conflict
      # check — exactly the D44 correction.
      {1, _} =
        Repo.update_all(
          from(j in Oban.Job, where: j.id == ^job_a.id),
          set: [state: "executing"]
        )

      # A publish arrives mid-build. Because A is `:executing` (∉ states), there is
      # NO conflict — a fresh trailing job is minted carrying the NEW content.
      assert {:ok, job_b} = AutoDeployWorker.enqueue(site.id)
      refute job_b.id == job_a.id

      # Exactly ONE trailing job is pending (not zero — the publish is not lost —
      # and not more than one — a second mid-build publish would still coalesce).
      assert length(pending_jobs(site.id)) == 1
      assert hd(pending_jobs(site.id)).id == job_b.id

      # A SECOND publish still mid-build coalesces onto the trailing job (the burst
      # rule holds again now that a :scheduled job exists).
      assert {:ok, _} = AutoDeployWorker.enqueue(site.id)
      assert length(pending_jobs(site.id)) == 1
    end
  end

  describe "perform — provenance + force (charter D48/D49)" do
    test "mints a Deployment with trigger=content-auto and a force-fresh build_id" do
      {bp, site} = setup_site()

      # A manual deploy of this exact content fixes the baseline build_id.
      assert {:ok, manual} = Deploy.enqueue(site, bp)
      assert manual.trigger == "manual"
      # It is only a build_id baseline here; settle it so the auto-deploy below
      # is not (correctly) refused as a second concurrent build.
      settle(manual)

      # The debounced job fires. In test the deploy STARTER is the no-op (config),
      # so no box is touched — but the row is minted synchronously by enqueue.
      assert :ok = perform_job(AutoDeployWorker, %{"site_id" => site.id})

      autos =
        Registry.list_deployments(site, 10)
        |> Enum.filter(&(&1.trigger == "content-auto"))

      assert [auto] = autos
      assert is_binary(auto.build_id) and byte_size(auto.build_id) == 16
      # FORCE nonce (D48): a byte-identical republish still mints a DISTINCT build,
      # never the cached duplicate — the auto-rebuild always re-runs.
      refute auto.build_id == manual.build_id
    end

    test "a job for a deleted site cancels rather than crashing or retrying forever" do
      # No site with this id exists — the publish raced a site delete.
      assert {:cancel, :site_or_box_gone} =
               perform_job(AutoDeployWorker, %{"site_id" => Ecto.UUID.generate()})
    end
  end

  describe "the PREBUILT refusal (charter D92/D105)" do
    test "FAIL-BEFORE: unguarded, a content publish mints a BOX build over the uploaded release" do
      {bp, site} = setup_site()
      site = deployed_prebuilt(site, bp)
      live = Registry.get_deployment(site.current_deployment_id)

      # The pre-guard `drive/2`, VERBATIM: force + content-auto, `source` left at
      # its "box-build" default.
      assert {:ok, ghost} = Deploy.enqueue(site, bp, true, "content-auto")
      assert ghost.source == "box-build"
      refute ghost.build_id == live.build_id
    end

    test "mints a USER-VISIBLE cancelled row (content-auto/prebuilt) naming the remedy, and cancels BY VALUE" do
      {bp, site} = setup_site()
      site = deployed_prebuilt(site, bp)

      # BY VALUE, not by shape: {:error, _} would have Oban retry to max_attempts
      # and then DISCARD — a permanent, correct refusal made to look like a box
      # outage.
      assert {:cancel, :prebuilt_release_protected} =
               perform_job(AutoDeployWorker, %{"site_id" => site.id})

      assert [row] = content_autos(site)
      assert row.status == "cancelled"
      assert row.source == "prebuilt"
      assert row.trigger == "content-auto"

      # The webhook already answered 202 ok, so the row is the ONLY place a user
      # can learn the publish did not reach live — it must name the way forward.
      assert row.detail =~ "--prebuilt"
      assert row.detail =~ "bp cloud site deploy"
      assert row.failure_reason == row.detail

      # And it never became a build: no queued/building row was left behind.
      refute Enum.any?(content_autos(site), &(&1.status in ~w(queued building pushing live)))
    end

    test "a BOX-BUILT live release is untouched by the guard — the auto-deploy still fires" do
      {bp, site} = setup_site()
      site = deployed_box_build(site, bp)

      assert :ok = perform_job(AutoDeployWorker, %{"site_id" => site.id})

      assert [row] = content_autos(site)
      assert row.status == "queued"
      assert row.source == "box-build"
    end

    test "keys on the LIVE RELEASE, not sites.prebuilt_enabled — an ENABLED site serving a box build still auto-deploys" do
      {bp, site} = setup_site()

      # The opt-in is ON, but this site's live bytes came from the box. Keying on
      # the flag would kill its content auto-deploy outright.
      site =
        site
        |> Ecto.Changeset.change(prebuilt_enabled: true)
        |> Repo.update!()
        |> deployed_box_build(bp)

      assert :ok = perform_job(AutoDeployWorker, %{"site_id" => site.id})
      assert [%{status: "queued", source: "box-build"}] = content_autos(site)
    end

    test "a never-deployed site is not refused (nil current release is not provenance)" do
      {_bp, site} = setup_site()
      assert site.current_deployment_id == nil

      assert :ok = perform_job(AutoDeployWorker, %{"site_id" => site.id})
      assert [%{source: "box-build"}] = content_autos(site)
    end

    test "the MANUAL path is unchanged: a manual deploy of a prebuilt-current site still enqueues" do
      {bp, site} = setup_site()
      site = deployed_prebuilt(site, bp)

      # The guard belongs to the UNBIDDEN paths only. A human running
      # `bp cloud site deploy` asked for exactly this.
      assert {:ok, manual} = Deploy.enqueue(site, bp, true, "manual")
      assert manual.status == "queued"
      assert manual.trigger == "manual"
    end
  end

  # deploy-truth W1 (charter D9) — THE PUBLISH IS NO LONGER LOST.
  #
  # The old `drive/2` was `:ok = Deploy.start(deployment); :ok` against a starter
  # that returned a literal `:ok` no matter what happened. Production's proof:
  # 11,868 completed `site_deploy` jobs and ZERO retryable/discarded ones, while
  # 8,830 deploys (51.4% of every failed row) were refused by a busy box and died
  # terminal-`failed` with nothing to re-drive them. 4,058 of those sites saw no
  # later build at all.
  describe "a busy box is a COUNTED deferral that RE-FIRES (charter D9)" do
    test "the worker OBSERVES a box 409 instead of returning :ok blind" do
      {_bp, site} = setup_site()

      # Drive the deploy synchronously in THIS process so the outcome can travel
      # back to the worker at all (production spawns; the seam is process-local
      # so an async test never swaps it for another).
      Process.put(:site_deploy_starter, Deploy.SyncStarter)
      program_busy_box(site)

      # BY VALUE: the job records the deferral. The pre-W1 code returned a bare
      # `:ok` here — indistinguishable from a build that went live.
      assert {:ok, :deferred} = perform_job(AutoDeployWorker, %{"site_id" => site.id})

      # A COUNTED row in its own bucket — not a failure, not a dropped row.
      assert [row] = content_autos(site)
      assert row.status == "deferred"
      assert row.failure_reason =~ "already_running"
      assert row.failure_reason =~ "re-queued"
    end

    test "NO PUBLISH LOST: a publish during an in-flight build is provably rebuilt afterwards" do
      {bp, site} = setup_site()

      # A build is IN FLIGHT: the row is claimed and building, exactly as it is
      # while the box runs `npm ci && npm run build` for two to four minutes.
      {:ok, in_flight} = Deploy.enqueue(site, bp, true, "content-auto")
      {:ok, in_flight} = Registry.claim_deployment(in_flight.id, "worker-1")
      assert in_flight.status == "building"

      # The publish lands mid-build. Before this slice: a second row minted, the
      # box answered 409, the row died `failed`, and nothing re-enqueued it —
      # this content never reached live.
      assert {:ok, :deferred} = perform_job(AutoDeployWorker, %{"site_id" => site.id})

      # No second concurrent build was minted (the re-keyed index refuses it) and
      # the in-flight build was NOT disturbed.
      assert Registry.get_deployment(in_flight.id).status == "building"

      # THE PROOF, as a real Oban row: a trailing rebuild is pending.
      assert [trailing] = pending_jobs(site.id)

      # The in-flight build finishes…
      {:ok, _} =
        Registry.transition_deployment(Registry.get_deployment(in_flight.id), %{
          status: "pushing"
        })

      {:ok, _} =
        Registry.transition_deployment(Registry.get_deployment(in_flight.id), %{status: "live"})

      # …and the trailing job then mints a REAL rebuild carrying the publish that
      # was deferred. This is the whole slice in one assertion.
      assert :ok = perform_job(AutoDeployWorker, trailing.args)

      rebuilt =
        content_autos(site)
        |> Enum.reject(&(&1.id == in_flight.id))

      assert [%{status: "queued", trigger: "content-auto"} = fresh] = rebuilt
      refute fresh.build_id == in_flight.build_id
    end

    test "RETRY ACCOUNTING: six consecutive busy boxes never DISCARD the rebuild" do
      {_bp, site} = setup_site()

      Process.put(:site_deploy_starter, Deploy.SyncStarter)
      program_busy_box(site)

      # `max_attempts` is 3. A naive `{:snooze, n}` increments `attempt` against
      # it, so the FOURTH busy box would discard the job — the silent drop this
      # wave refuses. The deferral mints a FRESH debounced job instead, which
      # carries no attempt history at all, so six rounds are still six rounds.
      for round <- 1..5 do
        assert {:ok, :deferred} = perform_job(AutoDeployWorker, %{"site_id" => site.id}),
               "round #{round} must defer, never discard"

        # …and each round leaves exactly ONE pending rebuild (the site_id unique
        # collapses repeats) whose attempt count is untouched.
        assert [job] = pending_jobs(site.id)
        assert job.attempt == 0
        assert job.state in ["available", "scheduled"]
      end

      # Every round is ON THE RECORD: five counted deferrals, none discarded,
      # none quietly relabelled a success.
      assert Enum.count(content_autos(site), &(&1.status == "deferred")) == 5

      # The chain is bounded, not infinite: a box still refusing after the cap is
      # not busy but stuck, and the row says so terminally.
      assert {:ok, :failed} = perform_job(AutoDeployWorker, %{"site_id" => site.id})
      assert [stuck] = Enum.filter(content_autos(site), &(&1.status == "failed"))
      assert stuck.failure_reason =~ "stuck"
    end

    test "a spawn that never happened is NOT reported as success" do
      {bp, site} = setup_site()
      {:ok, deployment} = Deploy.enqueue(site, bp, true, "content-auto")

      # The supervisor refused the child: nothing is building and nothing
      # recorded it. The row is still `queued`, so an Oban retry (and, failing
      # that, the stale-deployment reaper) can still pick it up.
      Process.put(:site_deploy_starter, __MODULE__.RefusingStarter)

      assert {:error, :max_children} = Deploy.start_reported(deployment)
      assert Registry.get_deployment(deployment.id).status == "queued"

      # …and the fire-and-forget wrapper still answers `:ok` for the call sites
      # that match on it (the deploy route, the template sweep).
      assert :ok = Deploy.start(deployment)
    end
  end

  defmodule RefusingStarter do
    @moduledoc false
    @behaviour BarkparkCloud.Sites.Deploy.Starter

    @impl true
    def start(_deployment_id), do: {:error, :max_children}
  end

  describe "debounce window (D44 amendment: 60s default, env-overridable, floored)" do
    # The window is read per-enqueue from AUTODEPLOY_DEBOUNCE_S so a small box
    # can stretch it without a deploy; the floor keeps it never LESS debounced
    # than the original D44 5s.
    test "defaults to 60s, honors a valid override, floors garbage and sub-5 values" do
      site_id = Ecto.UUID.generate()

      grab = fn ->
        {:ok, job} = AutoDeployWorker.enqueue(site_id)
        seconds = DateTime.diff(job.scheduled_at, DateTime.utc_now())
        Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id))
        seconds
      end

      System.delete_env("AUTODEPLOY_DEBOUNCE_S")
      assert_in_delta grab.(), 60, 3

      System.put_env("AUTODEPLOY_DEBOUNCE_S", "120")
      assert_in_delta grab.(), 120, 3

      System.put_env("AUTODEPLOY_DEBOUNCE_S", "2")
      assert_in_delta grab.(), 60, 3

      System.put_env("AUTODEPLOY_DEBOUNCE_S", "nonsense")
      assert_in_delta grab.(), 60, 3
    after
      System.delete_env("AUTODEPLOY_DEBOUNCE_S")
    end
  end
end
