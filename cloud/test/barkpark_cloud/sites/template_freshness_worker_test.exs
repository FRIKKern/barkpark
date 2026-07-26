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
    |> Ecto.Changeset.change(current_deployment_id: marker.id)
    |> Repo.update!()
  end

  defp deployments(site), do: Registry.list_deployments(site)

  defp sweep, do: TemplateFreshnessWorker.perform(%Oban.Job{args: %{}})

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
