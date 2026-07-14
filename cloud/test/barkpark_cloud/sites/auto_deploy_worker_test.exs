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
  alias BarkparkCloud.Sites.{AutoDeployWorker, Deploy}

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
end
