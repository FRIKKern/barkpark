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

    # dr-w12 S6. THE ATTEMPT THAT MINTS NO ROW. The test above proves the
    # publish is not LOST; it says nothing about whether it is COUNTED — and it
    # was not. `defer_behind_running_build/2` wrote a Logger line and nothing
    # else, correctly refusing to mint a fake `deferred` row (the
    # active-deployment index refused one, and the row in flight is a real build
    # that must not be relabelled) — which left the attempt invisible to every
    # aggregate over the deployment stream.
    #
    # Measured, not assumed: in the twelve hours 2026-08-06 08:00-20:00Z there
    # were 2,256 AutoDeployWorker jobs against 1,052 deployment rows — 1,204
    # ATTEMPTS THAT MINTED NO ROW against 277 counted deferrals (4.35:1). Since
    # 22:00Z the ratio is 0.086:1 and zero per minute: DORMANT, not fixed, and it
    # returns as a function of load, i.e. when the number matters most.
    #
    # IT CAN LOSE: delete the `record_coalesced_attempt(in_flight)` call and the
    # count assertions red, while "NO PUBLISH LOST" above stays green.
    test "AN ATTEMPT THAT MINTS NO ROW IS STILL COUNTED — on the in-flight build it coalesced onto" do
      {bp, site} = setup_site()

      {:ok, in_flight} = Deploy.enqueue(site, bp, true, "content-auto")
      {:ok, in_flight} = Registry.claim_deployment(in_flight.id, "worker-1")
      assert in_flight.status == "building"

      # A build in flight starts having answered for nobody but itself.
      assert Registry.get_deployment(in_flight.id).coalesced_attempts == 0
      before_rows = length(Registry.list_deployments(site, 50))

      # Three publishes land mid-build. Each coalesces onto the running row.
      for _ <- 1..3 do
        assert {:ok, :deferred} = perform_job(AutoDeployWorker, %{"site_id" => site.id})
      end

      # NO ROW WAS MINTED — that is the whole reason the count had nowhere to go,
      # and the fix must not have quietly changed it. The in-flight build is also
      # still a BUILD: it was not relabelled a deferral.
      assert length(Registry.list_deployments(site, 50)) == before_rows

      reloaded = Registry.get_deployment(in_flight.id)
      assert reloaded.status == "building"

      # …and yet all three attempts are on the record, against the build that is
      # actually answering for them.
      assert reloaded.coalesced_attempts == 3
      assert reloaded.coalesced_last_at

      # The count belongs to THIS build, not to the site: the trailing rebuild
      # that eventually carries the coalesced content starts from zero.
      {:ok, _} =
        Registry.transition_deployment(reloaded, %{status: "pushing"})

      {:ok, _} =
        Registry.transition_deployment(Registry.get_deployment(in_flight.id), %{status: "live"})

      assert [trailing] = pending_jobs(site.id)
      assert :ok = perform_job(AutoDeployWorker, trailing.args)

      assert [fresh] = content_autos(site) |> Enum.reject(&(&1.id == in_flight.id))
      assert fresh.coalesced_attempts == 0
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

      # …and there is NO fire-and-forget wrapper left to launder that refusal.
      # This assertion used to be `assert :ok = Deploy.start(deployment)` — a
      # test whose entire content was that a refused spawn reads as success for
      # the call sites matching on it. `start/1` is deleted; every caller sees
      # the error arm or does not compile.
      refute function_exported?(Deploy, :start, 1)
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

  # How far out a job is scheduled, in seconds from NOW — the only number this
  # slice changes.
  defp window(%Oban.Job{} = job), do: DateTime.diff(job.scheduled_at, DateTime.utc_now())

  # Move a pending job into `:executing` — the state DROPPED from `@unique`, so
  # it is invisible to the next enqueue's conflict check (charter D44).
  defp execute_now(%Oban.Job{} = job) do
    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])

    job
  end

  describe "the refusal backoff is DEPTH-DERIVED and CAPPED (deploy-reliability W20)" do
    # THE WINDOW LADDER. A multiple of the operator's own debounce, never a
    # second constant: round 1 waits exactly as long as today (so a first blip is
    # not slowed at all) and each further round of the SAME chain waits one more
    # window.
    test "the window is depth x the debounce, capped at 240s — and the cap is under the unique period" do
      assert Deploy.deferral_backoff_seconds(1) == 60
      assert Deploy.deferral_backoff_seconds(2) == 120
      assert Deploy.deferral_backoff_seconds(3) == 180
      assert Deploy.deferral_backoff_seconds(4) == 240
      # Every deeper round is the cap. `@max_consecutive_capacity_deferrals` is
      # 12, so 50 is far past anything `defer/3` can reach.
      assert Deploy.deferral_backoff_seconds(12) == 240
      assert Deploy.deferral_backoff_seconds(50) == 240

      # P7, CLOSED BY THE CAP. `@unique period: 300` is compared against
      # `inserted_at`, not `scheduled_at` — a job scheduled further out than the
      # period ages out of its own unique window while still pending, and the
      # next enqueue mints a SECOND job. 240 < 300 with headroom.
      assert Deploy.deferral_backoff_seconds(50) < 300
    end

    test "the window follows the operator's debounce, and the cap never makes a deferral MORE eager" do
      System.put_env("AUTODEPLOY_DEBOUNCE_S", "30")
      assert Deploy.deferral_backoff_seconds(1) == 30
      assert Deploy.deferral_backoff_seconds(3) == 90
      assert Deploy.deferral_backoff_seconds(20) == 240

      # An operator who already stretched the debounce PAST the cap keeps their
      # own window — a refused deploy must never re-fire sooner than a plain
      # publish would.
      System.put_env("AUTODEPLOY_DEBOUNCE_S", "600")
      assert Deploy.deferral_backoff_seconds(1) == 600
      assert Deploy.deferral_backoff_seconds(5) == 600
    after
      System.delete_env("AUTODEPLOY_DEBOUNCE_S")
    end

    # P7 AS A ROW COUNT, not just an inequality: at the LONGEST window the code
    # can produce, two enqueues still collapse to ONE pending job. If the cap
    # were ever raised past the unique period this fails with pending == 2 — the
    # fan-out the backoff exists to cut, reintroduced by the backoff.
    test "at the MAXIMUM backoff the code can produce, the pending job count is still 1" do
      site_id = Ecto.UUID.generate()
      max = Deploy.deferral_backoff_seconds(50)

      assert {:ok, a} = AutoDeployWorker.enqueue(site_id, max)
      assert {:ok, b} = AutoDeployWorker.enqueue(site_id, max)
      assert b.id == a.id
      assert length(pending_jobs(site_id)) == 1
      assert_in_delta window(b), max, 3
    end

    # CONTENTION, CASE 1 — an :executing sibling. This is the production shape
    # (measured wave 20: the Oban job holds :executing for a p50 of 0.30s against
    # a 63.2s build, because `perform/1` spawns a supervised driver and returns —
    # so by the time the deferral re-fires, the sibling is usually GONE, and when
    # it is not it is :executing ∉ the unique states). Either way the longer
    # window is inserted VERBATIM. The assertion is on the SECOND insert's
    # scheduled_at while the first is still pending — not on ids or counts, which
    # the pre-W20 tests already passed with the flat 60s.
    test "path B (defer behind a running build): the trailing job carries the depth-derived window" do
      {bp, site} = setup_site()

      # A chain already two rounds deep sits at the head of this site's stream.
      chain = deferral_chain(site, bp, 2)
      assert length(chain) == 2

      # A build is IN FLIGHT, so the auto-deploy's own enqueue is refused and
      # `defer_behind_running_build/2` (path B) runs — the path most deferral
      # rows flow through, and the one with no `cause` in scope.
      {:ok, in_flight} = Deploy.enqueue(site, bp, true, "content-auto")
      {:ok, _} = Registry.claim_deployment(in_flight.id, "worker-1")

      sibling = execute_now(elem(AutoDeployWorker.enqueue(site.id), 1))

      assert {:ok, :deferred} = perform_job(AutoDeployWorker, %{"site_id" => site.id})

      assert [trailing] = pending_jobs(site.id)
      refute trailing.id == sibling.id

      # Round 3 of the chain: 3 x 60. With the pre-W20 constant this is 60 and
      # the test fails on the value, not on a count.
      assert_in_delta window(trailing), 180, 3
    end

    # CONTENTION, CASE 2 — a :scheduled sibling. Here the unique DOES match, and
    # Oban (without `:replace`) returns the EXISTING job: the longer window is
    # discarded and the pending job keeps its shorter one. That is the correct,
    # deliberate behaviour and it is asserted so nobody "fixes" it with
    # `replace: [scheduled: [:scheduled_at]]` — which has no max/min semantics
    # and would let the SHORTEST caller win (probe P6: a 60s publish dragging a
    # pending deferral back to 59s).
    test "scheduled sibling: the longer window COALESCES onto the pending job — one job, no reset" do
      site_id = Ecto.UUID.generate()

      assert {:ok, a} = AutoDeployWorker.enqueue(site_id)
      assert_in_delta window(a), 60, 3

      assert {:ok, b} = AutoDeployWorker.enqueue(site_id, 240)
      assert b.id == a.id
      assert_in_delta window(b), 60, 3
      assert length(pending_jobs(site_id)) == 1

      # …and the reverse order proves the same rule from the other side: a
      # pending 240s deferral is NOT dragged forward by an ordinary publish.
      other = Ecto.UUID.generate()
      assert {:ok, long} = AutoDeployWorker.enqueue(other, 240)
      assert {:ok, publish} = AutoDeployWorker.enqueue(other)
      assert publish.id == long.id
      assert_in_delta window(publish), 240, 3
      assert length(pending_jobs(other)) == 1
    end

    # NO `replace:` ANYWHERE, as a source fact rather than a behaviour that only
    # shows up under a shape nobody remembered to write.
    test "no :replace option is passed on any insert" do
      # An actual `:replace` option always carries a keyword list — the prose
      # above the enqueue explaining why it is refused does not.
      refute File.read!("lib/barkpark_cloud/sites/auto_deploy_worker.ex") =~ ~r/\breplace:\s*\[/
      refute File.read!("lib/barkpark_cloud/sites/deploy.ex") =~ ~r/\breplace:\s*\[/
    end

    # PATH A — `Deploy.defer/3`, which already holds `prior` and reaches Oban two
    # hops away through `requeue_rebuild/2`. A real chain, driven by a real box
    # 409, so the depth is the one production would compute.
    test "path A (Deploy.defer): the SECOND refusal of a chain re-fires later than the first" do
      {_bp, site} = setup_site()
      Process.put(:site_deploy_starter, Deploy.SyncStarter)
      program_busy_box(site)

      assert {:ok, :deferred} = perform_job(AutoDeployWorker, %{"site_id" => site.id})
      assert [first] = pending_jobs(site.id)
      # Round 1 is UNCHANGED — a first blip is not slowed.
      assert_in_delta window(first), 60, 3

      # The re-fired job starts (:executing ∉ the unique states), and the box is
      # still busy when the round runs.
      execute_now(first)

      assert {:ok, :deferred} = perform_job(AutoDeployWorker, %{"site_id" => site.id})
      assert [second] = pending_jobs(site.id)
      refute second.id == first.id
      assert_in_delta window(second), 120, 3
      # Still ONE pending job at the longer window — the coalescing that pays for
      # this whole change is intact.
      assert length(pending_jobs(site.id)) == 1

      assert [row_2, row_1] = content_autos(site)
      assert row_1.status == "deferred" and row_2.status == "deferred"
      assert row_2.deferral_depth == 2
    end

    # THE TWO UNTOUCHED CALLERS. `enqueue/2` is a separate arity, never a default
    # argument, precisely so this pin can exist: a mis-edit that handed the
    # publish webhook the backoff would otherwise ship green.
    test "the publish webhook and the manual/API trigger still schedule at the flat debounce" do
      site_id = Ecto.UUID.generate()
      assert {:ok, job} = AutoDeployWorker.enqueue(site_id)
      assert_in_delta window(job), 60, 3

      router = File.read!("lib/barkpark_cloud/web/router.ex")
      assert router =~ "Sites.AutoDeployWorker.enqueue(site.id)"
      refute router =~ ~r/AutoDeployWorker\.enqueue\(site\.id,/

      # And nothing else in the app has quietly grown a window: exactly the two
      # defer-path files pass one.
      windowed =
        Path.wildcard("lib/**/*.ex")
        |> Enum.filter(&(File.read!(&1) =~ ~r/enqueue\(site(?:\.id|_id), /))
        |> Enum.sort()

      assert windowed == [
               "lib/barkpark_cloud/sites/auto_deploy_worker.ex",
               "lib/barkpark_cloud/sites/deploy.ex"
             ]
    end
  end

  # N settled `deferred` rows at the head of a site's stream — the chain a later
  # refusal is counted against. Written through the real transition so the rows
  # are the ones `consecutive_deferrals/2` scans, not hand-built decoys.
  defp deferral_chain(site, bp, n) do
    Enum.map(1..n, fn i ->
      {:ok, d} = Deploy.enqueue(site, bp, true, "content-auto")

      {:ok, deferred} =
        Registry.transition_deployment(d, %{
          status: "deferred",
          failure_reason:
            "a deploy for site '#{site.slug}' is already running — deferred: refusal #{i}"
        })

      deferred
    end)
  end

  # An `:executing` row whose node is gone: attempted long enough ago to be past
  # any rescue cutoff (dr-w8-s7).
  defp orphaned_executing(site_id, max_attempts, attempt, minutes_ago) do
    job =
      %{"site_id" => site_id}
      |> Oban.Job.new(worker: AutoDeployWorker, queue: :site_deploy, max_attempts: max_attempts)
      |> Repo.insert!()

    {1, _} =
      Repo.update_all(
        from(j in Oban.Job, where: j.id == ^job.id),
        set: [
          state: "executing",
          attempt: attempt,
          attempted_at: DateTime.add(DateTime.utc_now(), -minutes_ago, :minute),
          attempted_by: ["cloud@dead-node-#{System.unique_integer([:positive])}"]
        ]
      )

    job.id
  end

  # Scope the rescue to the ids under test so it can never reach a neighbour's
  # rows — `rescue_jobs/3` takes the queryable, exactly as Lifeline passes `Job`.
  defp rescue_only(ids) do
    {:ok, _touched} =
      Oban.Engines.Basic.rescue_jobs(
        Oban.config(),
        from(j in Oban.Job, where: j.id in ^ids),
        rescue_after: :timer.minutes(5)
      )

    Map.new(Repo.all(from(j in Oban.Job, where: j.id in ^ids, select: {j.id, j.state})))
  end

  describe "orphan rescue — Oban.Plugins.Lifeline (dr-w8-s7)" do
    # A blue/green container replacement kills the BEAM mid-job. The row stays
    # `:executing` forever: Pruner only reaps completed/cancelled/discarded, so
    # nothing on the control plane ever contradicts a job that claims to have
    # been running for ten days. Lifeline is what ends that lie.
    #
    # These tests drive `Engine.rescue_jobs/3` DIRECTLY — the same call Lifeline
    # makes — rather than running the plugin, precisely BECAUSE the plugin is
    # leader-gated (`Peer.leader?/1`): during a blue/green overlap only one node
    # rescues, so a test that started the plugin on two nodes and expected both
    # to act would be asserting a falsehood. What is under test here is the split
    # the engine performs, which is what decides what actually happens on
    # adoption.

    test "under max_attempts RESCUES to available, at max_attempts DISCARDS" do
      # The five stranded AutoDeployWorker rows: max_attempts 3, attempt 1. They
      # go back to `available` and re-run — the one-time price of adoption, and
      # safe, because perform/1 only re-enqueues + re-spawns the driver.
      retryable = orphaned_executing(Ecto.UUID.generate(), 3, 1, 10)

      # A max_attempts-1 worker (the StalenessWorker / UsageSamplerWorker shape)
      # has no attempt left to spend: it is DISCARDED, never re-run. Both
      # outcomes are safe here; what matters is that neither stays `:executing`.
      exhausted = orphaned_executing(Ecto.UUID.generate(), 1, 1, 10)

      states = rescue_only([retryable, exhausted])

      assert states[retryable] == "available"
      assert states[exhausted] == "discarded"
    end

    test "a job still inside the rescue window is left alone" do
      # The healthy case: a build that started thirty seconds ago is IN FLIGHT,
      # not orphaned. rescue_after is a cutoff, not a kill switch — if this ever
      # rescued, a live job would be double-enqueued.
      fresh = orphaned_executing(Ecto.UUID.generate(), 3, 1, 0)

      assert rescue_only([fresh])[fresh] == "executing"
    end

    test "Lifeline is configured, above the measured tail, with an explicit grace" do
      oban = Application.fetch_env!(:barkpark_cloud, Oban)

      assert {Oban.Plugins.Lifeline, opts} =
               Enum.find(oban[:plugins], &match?({Oban.Plugins.Lifeline, _}, &1)),
             "without Lifeline an orphaned :executing row is stranded forever"

      # Never below 60s: the all-time max completed AutoDeployWorker duration
      # (15.017s over 13,287 jobs) is EXACTLY Oban's old unset
      # shutdown_grace_period, so the observed distribution is clipped there and
      # the true healthy tail is unobservable. 5 minutes is 20x that max and well
      # clear of the 60s debounce window.
      assert opts[:rescue_after] >= :timer.seconds(60)
      assert opts[:rescue_after] == :timer.minutes(5)

      # Set explicitly rather than inherited: a longer grace PREVENTS orphans,
      # where Lifeline only cleans up after them.
      assert oban[:shutdown_grace_period] >= :timer.seconds(30)
    end
  end
end
