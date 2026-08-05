defmodule BarkparkCloud.Sites.TemplateFreshnessWorkerTest do
  @moduledoc """
  stw9 (charter D57b) — the hourly template-freshness sweep.

  Three properties, all of which the sweep would be actively HARMFUL without:

    * it enqueues an UNFORCED `"template-auto"` deploy for a deployed
      content-bound site (static AND node — the Next demo is node);
    * it is a NO-OP on a second tick when nothing changed (unforced ⇒ the
      `(site_id, build_id)` unique index collapses it) — this is the "never force
      on a schedule" proof: a forced sweep would mint a row every hour forever;
    * it SKIPS a site whose `content_rev` cannot be read, instead of riding
      `Deploy.enqueue/4`'s fail-open, which would mint a fresh `build_id` every
      single tick on a sick box — a build storm on a 2-core machine.

  Plus the changeset half: `"template-auto"` is a legal `trigger` (an unlisted
  value is rejected by `validate_inclusion`, so the worker's rows would silently
  never insert).
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.{Deployment, Vault}
  alias BarkparkCloud.Sites.{Deploy, TemplateFreshnessWorker}
  alias BarkparkCloud.StudioLinkFakeHttpClient

  @instance_url "https://acme.barkpark.cloud"
  @analytics_path "/w/acme/p/blog/v1/data/analytics/production"

  ## Fixtures

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp live_barkpark(team, url \\ @instance_url) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: url,
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> Repo.update!()
  end

  defp site_fixture(bp, kind, framework) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Site #{n}",
        slug: "site-#{n}",
        kind: kind,
        framework: framework,
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: "bpt_read_#{n}"
      })

    site
  end

  # Mark the site DEPLOYED with a FORCED marker deployment — forced so its
  # build_id carries a nonce and can never collide with the unforced build_id the
  # sweep computes (otherwise the very first tick would read as a duplicate for
  # the wrong reason).
  defp deployed(site, bp) do
    {:ok, marker} = Deploy.enqueue(site, bp, true, "manual")

    site
    |> Ecto.Changeset.change(current_deployment_id: went_live(marker).id)
    |> Repo.update!()
  end

  # A site's CURRENT release is a build that FINISHED. deploy-truth W1 re-keyed
  # the active-deployment index onto (site_id, environment), so a marker left
  # `queued` would also (correctly) refuse the very sweep these tests exercise —
  # one build in flight per site.
  defp went_live(deployment) do
    Enum.reduce(~w(building pushing live), deployment, fn status, d ->
      {:ok, next} = Registry.transition_deployment(d, %{status: status})
      next
    end)
  end

  # Mark the site deployed with a PREBUILT current release — bytes uploaded from
  # somewhere else, which this fleet cannot reproduce.
  defp deployed_prebuilt(site, bp) do
    {:ok, marker} = Deploy.enqueue(site, bp, false, "manual", nil, "prebuilt")
    assert marker.source == "prebuilt"

    site
    |> Ecto.Changeset.change(current_deployment_id: went_live(marker).id)
    |> Repo.update!()
  end

  defp enable_prebuilt(site) do
    site |> Ecto.Changeset.change(prebuilt_enabled: true) |> Repo.update!()
  end

  defp live_release(site), do: Registry.get_deployment(site.current_deployment_id)

  defp deployments(site), do: Registry.list_deployments(site)

  defp sweep, do: TemplateFreshnessWorker.perform(%Oban.Job{args: %{}})

  # The scoped analytics reads this owner has seen — MEASURED, not claimed.
  defp analytics_reads do
    StudioLinkFakeHttpClient.requests()
    |> Enum.count(&String.contains?(&1.url, "/v1/data/analytics/"))
  end

  ## ---------------------------------------------------------------------------

  describe "the sweep" do
    test "enqueues an UNFORCED template-auto deploy for a deployed STATIC site" do
      StudioLinkFakeHttpClient.program(%{})
      bp = team_fixture() |> live_barkpark()
      site = site_fixture(bp, "static", "astro") |> deployed(bp)

      assert {:ok, %{enqueued: 1, duplicate: 0, skipped: 0, failed: 0}} = sweep()

      assert [%Deployment{trigger: "template-auto"} | _] =
               deployments(site) |> Enum.filter(&(&1.trigger == "template-auto"))
    end

    test "enqueues for a deployed NODE site too (the Next demo is kind=node)" do
      StudioLinkFakeHttpClient.program(%{})
      bp = team_fixture() |> live_barkpark()
      site = site_fixture(bp, "node", "nextjs") |> deployed(bp)

      assert {:ok, %{enqueued: 1}} = sweep()

      assert Enum.any?(deployments(site), &(&1.trigger == "template-auto"))
    end

    test "NEVER forces: a second tick on unchanged content is a pure no-op (no new row)" do
      StudioLinkFakeHttpClient.program(%{})
      bp = team_fixture() |> live_barkpark()
      site = site_fixture(bp, "static", "astro") |> deployed(bp)

      assert {:ok, %{enqueued: 1}} = sweep()
      before = length(deployments(site))

      # THE force tripwire: with force: true this second tick would mint another
      # row (fresh nonce ⇒ fresh build_id) and, hourly, forever.
      assert {:ok, %{enqueued: 0, duplicate: 1, skipped: 0, failed: 0}} = sweep()
      assert length(deployments(site)) == before
    end

    test "SKIPS a site whose content_rev cannot be read — no build storm on a sick box" do
      # The box's scoped analytics read is failing. `Deploy.enqueue/4` would
      # fail-open to a random "u…" content_rev and therefore a NEW build_id on
      # every tick; the worker must not go anywhere near that on a schedule.
      StudioLinkFakeHttpClient.program(%{
        @analytics_path => {:ok, %{status: 502, body: "upstream down"}}
      })

      bp = team_fixture() |> live_barkpark()

      # Mint the marker while the read still works, then break it.
      site =
        site_fixture(bp, "static", "astro")
        |> then(fn s ->
          StudioLinkFakeHttpClient.program(%{})
          s = deployed(s, bp)

          StudioLinkFakeHttpClient.program(%{
            @analytics_path => {:ok, %{status: 502, body: "upstream down"}}
          })

          s
        end)

      before = length(deployments(site))

      assert {:ok, %{enqueued: 0, duplicate: 0, skipped: 1, failed: 0}} = sweep()
      assert {:ok, %{skipped: 1}} = sweep()

      assert length(deployments(site)) == before,
             "an unreadable content_rev must mint NOTHING — not a fresh build per tick"
    end

    test "caps STARTED builds at ONE per box per tick — the rest defer and converge over ticks" do
      StudioLinkFakeHttpClient.program(%{})
      bp = team_fixture() |> live_barkpark()
      _a = site_fixture(bp, "static", "astro") |> deployed(bp)
      _b = site_fixture(bp, "node", "nextjs") |> deployed(bp)

      # The queue's concurrency 1 serializes JOBS, not builds: this one job would
      # otherwise start BOTH builds concurrently on a 2-core box (the box
      # single-flights per slug only).
      assert {:ok, %{enqueued: 1, deferred: 1, duplicate: 0}} = sweep()

      # Next tick: the built site collapses to duplicate (no start), so the
      # deferred one gets its build — the cap converges, never starves.
      assert {:ok, %{enqueued: 1, duplicate: 1, deferred: 0}} = sweep()

      # Quiet fleet: everything a no-op.
      assert {:ok, %{enqueued: 0, duplicate: 2, deferred: 0}} = sweep()
    end

    test "the cap is PER BOX — two boxes each start one build in the same tick" do
      StudioLinkFakeHttpClient.program(%{})
      bp1 = team_fixture() |> live_barkpark()
      # barkparks.url is unique — the second box needs its own host.
      bp2 = team_fixture() |> live_barkpark("https://beta.barkpark.cloud")
      _ = site_fixture(bp1, "static", "astro") |> deployed(bp1)
      _ = site_fixture(bp2, "static", "astro") |> deployed(bp2)

      assert {:ok, %{enqueued: 2, deferred: 0}} = sweep()
    end

    test "ignores a container site and a never-deployed site" do
      StudioLinkFakeHttpClient.program(%{})
      bp = team_fixture() |> live_barkpark()

      {:ok, _container} =
        Registry.create_site(bp, %{name: "App", slug: "app-tf", kind: "container"})

      # Content-bound but never deployed: nothing to keep fresh, and a cron must
      # not perform a site's FIRST deploy.
      _never = site_fixture(bp, "static", "astro")

      assert {:ok, %{enqueued: 0, duplicate: 0, skipped: 0, failed: 0}} = sweep()
    end
  end

  describe "the inert-sweep counter (residue 1)" do
    test "counts a box with NO code revision — an inert sweep is no longer indistinguishable from a quiet one" do
      StudioLinkFakeHttpClient.program(%{})
      bp = team_fixture() |> live_barkpark()

      # A box that has reported neither git_commit nor version: Deploy.code_rev/1
      # falls back to the "unknown" CONSTANT, which freezes build_id's code half,
      # so no code roll on this box can EVER mint a new build here.
      bp = bp |> Ecto.Changeset.change(git_commit: nil, version: nil) |> Repo.update!()
      refute Deploy.code_rev_known?(bp)

      _site = site_fixture(bp, "static", "astro") |> deployed(bp)

      # The count rides ALONGSIDE the real outcome, never instead of it.
      assert {:ok, %{enqueued: 1, code_rev_unknown: 1}} = sweep()

      # And on the quiet tick, where the whole hazard lives: without this key the
      # summary is byte-identical to a healthy fleet's.
      assert {:ok, %{enqueued: 0, duplicate: 1, code_rev_unknown: 1}} = sweep()
    end

    test "a healthy box reports zero, and an unreadable box is not ALSO diagnosed code-rev-unknown" do
      StudioLinkFakeHttpClient.program(%{})
      bp = team_fixture() |> live_barkpark()
      assert Deploy.code_rev_known?(bp)
      _site = site_fixture(bp, "static", "astro") |> deployed(bp)

      assert {:ok, %{enqueued: 1, code_rev_unknown: 0}} = sweep()

      # A box whose analytics read fails is SKIPPED; one sick box must not read
      # as two distinct diagnoses.
      StudioLinkFakeHttpClient.program(%{
        @analytics_path => {:ok, %{status: 502, body: "upstream down"}}
      })

      assert {:ok, %{skipped: 1, code_rev_unknown: 0}} = sweep()
    end

    test "SHAPE LAW: a sixth OUTCOME ATOM raises KeyError — the count must be a KEY seeded in zero" do
      # This is the constraint the implementation is shaped by, asserted rather
      # than trusted. `perform/1` reduces with `Map.update!(acc, outcome, …)`, so
      # returning a new atom from sweep_site/1 would crash the whole sweep.
      zero = %{
        enqueued: 0,
        duplicate: 0,
        skipped: 0,
        failed: 0,
        deferred: 0,
        code_rev_unknown: 0
      }

      assert_raise KeyError, fn -> Map.update!(zero, :code_rev_stale, &(&1 + 1)) end
      assert %{code_rev_unknown: 1} = Map.update!(zero, :code_rev_unknown, &(&1 + 1))
    end
  end

  describe "one analytics read per site per tick (residue 2a)" do
    test "the probed content_rev is handed to Deploy.enqueue instead of re-read — on BOTH tick kinds" do
      StudioLinkFakeHttpClient.program(%{})
      bp = team_fixture() |> live_barkpark()
      _site = site_fixture(bp, "static", "astro") |> deployed(bp)

      # program/1 resets this owner's request log, so the fixture's own marker
      # deploy is not counted against the tick.
      StudioLinkFakeHttpClient.program(%{})
      assert {:ok, %{enqueued: 1}} = sweep()

      assert analytics_reads() == 1,
             "enqueue-tick: the sweep probes content_rev, then Deploy.enqueue/5 must REUSE it"

      StudioLinkFakeHttpClient.program(%{})
      assert {:ok, %{duplicate: 1}} = sweep()

      assert analytics_reads() == 1,
             "quiet-tick: the no-op path pays exactly one read too"
    end

    test "two sites = two reads, one each (the saving is per site, not a global cache)" do
      StudioLinkFakeHttpClient.program(%{})
      bp = team_fixture() |> live_barkpark()
      _a = site_fixture(bp, "static", "astro") |> deployed(bp)
      _b = site_fixture(bp, "node", "nextjs") |> deployed(bp)

      StudioLinkFakeHttpClient.program(%{})
      # One enqueues, one defers (per-box start cap) — the deferred site is
      # skipped BEFORE probing, so it costs no read at all.
      assert {:ok, %{enqueued: 1, deferred: 1}} = sweep()
      assert analytics_reads() == 1

      StudioLinkFakeHttpClient.program(%{})
      assert {:ok, %{enqueued: 1, duplicate: 1}} = sweep()
      assert analytics_reads() == 2
    end
  end

  describe "the PREBUILT refusal (charter D92/D105)" do
    test "FAIL-BEFORE: the UNGUARDED enqueue mints a box build that DISPLACES the uploaded release" do
      StudioLinkFakeHttpClient.program(%{})
      bp = team_fixture() |> live_barkpark()
      site = site_fixture(bp, "static", "astro") |> deployed_prebuilt(bp)

      live = live_release(site)
      assert live.source == "prebuilt"

      # This is the pre-guard sweep, VERBATIM: `enqueue_unforced/3` called
      # `Deploy.enqueue(site, bp, false, "template-auto", rev)` and let `source`
      # default. Reproduced here so the hazard is RECORDED, not asserted about.
      {:ok, rev} = Deploy.content_rev_probe(site, bp)
      assert {:ok, ghost} = Deploy.enqueue(site, bp, false, "template-auto", rev)

      assert ghost.source == "box-build",
             "the unguarded sweep enqueues a BOX build over an uploaded release"

      refute ghost.build_id == live.build_id,
             "and at a DIFFERENT build_id — the prebuilt mint folds a nonce, so the " <>
               "unforced no-op can never protect it: SWITCH would serve box-built bytes " <>
               "and RETIRE would eventually delete the upload"

      # AFTER: the guarded sweep refuses the same site instead. The summary is the
      # proof, quoted key-for-key.
      assert {:ok,
              %{
                refused: 1,
                enqueued: 0,
                duplicate: 0,
                skipped: 0,
                failed: 0,
                deferred: 0,
                code_rev_unknown: 0
              }} = sweep()
    end

    test "keys on the LIVE RELEASE's source, BOTH ways: prebuilt-current refused, enabled-but-box-built STILL SWEPT" do
      StudioLinkFakeHttpClient.program(%{})
      bp = team_fixture() |> live_barkpark()

      # (a) live release is prebuilt, and the OPT-IN FLAG IS OFF — the flag is not
      # what the guard reads.
      prebuilt = site_fixture(bp, "static", "astro") |> deployed_prebuilt(bp)
      refute prebuilt.prebuilt_enabled

      assert {:ok, %{refused: 1, enqueued: 0}} = sweep()

      # (b) the mirror image: prebuilt_enabled TRUE but the live release is a box
      # build. Keying on the flag would freeze this site's template freshness
      # forever — it must still be swept.
      _boxy =
        site_fixture(bp, "static", "astro")
        |> enable_prebuilt()
        |> deployed(bp)

      assert {:ok, %{refused: 1, enqueued: 1}} = sweep(),
             "an OPT-IN flag is not a provenance fact: a site serving box-built bytes " <>
               "must keep receiving template freshness"
    end

    test "mints NO deployment row for a refused site — the counted outcome and a log line are the whole trace" do
      StudioLinkFakeHttpClient.program(%{})
      bp = team_fixture() |> live_barkpark()
      site = site_fixture(bp, "static", "astro") |> deployed_prebuilt(bp)

      before = length(deployments(site))
      assert {:ok, %{refused: 1}} = sweep()
      # A second tick too: 24 rows/day/site would bury the deployment stream.
      assert {:ok, %{refused: 1}} = sweep()

      assert length(deployments(site)) == before,
             "the hourly sweep is a TIMER — no user intent stands behind it, so it owes no row"
    end

    test "FLEET-ABORT LANDMINE: :refused is a SEEDED key, and a healthy site on another box still builds" do
      # Mutation proof, asserted rather than trusted: `perform/1` reduces with
      # `Map.update!(acc, outcome, …)`, so returning :refused UNSEEDED raises
      # KeyError mid-reduce — aborting the sweep for the WHOLE FLEET, and
      # asymmetrically (sites ordered before the offender already enqueued).
      unseeded = %{
        enqueued: 0,
        duplicate: 0,
        skipped: 0,
        failed: 0,
        deferred: 0,
        code_rev_unknown: 0
      }

      assert_raise KeyError, fn -> Map.update!(unseeded, :refused, &(&1 + 1)) end

      # And the surviving-site half, against the real sweep: the refused site is
      # created FIRST (list_deployed_content_sites orders inserted_at ASC), so an
      # unseeded atom would have raised before the healthy site was ever visited.
      StudioLinkFakeHttpClient.program(%{})
      bp1 = team_fixture() |> live_barkpark()
      bp2 = team_fixture() |> live_barkpark("https://beta.barkpark.cloud")

      _refused = site_fixture(bp1, "static", "astro") |> deployed_prebuilt(bp1)
      healthy = site_fixture(bp2, "static", "astro") |> deployed(bp2)

      assert {:ok, %{refused: 1, enqueued: 1, failed: 0, skipped: 0}} = sweep()

      assert Enum.any?(deployments(healthy), &(&1.trigger == "template-auto")),
             "one refused site must never cost the rest of the fleet its freshness sweep"
    end

    test "a refused site costs NO analytics read — the guard runs before the box is touched" do
      StudioLinkFakeHttpClient.program(%{})
      bp = team_fixture() |> live_barkpark()
      _site = site_fixture(bp, "static", "astro") |> deployed_prebuilt(bp)

      StudioLinkFakeHttpClient.program(%{})
      assert {:ok, %{refused: 1}} = sweep()
      assert analytics_reads() == 0
    end
  end

  describe "the trigger enum" do
    test "template-auto passes the Deployment changeset (an unlisted trigger is rejected)" do
      StudioLinkFakeHttpClient.program(%{})
      bp = team_fixture() |> live_barkpark()
      site = site_fixture(bp, "static", "astro")

      assert {:ok, %Deployment{trigger: "template-auto"}} =
               Registry.create_deployment(site, %{
                 build_id: "abc123abc123abc1",
                 trigger: "template-auto"
               })

      assert {:error, cs} =
               Registry.create_deployment(site, %{
                 build_id: "def456def456def4",
                 trigger: "cron-vibes"
               })

      assert "is invalid" in errors_on(cs).trigger
    end
  end
end
