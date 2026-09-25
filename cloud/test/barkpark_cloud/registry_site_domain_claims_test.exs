defmodule BarkparkCloud.RegistrySiteDomainClaimsTest do
  @moduledoc """
  task-274fad4f639e6890 — site domains in `hostname_claims`, in the sandbox.

  Every site domain write and removal claims / releases its host in the same
  transaction; a claim the pre-check cannot see (the state a lost race leaves)
  is refused by the UNIQUE index with the doors' existing error shapes; the
  abandoned-url carve-out still reclaims; the backfill skips and reports a
  pre-existing collision. The two-connection race is
  `registry_site_domain_claims_race_test.exs`.
  """
  use BarkparkCloud.DataCase, async: true

  import ExUnit.CaptureLog

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, HostnameClaim, Site}

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team \\ team_fixture(), attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  defp site_fixture(bp, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, site} = Registry.create_site(bp, Enum.into(attrs, %{name: "S #{n}", slug: "s-#{n}"}))
    site
  end

  defp host(label), do: "#{label}-#{System.unique_integer([:positive])}.example.com"
  defp claim(host), do: Repo.get_by(HostnameClaim, host: host)

  describe "every site domain write claims, every removal releases" do
    test "create_site/2 claims each domain as a site_domain" do
      a = host("create-a")
      b = host("create-b")
      site = site_fixture(barkpark_fixture(), domains: [String.upcase(a) <> ".", b])

      for h <- [a, b] do
        assert %HostnameClaim{kind: "site_domain", site_id: sid, barkpark_id: nil} = claim(h)
        assert sid == site.id
      end
    end

    test "add_site_domain/2 claims; remove_site_domain/2 releases; the name is free again" do
      h = host("add")
      site = site_fixture(barkpark_fixture())

      assert {:ok, site} = Registry.add_site_domain(site, h)
      assert %HostnameClaim{kind: "site_domain", site_id: sid} = claim(h)
      assert sid == site.id

      assert {:ok, %Site{domains: []}} = Registry.remove_site_domain(site, h)
      refute claim(h)

      other = barkpark_fixture()
      assert {:ok, %Barkpark{custom_host: ^h}} = Registry.set_custom_host(other, h)
    end

    test "delete_site/1 and deleting the barkpark release the site's claims (FK cascade)" do
      h1 = host("del-site")
      h2 = host("del-box")
      bp = barkpark_fixture()
      s1 = site_fixture(bp, domains: [h1])
      _s2 = site_fixture(bp, domains: [h2])

      assert {:ok, _, _} = Registry.delete_site(s1)
      refute claim(h1)
      assert claim(h2)

      assert {:ok, _} = Registry.delete_barkpark(bp)
      refute claim(h2)
    end

    test "a malformed domain is refused by the changeset and claims nothing" do
      site = site_fixture(barkpark_fixture())
      before = Repo.aggregate(HostnameClaim, :count)

      assert {:error, %Ecto.Changeset{}} = Registry.add_site_domain(site, "not a domain")
      assert Repo.aggregate(HostnameClaim, :count) == before
    end

    test "removing a domain releases only THIS site's claim" do
      h = host("foreign")
      holder = barkpark_fixture()
      {:ok, _} = Registry.set_custom_host(holder, h)
      site = site_fixture(barkpark_fixture())

      assert {:ok, _} = Registry.remove_site_domain(site, h)
      assert %HostnameClaim{kind: "custom_host"} = claim(h)
    end
  end

  describe "the database refuses a claim the pre-check cannot see" do
    # The state a racing writer leaves between this door's pre-check and its
    # write: the claim is committed, but no column the pre-check walks names
    # the host yet.
    test "add_site_domain/2 vs a barkpark custom_host claim → {:error, :domain_taken}" do
      h = host("lost-add")
      racer = barkpark_fixture()
      Repo.insert!(%HostnameClaim{host: h, barkpark_id: racer.id, kind: "custom_host"})

      site = site_fixture(barkpark_fixture())
      assert {:error, :domain_taken} = Registry.add_site_domain(site, h)
      assert Repo.get!(Site, site.id).domains == []
      assert %HostnameClaim{barkpark_id: holder} = claim(h)
      assert holder == racer.id
    end

    test "create_site/2 vs a barkpark custom_host claim → {:error, :domain_taken}, no row left" do
      h = host("lost-create")
      racer = barkpark_fixture()
      Repo.insert!(%HostnameClaim{host: h, barkpark_id: racer.id, kind: "custom_host"})

      bp = barkpark_fixture()

      assert {:error, :domain_taken} =
               Registry.create_site(bp, %{name: "Lost", slug: "lost", domains: [h]})

      refute Repo.exists?(from(s in Site, where: s.barkpark_id == ^bp.id))
    end

    test "set_custom_host/2 vs a site_domain claim → {:error, :taken}" do
      h = host("lost-attach")
      holder_site = site_fixture(barkpark_fixture())
      Repo.insert!(%HostnameClaim{host: h, site_id: holder_site.id, kind: "site_domain"})

      attacher = barkpark_fixture()
      assert {:error, :taken} = Registry.set_custom_host(attacher, h)
      assert Repo.get!(Barkpark, attacher.id).custom_host == nil
    end
  end

  test "an abandoned row's url claim is taken over by a site the pre-check allows" do
    h = host("ghost")
    ghost = barkpark_fixture(team_fixture(), %{url: "https://" <> h})

    ghost
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -30, :day))
    |> Repo.update!()

    site = site_fixture(barkpark_fixture())
    assert {:ok, _} = Registry.add_site_domain(site, h)
    assert %HostnameClaim{kind: "site_domain", site_id: sid, barkpark_id: nil} = claim(h)
    assert sid == site.id
  end

  test "the owner CHECK pins one owner column per kind" do
    bp = barkpark_fixture()

    assert_raise Ecto.ConstraintError, ~r/hostname_claims_owner_check/, fn ->
      Repo.insert!(%HostnameClaim{host: host("both"), barkpark_id: bp.id, kind: "site_domain"})
    end
  end

  describe "backfill_site_domain_claims/1" do
    test "a site domain colliding with a custom_host is SKIPPED and logged; the custom_host holds" do
      h = host("dup")
      holder = barkpark_fixture()
      {:ok, _} = Registry.set_custom_host(holder, h)

      site = site_fixture(barkpark_fixture())
      # Pre-table state: the domain written around the claims.
      {1, _} = Repo.update_all(from(s in Site, where: s.id == ^site.id), set: [domains: [h]])

      log =
        capture_log(fn ->
          %{skipped: skipped} = Registry.backfill_site_domain_claims(Repo)
          send(self(), {:skipped, skipped})
        end)

      assert_received {:skipped, skipped}
      site_id = site.id
      holder_id = holder.id

      assert [%{site_id: ^site_id, held_by: ^holder_id, held_as: "custom_host"}] =
               Enum.filter(skipped, &(&1.host == h))

      assert log =~
               "SKIPPED pre-existing collision on #{h} — site #{site.id} (site_domain) left unclaimed; " <>
                 "held by barkpark #{holder.id} (custom_host)"

      assert %HostnameClaim{kind: "custom_host"} = claim(h)
      assert Repo.get!(Site, site.id).domains == [h]
    end
  end
end
