defmodule BarkparkCloud.SiteTeamDriftTest do
  @moduledoc """
  task-69d84bc7f15c88d6. `sites.team_id` is stamped from the box at create and
  never again, so a box moved between teams leaves its sites on the old team.
  `Registry.site_team_drift/1` is the census that names such a site.

  The move is done the only way one can happen today — out of band, on the
  `barkparks` row — because no in-tree path writes `barkparks.team_id` after
  insert (the ruling in `BarkparkCloud.Registry.Site`'s moduledoc).
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo}

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp site_on_box(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "App #{n}",
        slug: "app-#{n}",
        kind: "container",
        framework: "nextjs"
      })

    {bp, site}
  end

  test "a fixture with NO move reports zero drift (positive control on the fixture)" do
    team = team_fixture()
    {bp, site} = site_on_box(team)

    # The fixture really is a site on that box, owned by that team — so an empty
    # answer below is about drift, not about a query that cannot see the row.
    assert site.barkpark_id == bp.id
    assert site.team_id == bp.team_id
    assert Registry.site_team_drift(site_ids: [site.id]) == []
  end

  test "moving the box between teams makes the census name the site with both team ids" do
    old_team = team_fixture()
    new_team = team_fixture()
    {bp, site} = site_on_box(old_team)

    bp |> Ecto.Changeset.change(team_id: new_team.id) |> Repo.update!()

    assert [row] = Registry.site_team_drift(site_ids: [site.id])
    assert row.site_id == site.id
    assert row.slug == site.slug
    assert row.site_team_id == old_team.id
    assert row.barkpark_id == bp.id
    assert row.barkpark_team_id == new_team.id

    # And the drift is what every sites.team_id reader follows: the new owner
    # does not see the site, the old one still does.
    refute Enum.any?(Registry.list_sites_for_team(new_team), &(&1.id == site.id))
    assert Enum.any?(Registry.list_sites_for_team(old_team), &(&1.id == site.id))
  end

  test "no in-tree changeset on an existing box casts team_id (the ruling's premise)" do
    team = team_fixture()
    other = team_fixture()
    {bp, _site} = site_on_box(team)

    # Every UPDATE changeset the Barkpark schema exposes drops a team_id change.
    for fun <- [
          :health_changeset,
          :suspend_changeset,
          :update_status_changeset,
          :verify_changeset,
          :fleet_changeset,
          :autoupdate_changeset,
          :channel_changeset,
          :vercel_changeset,
          :custom_host_changeset,
          :staleness_changeset
        ] do
      cs = apply(BarkparkCloud.Registry.Barkpark, fun, [bp, %{team_id: other.id}])

      assert Ecto.Changeset.get_change(cs, :team_id) == nil,
             "Barkpark.#{fun}/2 now casts team_id — a box-move door exists; it must re-stamp sites.team_id"
    end
  end
end
