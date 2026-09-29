defmodule BarkparkCloud.RegistrySiteDomainClaimsMigrationTest do
  @moduledoc """
  Runs the `add_site_domains_to_hostname_claims` MIGRATION MODULE ITSELF —
  `down/0` then `up/0` through `Ecto.Migrator` — over production-shaped
  collisions and junk domains, because the control plane auto-deploys
  migrations and one that raises strands prod.

  HOW, inside the sandbox: Postgres DDL is transactional. The test seeds the
  rows with the table in its current shape, runs `Ecto.Migrator.down/4` (drops
  the site claims, the owner CHECK and `site_id`, restores the old kind CHECK
  and `barkpark_id NOT NULL`, deletes the version row), writes the site domains
  AROUND the claims (as every pre-migration row was written), then runs
  `Ecto.Migrator.up/4`. `migration_lock: false` because the migrator's lock
  needs a second connection the sandbox does not have. The sandbox rollback
  restores everything.
  """
  use BarkparkCloud.DataCase, async: false

  import ExUnit.CaptureLog

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{HostnameClaim, Site}

  @version 20_260_925_182_656
  @path "priv/repo/migrations/20260925182656_add_site_domains_to_hostname_claims.exs"

  setup do
    mod =
      case Code.ensure_loaded(BarkparkCloud.Repo.Migrations.AddSiteDomainsToHostnameClaims) do
        {:module, m} -> m
        _ -> @path |> Code.require_file() |> hd() |> elem(0)
      end

    %{mod: mod}
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(
        team_fixture(),
        Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"})
      )

    bp
  end

  defp site_fixture(bp) do
    n = System.unique_integer([:positive])
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # Write domains around the claims (and around the cross-site trigger, which
  # the test disables inside its transaction to seed a legacy site-vs-site dup).
  defp raw_domains(site, domains, days_old) do
    at = DateTime.add(DateTime.utc_now(), -days_old, :day)

    {1, _} =
      Repo.update_all(from(s in Site, where: s.id == ^site.id),
        set: [domains: domains, inserted_at: at]
      )
  end

  defp holder(host) do
    case Repo.get_by(HostnameClaim, host: host) do
      nil -> nil
      %HostnameClaim{site_id: s, barkpark_id: b, kind: k} -> {s || b, k}
    end
  end

  test "down/0 then up/0 completes green: existing claims hold, site collisions skipped and logged, junk never claimed",
       %{mod: mod} do
    n = System.unique_integer([:positive])
    h_custom = "custom-#{n}.example.com"
    h_url = "url-#{n}.example.com"
    h_free = "free-#{n}.example.com"
    h_sites = "sites-#{n}.example.com"

    live = barkpark_fixture()
    {:ok, _} = Registry.set_custom_host(live, h_custom)
    ghost = barkpark_fixture(%{url: "https://" <> h_url})

    older = site_fixture(barkpark_fixture())
    newer = site_fixture(barkpark_fixture())
    junky = site_fixture(barkpark_fixture())

    assert :ok = Ecto.Migrator.down(Repo, @version, mod, log: false, migration_lock: false)

    Repo.query!("ALTER TABLE sites DISABLE TRIGGER sites_domain_cross_site_uniqueness")
    raw_domains(older, [h_custom, h_url, h_free, h_sites], 90)
    raw_domains(newer, [h_sites], 10)
    raw_domains(junky, ["-", ".", "", "https://", ".-.", "https:///"], 5)
    Repo.query!("ALTER TABLE sites ENABLE TRIGGER sites_domain_cross_site_uniqueness")

    log =
      capture_log(fn ->
        assert :ok = Ecto.Migrator.up(Repo, @version, mod, log: false, migration_lock: false)
      end)

    # Existing barkpark claims hold; the older site holds a site-vs-site dup.
    assert holder(h_custom) == {live.id, "custom_host"}
    assert holder(h_url) == {ghost.id, "url"}
    assert holder(h_free) == {older.id, "site_domain"}
    assert holder(h_sites) == {older.id, "site_domain"}

    for {h, loser, held_by, held_as} <- [
          {h_custom, older.id, "barkpark #{live.id}", "custom_host"},
          {h_url, older.id, "barkpark #{ghost.id}", "url"},
          {h_sites, newer.id, "site #{older.id}", "site_domain"}
        ] do
      assert log =~
               "SKIPPED pre-existing collision on #{h} — site #{loser} (site_domain) left unclaimed; " <>
                 "held by #{held_by} (#{held_as})"
    end

    refute Repo.exists?(from(c in HostnameClaim, where: c.site_id == ^junky.id))
    refute Repo.exists?(from(c in HostnameClaim, where: c.host in ["", "-", ".-", "https"]))

    # The site rows are untouched.
    assert Repo.get!(Site, older.id).domains == [h_custom, h_url, h_free, h_sites]
    assert Repo.get!(Site, newer.id).domains == [h_sites]
  end
end
