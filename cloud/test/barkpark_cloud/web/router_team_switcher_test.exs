defmodule BarkparkCloud.Web.RouterTeamSwitcherTest do
  @moduledoc """
  The team switcher's server half: `x-barkpark-team` pins `current_team` to
  any team the caller is a MEMBER of; everything else (absent header,
  malformed id, foreign team) falls back to the primary (oldest) membership —
  degrade, never brick. `/v1/me` lists EVERY membership so the SPA can render
  the switcher (an invite-accepted second team was otherwise unreachable).
  """
  use BarkparkCloud.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  defp user_fixture do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "switch-#{n}@example.com", password: "s3cret-pass-#{n}!"})

    user
  end

  defp team_fixture(name) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: name, slug: "#{String.downcase(name)}-#{n}"})
    team
  end

  defp me(token, team_header \\ nil) do
    conn(:get, "/v1/me")
    |> put_req_header("authorization", "Bearer " <> token)
    |> then(fn c ->
      if team_header, do: put_req_header(c, "x-barkpark-team", team_header), else: c
    end)
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  test "second-team member can pin the joined team; /v1/me lists both memberships" do
    user = user_fixture()
    first = team_fixture("First")
    second = team_fixture("Second")
    {:ok, _} = Accounts.add_member(first, user, "owner")
    {:ok, _} = Accounts.add_member(second, user, "member")
    {:ok, token} = Accounts.create_user_session_token(user)

    # No header → primary (oldest) team.
    body = json_body(me(token))
    assert body["team"]["id"] == first.id
    assert Enum.map(body["teams"], & &1["id"]) |> Enum.sort() == Enum.sort([first.id, second.id])
    assert %{"role" => "member"} = Enum.find(body["teams"], &(&1["id"] == second.id))

    # Pinned → the joined team, with the role scoped to IT.
    body = json_body(me(token, second.id))
    assert body["team"]["id"] == second.id
    assert body["role"] == "member"
  end

  test "a foreign or malformed team header degrades to the primary team" do
    user = user_fixture()
    mine = team_fixture("Mine")
    foreign = team_fixture("Foreign")
    {:ok, _} = Accounts.add_member(mine, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)

    for header <- [foreign.id, "not-a-uuid", ""] do
      body = json_body(me(token, header))
      assert body["team"]["id"] == mine.id, "header #{inspect(header)} must fall back"
    end
  end
end
