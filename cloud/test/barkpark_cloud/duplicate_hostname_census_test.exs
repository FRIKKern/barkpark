defmodule BarkparkCloud.DuplicateHostnameCensusTest do
  @moduledoc """
  task-b51e13714022da8f — the prod-duplicate hostname audit the
  `add_domain_cross_site_uniqueness` migration deferred to.

  The duplicates it must find predate every claim door, so the fixtures write
  the owning columns directly (the only way such a row can exist today): a site's
  `domains` via a plain changeset, a box's `custom_host` via a plain changeset,
  and — for site<->site — with the cross-site trigger disabled inside this test's
  transaction (rolled back with it). Every assertion is scoped to the test's own
  unique hostnames: the census reads the whole shared test database.

  async: false because the site<->site arm takes a table lock (ALTER TABLE).
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias Mix.Tasks.BarkparkCloud.DuplicateHostnames

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp box(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "App #{n}",
        slug: "app-#{n}",
        kind: "container",
        framework: "nextjs"
      })

    site
  end

  defp set_domains(site, domains),
    do: site |> Ecto.Changeset.change(domains: domains) |> Repo.update!()

  defp set_custom_host(bp, host),
    do: bp |> Ecto.Changeset.change(custom_host: host) |> Repo.update!()

  defp host, do: "dup-#{System.unique_integer([:positive])}.example.test"

  defp census_for(host), do: Enum.find(Registry.duplicate_hostname_census(), &(&1.host == host))

  test "POSITIVE CONTROL: a hostname held once is not a duplicate, and the scan does see it" do
    h = host()
    s = set_domains(site(box(team_fixture())), [h])

    # The row IS readable by the same key the census uses…
    assert Registry.hostname_claim_key(h) == h
    assert h in Repo.reload!(s).domains
    # …and a single holder is not reported.
    assert census_for(h) == nil
  end

  test "a site domain that another TEAM's box serves as custom_host is a cross-team duplicate" do
    h = host()
    team_a = team_fixture()
    team_b = team_fixture()
    s = set_domains(site(box(team_a)), [h])
    other = set_custom_host(box(team_b), String.upcase(h) <> ".")

    row = census_for(h)
    assert row, "the census missed #{h}"
    assert row.cross_team
    assert Enum.sort(row.teams) == Enum.sort([team_a.id, team_b.id])

    assert Enum.map(row.holders, &{&1.kind, &1.id, &1.column}) |> Enum.sort() ==
             Enum.sort([{"barkpark", other.id, "custom_host"}, {"site", s.id, "domains"}])
  end

  test "two sites holding one domain (pre-trigger rows) are reported, same-team flagged" do
    h = host()
    team = team_fixture()
    bp = box(team)
    a = set_domains(site(bp), [h])

    Repo.query!("ALTER TABLE sites DISABLE TRIGGER sites_domain_cross_site_uniqueness")
    b = set_domains(site(bp), [h])
    Repo.query!("ALTER TABLE sites ENABLE TRIGGER sites_domain_cross_site_uniqueness")

    row = census_for(h)
    assert row
    refute row.cross_team
    assert row.teams == [team.id]
    assert Enum.sort(Enum.map(row.holders, & &1.id)) == Enum.sort([a.id, b.id])
  end

  test "a box whose url and custom_host key the same host is ONE owner, not a duplicate" do
    h = host()
    bp = box(team_fixture())
    bp |> Ecto.Changeset.change(url: "https://#{h}", custom_host: h) |> Repo.update!()

    assert census_for(h) == nil
  end

  test "the mix task renders the count and names the cross-team holders" do
    assert DuplicateHostnames.render([]) =~ "duplicate hostnames: 0"

    out =
      DuplicateHostnames.render([
        %{
          host: "x.example.test",
          cross_team: true,
          teams: ["t1", "t2"],
          holders: [
            %{kind: "site", id: "s1", slug: "blog", team_id: "t1", column: "domains"},
            %{kind: "barkpark", id: "b1", slug: "box", team_id: "t2", column: "custom_host"}
          ]
        }
      ])

    assert out =~ "duplicate hostnames: 1 (1 cross-team, 0 same-team)"
    assert out =~ "x.example.test [CROSS-TEAM]"
    assert out =~ "site blog (s1) team t1 via domains"
    assert out =~ "barkpark box (b1) team t2 via custom_host"
  end
end
