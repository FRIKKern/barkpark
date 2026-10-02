defmodule BarkparkCloud.RegistrySiteDomainClaimsRaceTest do
  @moduledoc """
  task-274fad4f639e6890 — a site domain vs a barkpark hostname, on two REAL
  connections (same harness as `registry_hostname_claims_race_test.exs`:
  `Sandbox.mode(:auto)`, a two-phase barrier with no sleep, assertions read
  from committed rows, teams deleted in `on_exit`).

  WHICH PAIR CAN ACTUALLY RACE. `set_custom_host/2`, `add_site_domain/2` and
  `create_site/2` all take the per-hostname advisory lock, so two of them never
  interleave — the second blocks on the LOCK and its pre-check then sees the
  first (`registry_hostname_claim_race_test.exs` pins that). Provisioning takes
  no lock: a barkpark url host committed after a site door's pre-check read the
  namespace was invisible to every guard before this change. That is the pair
  here, in both directions and for both site doors. The sandbox twin in
  `registry_site_domain_claims_test.exs` pins the custom_host shape of the same
  refusal (a committed claim the pre-check cannot see).
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, HostnameClaim, Site}

  @slug_prefix "sdclaims"
  @blocked_ms 3_000
  @racer_ms 30_000

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    host = "sdclaims-#{System.unique_integer([:positive])}.example.com"

    on_exit(fn ->
      Repo.delete_all(from(t in Team, where: like(t.slug, ^(@slug_prefix <> "-%"))))
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    %{host: host}
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "#{@slug_prefix}-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp site_fixture(bp) do
    n = System.unique_integer([:positive])
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # Surfaces answering on `host`, across both tables. The invariant: one.
  defp owners(host) do
    boxes =
      Repo.aggregate(from(b in Barkpark, where: b.url == ^("https://" <> host)), :count, :id)

    sites =
      Repo.aggregate(
        from(s in Site, where: fragment("? = ANY(?)", ^host, s.domains)),
        :count,
        :id
      )

    boxes + sites
  end

  defp spawn_racer(fun) do
    parent = self()
    ref = make_ref()

    {pid, mon} =
      spawn_monitor(fn ->
        result =
          try do
            fun.(parent, ref)
          rescue
            e -> {:infra, e}
          catch
            :exit, reason -> {:infra, reason}
          end

        send(parent, {ref, :done, result})
      end)

    %{pid: pid, mon: mon, ref: ref}
  end

  defp await_done(%{ref: ref, mon: mon}) do
    receive do
      {^ref, :done, result} -> result
      {:DOWN, ^mon, :process, _, reason} -> {:infra, reason}
    after
      @racer_ms -> {:infra, :timeout}
    end
  end

  defp race(first, second) do
    a =
      spawn_racer(fn parent, ref ->
        Repo.transaction(
          fn ->
            result = first.()
            send(parent, {ref, :wrote, result})

            receive do
              {^ref, :commit} -> :ok
            after
              @racer_ms -> :ok
            end

            result
          end,
          timeout: @racer_ms
        )
      end)

    a_ref = a.ref
    assert_receive {^a_ref, :wrote, {:ok, _}}, @racer_ms

    b =
      spawn_racer(fn parent, ref ->
        {:ok, result} =
          Repo.transaction(
            fn ->
              result = second.()
              send(parent, {ref, :verdict, result})
              result
            end,
            timeout: @racer_ms
          )

        result
      end)

    b_ref = b.ref

    b_early? =
      receive do
        {^b_ref, :verdict, _} -> true
      after
        @blocked_ms -> false
      end

    send(a.pid, {a.ref, :commit})
    {await_done(a), await_done(b), b_early?}
  end

  test "provision url FIRST, add_site_domain SECOND → the site door's {:error, :domain_taken}",
       %{host: host} do
    provisioner = team_fixture()
    site = team_fixture() |> barkpark_fixture() |> site_fixture()

    {a, b, b_early?} =
      race(
        fn ->
          Registry.register_barkpark(provisioner, %{name: "P", slug: "p", url: "https://" <> host})
        end,
        fn -> Registry.add_site_domain(site, host) end
      )

    assert {:ok, {:ok, %Barkpark{}}} = a

    assert owners(host) == 1, """
    #{owners(host)} surfaces answer on #{host}: a barkpark url AND a site domain both
    committed. A: #{inspect(a)} B: #{inspect(b)} (B answered before A committed? #{b_early?})
    """

    assert b == {:error, :domain_taken}
    refute b_early?, "B answered while A was uncommitted — the claims index never blocked it"
    assert %HostnameClaim{kind: "url"} = Repo.get_by(HostnameClaim, host: host)
  end

  test "provision url FIRST, create_site SECOND → {:error, :domain_taken}, no site row",
       %{host: host} do
    provisioner = team_fixture()
    bp = team_fixture() |> barkpark_fixture()

    {a, b, b_early?} =
      race(
        fn ->
          Registry.register_barkpark(provisioner, %{name: "P", slug: "p", url: "https://" <> host})
        end,
        fn -> Registry.create_site(bp, %{name: "Late", slug: "late", domains: [host]}) end
      )

    assert {:ok, {:ok, %Barkpark{}}} = a
    assert owners(host) == 1, "A: #{inspect(a)} B: #{inspect(b)} early? #{b_early?}"
    assert b == {:error, :domain_taken}
    refute b_early?
    refute Repo.exists?(from(s in Site, where: s.barkpark_id == ^bp.id))
  end

  test "add_site_domain FIRST, provision url SECOND → the url-index error shape",
       %{host: host} do
    site = team_fixture() |> barkpark_fixture() |> site_fixture()
    provisioner = team_fixture()

    {a, b, b_early?} =
      race(
        fn -> Registry.add_site_domain(site, host) end,
        fn ->
          Registry.register_barkpark(provisioner, %{name: "P", slug: "p", url: "https://" <> host})
        end
      )

    assert {:ok, {:ok, %Site{}}} = a
    assert owners(host) == 1, "A: #{inspect(a)} B: #{inspect(b)} early? #{b_early?}"
    assert {:error, %Ecto.Changeset{errors: errors}} = b
    assert {"is already provisioned", opts} = errors[:url]
    assert opts[:constraint] == :unique
    refute b_early?
    assert %HostnameClaim{kind: "site_domain"} = Repo.get_by(HostnameClaim, host: host)
  end
end
