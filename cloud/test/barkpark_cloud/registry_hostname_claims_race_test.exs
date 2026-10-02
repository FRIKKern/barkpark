defmodule BarkparkCloud.RegistryHostnameClaimsRaceTest do
  @moduledoc """
  dr-w24-bl-hostname-claims-table-backstop — the url/custom_host race, on two
  REAL connections.

  The advisory lock in `hostname_claimed?/2` serialises the three claim doors
  that take it (`add_site_domain/2`, `create_site/2`, `set_custom_host/2`).
  PROVISIONING does not take it: `register_barkpark/2` writes a url with no
  hostname lock at all, so a provision of `https://h` and an attach of `h` as a
  custom_host were a check-then-write pair with nothing between them. The two
  per-column unique indexes cannot see across columns, so before
  `hostname_claims` both committed.

  Same harness as `registry_hostname_claim_race_test.exs` (read its moduledoc
  for why the sandbox cannot be used): `Sandbox.mode(:auto)`, a two-phase
  barrier with no sleep, assertions read from committed rows, and `on_exit`
  deletes the teams (which cascade to barkparks and to hostname_claims).
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, HostnameClaim}

  @slug_prefix "hclaims"
  @blocked_ms 3_000
  @racer_ms 30_000

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    host = "hclaims-#{System.unique_integer([:positive])}.example.com"

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

  # Every barkparks row that answers on `host`, from EITHER column. The
  # invariant: exactly one.
  defp owners(host) do
    Repo.aggregate(
      from(b in Barkpark,
        where: b.custom_host == ^host or b.url == ^("https://" <> host)
      ),
      :count,
      :id
    )
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

  # Racer A runs `first` in a transaction and holds it open, uncommitted; then
  # racer B runs `second` in its own transaction on its own connection.
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
    assert_receive {^a_ref, :wrote, {:ok, %Barkpark{}}}, @racer_ms

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

  test "provision url FIRST, attach custom_host SECOND → the attach gets the pre-check's {:error, :taken}",
       %{host: host} do
    provisioner = team_fixture()
    attacher = team_fixture() |> barkpark_fixture()

    {a, b, b_early?} =
      race(
        fn ->
          Registry.register_barkpark(provisioner, %{name: "P", slug: "p", url: "https://" <> host})
        end,
        fn -> Registry.set_custom_host(attacher, host) end
      )

    assert {:ok, {:ok, %Barkpark{}}} = a

    assert owners(host) == 1, """
    #{owners(host)} barkparks rows answer on #{host}: a url host and a custom_host
    both committed. A: #{inspect(a)} B: #{inspect(b)} (B answered before A committed? #{b_early?})
    """

    assert b == {:error, :taken},
           "the loser must get the pre-check's refusal shape (got #{inspect(b)})"

    refute b_early?,
           "B answered while A was uncommitted — it was never blocked by the claims index"

    assert %HostnameClaim{kind: "url"} = Repo.get_by(HostnameClaim, host: host)
  end

  test "attach custom_host FIRST, provision url SECOND → the provision gets the url-index error shape",
       %{host: host} do
    attacher = team_fixture() |> barkpark_fixture()
    provisioner = team_fixture()

    {a, b, b_early?} =
      race(
        fn -> Registry.set_custom_host(attacher, host) end,
        fn ->
          Registry.register_barkpark(provisioner, %{name: "P", slug: "p", url: "https://" <> host})
        end
      )

    assert {:ok, {:ok, %Barkpark{}}} = a

    assert owners(host) == 1,
           "#{owners(host)} rows answer on #{host}. A: #{inspect(a)} B: #{inspect(b)}"

    assert {:error, %Ecto.Changeset{errors: errors}} = b
    assert {"is already provisioned", opts} = errors[:url]
    assert opts[:constraint] == :unique
    refute b_early?
    assert %HostnameClaim{kind: "custom_host"} = Repo.get_by(HostnameClaim, host: host)
  end
end
