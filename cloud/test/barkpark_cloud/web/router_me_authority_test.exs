defmodule BarkparkCloud.Web.RouterMeAuthorityTest do
  @moduledoc """
  `/v1/me`'s `team_authority` — the ACCEPT side of authority on the wire.

  The endpoint has shipped `role` since the team switcher landed, but across
  the whole cloud suite exactly ONE assertion ever pinned it, and it pinned
  `"member"` — so `role: team && "member"` (every owner reported as a member)
  was a GREEN mutation. `team_authority` must not inherit that hole: these
  tests pin the FULL map for an owner, an admin, a member and a teamless
  caller, and pin that the map is scoped to the team `x-barkpark-team`
  actually resolved.

  What is deliberately NOT asserted: any capability claim. `team_authority`
  states MEMBERSHIP (role/admin/owner) only — `platform_operator` is a
  different axis and a PAT's token abilities are a third.
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
      Accounts.register_user(%{
        email: "authority-#{n}@example.com",
        password: "s3cret-pass-#{n}!"
      })

    user
  end

  defp team_fixture(name) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: name, slug: "#{String.downcase(name)}-#{n}"})
    team
  end

  defp me(token, team_header) do
    conn(:get, "/v1/me")
    |> put_req_header("authorization", "Bearer " <> token)
    |> then(fn c ->
      if team_header, do: put_req_header(c, "x-barkpark-team", team_header), else: c
    end)
    |> Router.call(@opts)
  end

  defp me_body(token, team_header \\ nil) do
    conn = me(token, team_header)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  # One member of `role` in a fresh team; returns {user, team, session token}.
  defp caller_with_role(role) do
    user = user_fixture()
    team = team_fixture("Auth#{String.capitalize(role)}")
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  test "an OWNER is told owner: true and admin: true, scoped to their team" do
    {_user, team, token} = caller_with_role("owner")

    assert %{
             "team_id" => team_id,
             "role" => "owner",
             "admin" => true,
             "owner" => true
           } = me_body(token)["team_authority"]

    assert team_id == team.id
  end

  test "an ADMIN is told admin: true and owner: false" do
    {_user, team, token} = caller_with_role("admin")

    assert %{
             "team_id" => team_id,
             "role" => "admin",
             "admin" => true,
             "owner" => false
           } = me_body(token)["team_authority"]

    assert team_id == team.id
  end

  test "a MEMBER is told admin: false and owner: false" do
    {_user, team, token} = caller_with_role("member")

    assert %{
             "team_id" => team_id,
             "role" => "member",
             "admin" => false,
             "owner" => false
           } = me_body(token)["team_authority"]

    assert team_id == team.id
  end

  test "a TEAMLESS caller gets team_authority: nil — a consumer fails CLOSED" do
    user = user_fixture()
    {:ok, token} = Accounts.create_user_session_token(user)

    body = me_body(token)

    assert Map.has_key?(body, "team_authority"), "the key must be present, not omitted"
    assert body["team_authority"] == nil
    assert body["team"] == nil
  end

  test "team_authority follows the team x-barkpark-team resolved, not the primary one" do
    user = user_fixture()
    first = team_fixture("AuthFirst")
    second = team_fixture("AuthSecond")
    {:ok, _} = Accounts.add_member(first, user, "owner")
    {:ok, _} = Accounts.add_member(second, user, "member")
    {:ok, token} = Accounts.create_user_session_token(user)

    # No header → the primary (oldest) membership, where the caller OWNS.
    primary = me_body(token)["team_authority"]
    assert primary["team_id"] == first.id
    assert primary["role"] == "owner"
    assert primary["admin"] == true
    assert primary["owner"] == true

    # Pinned to the joined team → the id AND the authority move together. A
    # role from one team beside an id from another is the bug this pins shut.
    pinned = me_body(token, second.id)["team_authority"]
    assert pinned["team_id"] == second.id
    assert pinned["role"] == "member"
    assert pinned["admin"] == false
    assert pinned["owner"] == false
  end

  test "team_authority.team_id always equals the team: block's id" do
    {_user, _team, token} = caller_with_role("admin")

    body = me_body(token)
    assert body["team_authority"]["team_id"] == body["team"]["id"]
    assert body["team_authority"]["role"] == body["role"]
  end
end
