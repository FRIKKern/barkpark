defmodule BarkparkCloud.RegistryAzureCredentialsTest do
  @moduledoc """
  W2/S6 — `Registry.resolved_azure_credentials_for_barkpark/1`: the claim-time
  decryption of a team's Azure service-principal (charter Decision 4/9). Mirrors
  `resolved_env_for_barkpark/1` — newest connected provider wins, fail-closed to
  nil when nothing is connected or the ciphertext won't decode.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}

  @azure_creds %{
    "tenant_id" => "t-1",
    "client_id" => "c-1",
    "client_secret" => "s-1",
    "subscription_id" => "sub-1"
  }

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team, attrs) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Map.merge(%{name: "BP #{n}", slug: "bp-#{n}"}, attrs))

    bp
  end

  test "decrypts the connected azure 4-tuple for an azure barkpark" do
    team = team_fixture()

    {:ok, _} =
      Registry.connect_provider(team, "azure", Jason.encode!(@azure_creds), label: "prod")

    bp = barkpark_fixture(team, %{provider: "azure"})

    assert Registry.resolved_azure_credentials_for_barkpark(bp) == @azure_creds
  end

  test "newest connected azure provider wins (rotation)" do
    team = team_fixture()

    {:ok, _old} =
      Registry.connect_provider(team, "azure", Jason.encode!(@azure_creds), label: "old")

    rotated = %{@azure_creds | "client_secret" => "rotated"}
    {:ok, _new} = Registry.connect_provider(team, "azure", Jason.encode!(rotated), label: "new")

    bp = barkpark_fixture(team, %{provider: "azure"})
    assert Registry.resolved_azure_credentials_for_barkpark(bp) == rotated
  end

  test "nil when the team has no connected azure provider (fail-closed)" do
    team = team_fixture()
    bp = barkpark_fixture(team, %{provider: "azure"})
    assert Registry.resolved_azure_credentials_for_barkpark(bp) == nil
  end

  test "a hetzner provider row does NOT satisfy an azure lookup" do
    team = team_fixture()
    {:ok, _} = Registry.connect_provider(team, "hetzner", "hz-token", label: "hz")
    bp = barkpark_fixture(team, %{provider: "azure"})
    assert Registry.resolved_azure_credentials_for_barkpark(bp) == nil
  end
end
