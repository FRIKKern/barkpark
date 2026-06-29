defmodule BarkparkCloud.Web.RouterInvitationsTest do
  @moduledoc """
  HTTP-edge tests for teams-invitations: the member/invitation routes, the
  unauthenticated accept-preview, the copy-paste accept path, and the RBAC gate
  regression on billing/go-live (a plain member is now 403, an admin keeps the
  old behaviour). Mirrors router_test.exs' Plug.Test setup.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  # A team with `user` at `role`, plus a freshly minted session token. Returns
  # {user, team, token}.
  defp member_with_token(team, role, attrs \\ %{}) do
    user = user_fixture(attrs)
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, token}
  end

  defp call(method, path, body \\ nil, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  describe "GET /v1/teams/:id/members" do
    test "a member sees the roster; a non-member gets 404 (no existence leak)" do
      team = team_fixture()
      {_owner, owner_token} = member_with_token(team, "owner")
      {_stranger, stranger_token} = {nil, elem(member_with_token(team_fixture(), "owner"), 1)}

      conn = call(:get, "/v1/teams/#{team.id}/members", nil, owner_token)
      assert conn.status == 200
      assert [%{"role" => "owner"}] = json_body(conn)["members"]

      # a valid user who is NOT a member of THIS team → 404, not 403.
      conn = call(:get, "/v1/teams/#{team.id}/members", nil, stranger_token)
      assert conn.status == 404
    end

    test "no token → 401" do
      team = team_fixture()
      conn = call(:get, "/v1/teams/#{team.id}/members")
      assert conn.status == 401
    end
  end

  describe "POST /v1/teams/:id/invitations" do
    test "an admin invites → 201 with an accept_url; a member → 403" do
      team = team_fixture()
      {_owner, owner_token} = member_with_token(team, "owner")
      {_member, member_token} = member_with_token(team, "member")

      conn =
        call(:post, "/v1/teams/#{team.id}/invitations", %{email: "new@example.com"}, owner_token)

      assert conn.status == 201
      body = json_body(conn)
      assert body["invitation"]["email"] == "new@example.com"
      assert is_binary(body["accept_url"])
      assert body["accept_url"] =~ "token="

      conn =
        call(:post, "/v1/teams/#{team.id}/invitations", %{email: "x@example.com"}, member_token)

      assert conn.status == 403
    end

    test "inviting an existing member → 409 already_member" do
      team = team_fixture()
      {_owner, owner_token} = member_with_token(team, "owner")
      existing = user_fixture(email: "dup@example.com")
      {:ok, _} = Accounts.add_member(team, existing, "member")

      conn =
        call(:post, "/v1/teams/#{team.id}/invitations", %{email: "dup@example.com"}, owner_token)

      assert conn.status == 409
      assert json_body(conn)["error"] == "already_member"
    end

    test "an admin inviting an owner → 422 role_too_high" do
      team = team_fixture()
      {_owner, _} = member_with_token(team, "owner")
      {_admin, admin_token} = member_with_token(team, "admin")

      conn =
        call(
          :post,
          "/v1/teams/#{team.id}/invitations",
          %{email: "boss@example.com", role: "owner"},
          admin_token
        )

      assert conn.status == 422
      assert json_body(conn)["error"] == "role_too_high"
    end
  end

  describe "accept flow" do
    test "GET /v1/invitations/:token previews unauthenticated; garbage → 404" do
      team = team_fixture(name: "Acme", slug: "acme")
      {_owner, owner_token} = member_with_token(team, "owner")

      conn =
        call(:post, "/v1/teams/#{team.id}/invitations", %{email: "join@example.com"}, owner_token)

      token = accept_token(json_body(conn)["accept_url"])

      conn = call(:get, "/v1/invitations/#{token}")
      assert conn.status == 200
      body = json_body(conn)
      assert body["team"]["name"] == "Acme"
      assert body["email"] == "join@example.com"

      assert call(:get, "/v1/invitations/garbage").status == 404
    end

    test "POST /v1/invitations/accept attaches membership; reuse → 404; wrong user → 403" do
      team = team_fixture()
      {_owner, owner_token} = member_with_token(team, "owner")

      conn =
        call(
          :post,
          "/v1/teams/#{team.id}/invitations",
          %{email: "invitee@example.com"},
          owner_token
        )

      token = accept_token(json_body(conn)["accept_url"])

      invitee = user_fixture(email: "invitee@example.com")
      {:ok, invitee_token} = Accounts.create_user_session_token(invitee)

      conn = call(:post, "/v1/invitations/accept", %{token: token}, invitee_token)
      assert conn.status == 200
      assert json_body(conn)["team_id"] == team.id
      assert Accounts.team_role(invitee, team) == "member"

      # reuse of the now-accepted token → 404.
      assert call(:post, "/v1/invitations/accept", %{token: token}, invitee_token).status == 404

      # a different invite accepted by the wrong logged-in user → 403.
      conn =
        call(
          :post,
          "/v1/teams/#{team.id}/invitations",
          %{email: "other@example.com"},
          owner_token
        )

      token2 = accept_token(json_body(conn)["accept_url"])
      wrong = user_fixture(email: "not-other@example.com")
      {:ok, wrong_token} = Accounts.create_user_session_token(wrong)
      assert call(:post, "/v1/invitations/accept", %{token: token2}, wrong_token).status == 403
    end
  end

  describe "member management" do
    test "DELETE a member as admin → 200 and the removed user's token now 401s" do
      team = team_fixture()
      {_owner, owner_token} = member_with_token(team, "owner")
      victim = user_fixture()
      {:ok, _} = Accounts.add_member(team, victim, "member")
      {:ok, victim_token} = Accounts.create_user_session_token(victim)

      conn = call(:delete, "/v1/teams/#{team.id}/members/#{victim.id}", nil, owner_token)
      assert conn.status == 200

      # the removed user is logged out — /v1/me 401s.
      assert call(:get, "/v1/me", nil, victim_token).status == 401
    end

    test "PATCH the sole owner's role → 409 last_owner" do
      team = team_fixture()
      {owner, owner_token} = member_with_token(team, "owner")

      conn =
        call(:patch, "/v1/teams/#{team.id}/members/#{owner.id}", %{role: "member"}, owner_token)

      assert conn.status == 409
      assert json_body(conn)["error"] == "last_owner"
    end
  end

  describe "B1 — member CRUD anti-escalation guard" do
    test "an admin cannot self-promote to owner → 403" do
      team = team_fixture()
      {_owner, _} = member_with_token(team, "owner")
      {admin, admin_token} = member_with_token(team, "admin")

      conn =
        call(:patch, "/v1/teams/#{team.id}/members/#{admin.id}", %{role: "owner"}, admin_token)

      assert conn.status == 403
      assert json_body(conn)["error"] == "forbidden"
    end

    test "an admin cannot promote a member to owner → 403" do
      team = team_fixture()
      {_owner, _} = member_with_token(team, "owner")
      {_admin, admin_token} = member_with_token(team, "admin")
      {member, _} = member_with_token(team, "member")

      conn =
        call(:patch, "/v1/teams/#{team.id}/members/#{member.id}", %{role: "owner"}, admin_token)

      assert conn.status == 403
    end

    test "an admin cannot demote an owner → 403" do
      team = team_fixture()
      {owner, _} = member_with_token(team, "owner")
      {_admin, admin_token} = member_with_token(team, "admin")

      conn =
        call(:patch, "/v1/teams/#{team.id}/members/#{owner.id}", %{role: "member"}, admin_token)

      assert conn.status == 403
    end

    test "an admin cannot evict an owner → 403" do
      team = team_fixture()
      {owner, _} = member_with_token(team, "owner")
      {_admin, admin_token} = member_with_token(team, "admin")

      conn = call(:delete, "/v1/teams/#{team.id}/members/#{owner.id}", nil, admin_token)
      assert conn.status == 403
    end

    test "an owner may promote a member to admin → 200" do
      team = team_fixture()
      {_owner, owner_token} = member_with_token(team, "owner")
      {member, _} = member_with_token(team, "member")

      conn =
        call(:patch, "/v1/teams/#{team.id}/members/#{member.id}", %{role: "admin"}, owner_token)

      assert conn.status == 200
      assert json_body(conn)["member"]["role"] == "admin"
    end
  end

  describe "RBAC gate regression on privileged routes" do
    test "POST /v1/billing/checkout as a member → 403; as admin reaches billing" do
      team = team_fixture()
      {_owner, _} = member_with_token(team, "owner")
      {_member, member_token} = member_with_token(team, "member")

      assert call(:post, "/v1/billing/checkout", %{plan: "pro"}, member_token).status == 403
    end

    test "POST /v1/go-live as a member → 403 (gate fires before the subscription check)" do
      team = team_fixture()
      {_owner, _} = member_with_token(team, "owner")
      {_member, member_token} = member_with_token(team, "member")

      assert call(:post, "/v1/go-live", %{name: "box"}, member_token).status == 403
    end
  end

  # Pull the `token=` query value out of an accept_url.
  defp accept_token(accept_url) do
    accept_url
    |> String.split("token=")
    |> List.last()
  end
end
