defmodule BarkparkCloud.Registry.DeploymentSourceTest do
  @moduledoc """
  site-spawner W9 (charter D86/D87) — the PROVENANCE columns behind a prebuilt
  deploy: `deployments.source`, `deployments.artifact_sha256`, and
  `sites.prebuilt_enabled`.

  The failure this file exists to catch is a SILENT one. A cast list that misses
  a field does not error: the changeset is valid, the insert succeeds, the route
  answers 201, and the column simply holds its default forever. There are FIVE
  independent cast paths for these three fields (Deployment.changeset/2, the
  separately-forked Deployment.preview_changeset/2, Site.changeset/2,
  Site.settings_changeset/2, and the router's own hard-coded Map.take/2
  allow-list) plus ONE that must deliberately NOT carry them
  (Deployment.transition_changeset/2). Each is pinned here or in the router
  suite, because each can drift alone.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.{Deployment, Site}

  @sha "aa" <> String.duplicate("bc", 31)

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp site_fixture do
    n = System.unique_integer([:positive])
    team = team_fixture()
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "Site #{n}", slug: "site-#{n}"})
    site
  end

  ## ---------------------------------------------------------------------------
  ## The migration's defaults — what an EXISTING row reads as
  ## ---------------------------------------------------------------------------

  describe "the migrated columns" do
    test "a deployment minted with no source at all reads box-build" do
      site = site_fixture()

      # Exactly the pre-W9 call shape: no `source` key anywhere. This is the
      # stand-in for the 13,932 rows already in prod — they backfill by column
      # default, with no data migration.
      {:ok, deployment} = Registry.create_deployment(site, %{git_ref: "abc123"})

      assert Repo.get!(Deployment, deployment.id).source == "box-build"
      assert Repo.get!(Deployment, deployment.id).artifact_sha256 == nil
    end

    test "a site created with no prebuilt flag defaults to OFF" do
      site = site_fixture()

      refute Repo.get!(Site, site.id).prebuilt_enabled
    end

    test "the source vocabulary is exactly box-build | prebuilt" do
      assert Deployment.sources() == ~w(box-build prebuilt)
    end

    test "prebuilt?/1 reads the column, so callers never re-spell the literal" do
      assert Deployment.prebuilt?(%Deployment{source: "prebuilt"})
      refute Deployment.prebuilt?(%Deployment{source: "box-build"})
    end
  end

  ## ---------------------------------------------------------------------------
  ## The FIVE cast paths (four here, the router's Map.take in the router suite)
  ## ---------------------------------------------------------------------------

  describe "cast coverage" do
    test "Deployment.changeset/2 carries source AND artifact_sha256 to the row" do
      site = site_fixture()

      {:ok, deployment} =
        Registry.create_deployment(site, %{source: "prebuilt", artifact_sha256: @sha})

      stored = Repo.get!(Deployment, deployment.id)
      assert stored.source == "prebuilt"
      assert stored.artifact_sha256 == @sha
    end

    test "Deployment.preview_changeset/2 carries them too — it is a FORK, not a delegation" do
      # A field added only to changeset/2 would be silently dropped on every
      # branch-preview deploy: 201, a queued row, and a build that quietly ran on
      # the box. Nothing would have errored.
      cs =
        Deployment.preview_changeset(%Deployment{}, %{
          site_id: Ecto.UUID.generate(),
          branch: "feature/x",
          preview_slug: "feature-x-ab12",
          preview_host: "feature-x-ab12.example.com",
          source: "prebuilt",
          artifact_sha256: @sha
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :source) == "prebuilt"
      assert Ecto.Changeset.get_change(cs, :artifact_sha256) == @sha
    end

    test "an unknown source is a validation error on BOTH create changesets" do
      base = %{site_id: Ecto.UUID.generate()}

      refute Deployment.changeset(%Deployment{}, Map.put(base, :source, "prebuilt-v2")).valid?

      preview =
        Map.merge(base, %{
          branch: "b",
          preview_slug: "b-ab12",
          preview_host: "b-ab12.example.com",
          source: "prebuilt-v2"
        })

      refute Deployment.preview_changeset(%Deployment{}, preview).valid?
    end

    test "transition_changeset/2 REFUSES to restate provenance" do
      # Provenance is create-time. A builder that could rewrite `source` could
      # relabel an off-box artifact as a box build after the fact — and the
      # ledger, which is the only record of what HEALTH certified, would agree
      # with it.
      cs =
        Deployment.transition_changeset(%Deployment{source: "prebuilt", artifact_sha256: @sha}, %{
          status: "building",
          source: "box-build",
          artifact_sha256: "deadbeef"
        })

      assert Ecto.Changeset.get_change(cs, :source) == nil
      assert Ecto.Changeset.get_change(cs, :artifact_sha256) == nil
      assert Ecto.Changeset.get_change(cs, :status) == "building"
    end

    test "Site.changeset/2 carries prebuilt_enabled (settable at create)" do
      n = System.unique_integer([:positive])
      team = team_fixture()
      {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

      {:ok, site} =
        Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}", prebuilt_enabled: true})

      assert Repo.get!(Site, site.id).prebuilt_enabled
    end

    test "Site.settings_changeset/2 can flip prebuilt_enabled between deploys" do
      site = site_fixture()

      {:ok, updated} = Registry.update_site_settings(site, %{prebuilt_enabled: true})

      assert Repo.get!(Site, updated.id).prebuilt_enabled
    end
  end
end
