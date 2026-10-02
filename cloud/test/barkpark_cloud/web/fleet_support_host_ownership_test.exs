defmodule BarkparkCloud.Web.FleetSupportHostOwnershipTest do
  @moduledoc """
  Cloud authz sweep (r4a): a team could register ANOTHER TEAM's box as its own
  support machine.

  `POST /v1/fleet/supports` (register mode) took `host` from the body with a
  format check only. The platform worker later SSHes to `barkpark.host` as root
  for the support's agent-key, attach-domain and auto-update jobs. So an admin
  of team A naming team B's box IP as a support's host made the platform rewrite
  B's fleet-listener credentials, add a Caddy vhost / CORS origin, or flip
  self-update on B's box. A host already registered to another team is now
  refused at registration.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @victim_ip "203.0.113.77"

  defp team_admin do
    {:ok, user} =
      Accounts.register_user(%{
        email: "fs-host-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "admin")
    {:ok, token} = Accounts.create_user_session_token(user)
    {team, token}
  end

  defp main_fixture(team, host \\ nil) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "Main #{n}", slug: "main-#{n}"})
    {:ok, main} = bp |> Barkpark.fleet_changeset(%{fleet_role: "main"}) |> Repo.update()
    if host, do: main |> Ecto.Changeset.change(host: host) |> Repo.update!(), else: main
  end

  defp post_support(token, body) do
    conn(:post, "/v1/fleet/supports", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  test "a team cannot register another team's box as its support host" do
    {victim_team, _} = team_admin()
    _victim_main = main_fixture(victim_team, @victim_ip)

    {team, token} = team_admin()
    own_main = main_fixture(team)

    conn = post_support(token, %{name: "stolen", parent_id: own_main.id, host: @victim_ip})

    assert conn.status == 422, "registered another team's box as a support (#{conn.status})"
    refute Repo.get_by(Barkpark, team_id: team.id, host: @victim_ip)
  end

  test "a team may register a support on a host no other team holds (control)" do
    {team, token} = team_admin()
    own_main = main_fixture(team)

    conn = post_support(token, %{name: "mine", parent_id: own_main.id, host: "198.51.100.10"})

    assert conn.status in [200, 201]
    assert Repo.get_by(Barkpark, team_id: team.id, host: "198.51.100.10")
  end
end
