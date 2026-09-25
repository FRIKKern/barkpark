defmodule BarkparkCloud.RegistryHostnameClaimsMigrationTest do
  @moduledoc """
  Runs the `create_hostname_claims` MIGRATION MODULE ITSELF — its `up/0`,
  through `Ecto.Migrator.up/4` — against production-shaped data, because the
  control plane auto-deploys migrations and one that raises strands prod.

  HOW, inside the sandbox: Postgres DDL is transactional, so within the test's
  sandbox transaction we `DROP TABLE hostname_claims` and delete this version's
  `schema_migrations` row, seed the rows, and call `Ecto.Migrator.up/4`, which
  sees the version as pending and runs `up/0` (table, indexes, CHECKs, the
  `LOCK TABLE barkparks`, the backfill). The sandbox rollback at test end
  restores the table and the version row. `async: false` + shared sandbox mode
  so the migrator's processes use the test's connection.
  """
  use BarkparkCloud.DataCase, async: false

  import ExUnit.CaptureLog

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Barkpark

  # SCHEMALESS reads on purpose: this test rebuilds the table as THIS migration
  # left it, and later migrations (add_site_domains_to_hostname_claims) add
  # columns the `HostnameClaim` schema now selects.
  @claims "hostname_claims"

  @version 20_260_925_152_031
  @path "priv/repo/migrations/20260925152031_create_hostname_claims.exs"

  setup do
    [{mod, _}] =
      case Code.ensure_loaded(BarkparkCloud.Repo.Migrations.CreateHostnameClaims) do
        {:module, m} -> [{m, nil}]
        _ -> Code.require_file(@path)
      end

    %{mod: mod}
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # A row written AROUND the claims (as every pre-migration row was), with its
  # url / custom_host / inserted_at set raw.
  defp raw_row(team, fields) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp |> Ecto.Changeset.change(fields) |> Repo.update!()
  end

  test "hostname_claim_key/1 never yields an empty or letterless host" do
    for junk <-
          [nil, "", "   ", "https://", "https:///", "https://:443", "https://:443/x"] ++
            [".", "...", "-", ".-.", "https://-/", 42] do
      assert Registry.hostname_claim_key(junk) == nil, "#{inspect(junk)} must claim nothing"
    end

    assert Registry.hostname_claim_key(" HTTPS://Gyldendal.Barkpark.Cloud./") ==
             "gyldendal.barkpark.cloud"
  end

  test "up/0 completes green on the Gyldendal ghost shape plus junk hosts; B holds, A is skipped and logged",
       %{mod: mod} do
    host = "gyldendal-#{System.unique_integer([:positive])}.barkpark.cloud"
    team = team_fixture()
    old = fn days -> DateTime.add(DateTime.utc_now(), -days, :day) end

    ghost = raw_row(team, url: "https://#{host}/", inserted_at: old.(90))
    variant = raw_row(team, url: " HTTPS://#{String.upcase(host)}.", inserted_at: old.(80))
    live = raw_row(team, custom_host: host, inserted_at: old.(60))

    # The worst junk each column can hold. None may be inserted.
    junk =
      for url <- ["https://", "https:///", "https://:443", "https://-/", "/"] do
        raw_row(team, url: url)
      end ++
        for ch <- [".", "-", ".-."] do
          raw_row(team, custom_host: ch)
        end

    # Back to the pre-migration world, inside the sandbox transaction.
    Repo.query!("DROP TABLE hostname_claims")
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])

    log =
      capture_log(fn ->
        assert :ok = Ecto.Migrator.up(Repo, @version, mod, log: false, migration_lock: false)
      end)

    assert {holder, "custom_host"} =
             Repo.one(
               from(c in @claims,
                 where: c.host == ^host,
                 select: {type(c.barkpark_id, :binary_id), c.kind}
               )
             )

    assert holder == live.id

    assert log =~
             "SKIPPED pre-existing collision on #{host} — barkpark #{ghost.id} (url) left unclaimed; " <>
               "held by barkpark #{live.id} (custom_host)"

    assert log =~
             "SKIPPED pre-existing collision on #{host} — barkpark #{variant.id} (url) left unclaimed"

    junk_ids = Enum.map(junk, & &1.id)

    refute Repo.exists?(
             from(c in @claims, where: c.barkpark_id in type(^junk_ids, {:array, :binary_id}))
           )

    refute Repo.exists?(from(c in @claims, where: c.host in ["", "-", ".-"]))

    # rows untouched
    assert Repo.get!(Barkpark, ghost.id).url == "https://#{host}/"
    assert Repo.get!(Barkpark, variant.id).url == " HTTPS://#{String.upcase(host)}."
  end
end
