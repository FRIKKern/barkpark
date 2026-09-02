defmodule BarkparkCloud.Web.AuthRequireTeamRoleMinRoleTest do
  @moduledoc """
  `Auth.require_team_role/3` decides with ONE expression —
  `TeamMembership.rank(held) < TeamMembership.rank(min_role)` — and
  `rank/1` answers 0 for a role it does not know. That default is CORRECT on the
  HELD side and WRONG on the REQUIRED side, and until this test existed only the
  held side was pinned:

    * HELD unranked     → `0 < rank(min_role)` is TRUE  → refused. Fail-CLOSED.
    * REQUIRED unranked → `rank(held) < 0` is FALSE for every real member
      (ranks are 1..3) → the `cond` fell through its `true ->` arm and ADMITTED.
      Fail-OPEN: an intended-admin gate collapsed to "any member of this team",
      silently, with a 200.

  No caller does this today — all six router call sites pass a string literal in
  `@ranks` — so nothing could go red about it, which is exactly why it is pinned
  here rather than left to every future caller spelling a role correctly.

  Three arms:

    * RED-FIRST — an unranked `min_role` ("admins") must refuse a plain member.
    * BOTH DIRECTIONS — unranked HELD refused AND unranked REQUIRED refused, so
      the two sides of the same comparison can never drift apart again.
    * NEGATIVE — the six current callers, exercised for owner/admin/member/
      non-member, must answer exactly what they answer today. The fix narrows a
      value no live route passes; it must move nothing that they do.
  """
  use BarkparkCloud.DataCase, async: true

  # The unranked-min_role clause logs at :error on purpose (reaching it is a
  # call-site bug). Captured so a green run stays quiet and a red one still
  # prints the log it emitted.
  @moduletag :capture_log

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.TeamMembership
  alias BarkparkCloud.Web.Auth
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # The value under test: a plural of a real role — the shape a typo, a rename,
  # or a config-threaded string actually takes. Guarded so this file cannot go
  # vacuous by someone adding "admins" to the ladder.
  @unranked_min_role "admins"

  # ── fixtures (mirrors router_invitations_test.exs; no new pattern invented) ──

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # A user at `role` in `team`, plus a session token. Returns {user, token}.
  defp member_with_token(team, role) do
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, token}
  end

  defp plain_member(team) do
    {user, _token} = member_with_token(team, "member")
    user
  end

  # Force a membership OFF the ladder. The changeset validates inclusion, so the
  # write goes around it — the same technique accounts_invitations_test.exs uses.
  defp off_ladder!(team, user, role) do
    refute role in TeamMembership.roles(),
           "off_ladder!/3 was handed #{inspect(role)}, which the changeset ACCEPTS — " <>
             "the caller would no longer be measuring the off-ladder branch"

    {1, _} =
      Repo.update_all(
        from(m in TeamMembership, where: m.team_id == ^team.id and m.user_id == ^user.id),
        set: [role: role]
      )

    # Non-vacuity: if a CHECK constraint ever guards the column the write stops
    # landing and every off-ladder assertion here would pass for the wrong
    # reason. Asserted through match?/2 so the message stays live.
    assert match?(^role, Accounts.team_role(user, team)),
           "off_ladder!/3 did not land #{inspect(role)} — the column now refuses it, " <>
             "so the off-ladder branch is UNREACHABLE from this fixture"
  end

  defp invitation_fixture(team, inviter, email) do
    {:ok, %{invitation: inv}} = Accounts.invite_member(team, email, "member", inviter)
    inv
  end

  # ── the gate, called DIRECTLY: no route in front, no literal in the way ──

  defp gate(token, team_id, min_role) do
    conn(:get, "/probe")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Auth.require_team_role(team_id, min_role)
  end

  defp verdict(conn) do
    %{
      status: conn.status,
      halted: conn.halted,
      granted_role: conn.assigns[:current_team_role],
      granted_team: conn.assigns[:current_team_scoped] && conn.assigns.current_team_scoped.id
    }
  end

  defp refused?(conn), do: conn.halted and conn.status in [401, 403, 404]

  # ── the six live callers, through the real router ──

  defp call(method, path, body, token) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          method
          |> conn(path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  # Every route that reaches `Auth.require_team_role/3` via the router's private
  # `with_team_role/3`, with the min_role literal it passes. Cited by ROUTE, not
  # by router.ex line — the GATE is what is pinned, and line numbers rot:
  #
  #   "member"  GET    /v1/teams/:id/members
  #   "admin"   POST   /v1/teams/:id/invitations
  #   "admin"   GET    /v1/teams/:id/invitations
  #   "admin"   DELETE /v1/teams/:id/invitations/:inv_id
  #   "admin"   PATCH  /v1/teams/:id/members/:user_id
  #   "admin"   DELETE /v1/teams/:id/members/:user_id
  @routes [
    :members_list,
    :invite,
    :invitations_list,
    :invitation_revoke,
    :member_patch,
    :member_delete
  ]

  defp run_route(:members_list, ctx, token),
    do: call(:get, "/v1/teams/#{ctx.team.id}/members", nil, token)

  defp run_route(:invite, ctx, token) do
    email = "invitee-#{System.unique_integer([:positive])}@example.com"
    call(:post, "/v1/teams/#{ctx.team.id}/invitations", %{email: email}, token)
  end

  defp run_route(:invitations_list, ctx, token),
    do: call(:get, "/v1/teams/#{ctx.team.id}/invitations", nil, token)

  defp run_route(:invitation_revoke, ctx, token) do
    n = System.unique_integer([:positive])
    inv = invitation_fixture(ctx.team, ctx.owner, "revoke-#{n}@example.com")
    call(:delete, "/v1/teams/#{ctx.team.id}/invitations/#{inv.id}", nil, token)
  end

  defp run_route(:member_patch, ctx, token) do
    target = plain_member(ctx.team)
    call(:patch, "/v1/teams/#{ctx.team.id}/members/#{target.id}", %{role: "member"}, token)
  end

  defp run_route(:member_delete, ctx, token) do
    target = plain_member(ctx.team)
    call(:delete, "/v1/teams/#{ctx.team.id}/members/#{target.id}", nil, token)
  end

  setup do
    team = team_fixture()
    {owner, owner_token} = member_with_token(team, "owner")
    {_admin, admin_token} = member_with_token(team, "admin")
    {member, member_token} = member_with_token(team, "member")

    # A real, authenticated user who is simply not in THIS team.
    {_stranger, stranger_token} = member_with_token(team_fixture(), "owner")

    %{
      team: team,
      owner: owner,
      owner_token: owner_token,
      admin_token: admin_token,
      member: member,
      member_token: member_token,
      stranger_token: stranger_token
    }
  end

  describe "an unranked min_role (the REQUIRED side)" do
    test "refuses a plain member instead of collapsing the gate to any-member", ctx do
      refute @unranked_min_role in TeamMembership.ranked_roles(),
             "#{inspect(@unranked_min_role)} is now a ranked role — this test is measuring nothing"

      conn = gate(ctx.member_token, ctx.team.id, @unranked_min_role)

      assert refused?(conn),
             "an unranked min_role #{inspect(@unranked_min_role)} ADMITTED #{ctx.member.email}, " <>
               "who holds #{inspect(Accounts.team_role(ctx.member, ctx.team))} in this team — " <>
               "the intended-admin gate collapsed to any-member. verdict: " <>
               inspect(verdict(conn))

      # And it granted nothing on the way past: no team scope, no role assign.
      assert verdict(conn).granted_role == nil
      assert verdict(conn).granted_team == nil
    end

    test "refuses the OWNER too — a threshold nobody can name is one nobody satisfies", ctx do
      conn = gate(ctx.owner_token, ctx.team.id, @unranked_min_role)

      assert refused?(conn),
             "an unranked min_role must refuse every caller, but the owner passed. verdict: " <>
               inspect(verdict(conn))
    end
  end

  describe "both directions of rank/1's 0 default" do
    test "an unranked HELD role is refused AND an unranked REQUIRED role is refused", ctx do
      # ── direction 1: the HELD role is off the ladder (already fail-closed —
      # rank(held) = 0 < rank("admin") = 2). Pinned so it cannot be "fixed" into
      # symmetry the wrong way, by making rank/1 permissive.
      stray = plain_member(ctx.team)
      off_ladder!(ctx.team, stray, "superadmin")
      {:ok, stray_token} = Accounts.create_user_session_token(stray)

      held_conn = gate(stray_token, ctx.team.id, "admin")

      assert refused?(held_conn),
             "unranked HELD role \"superadmin\" was ADMITTED against min_role \"admin\". " <>
               "verdict: #{inspect(verdict(held_conn))}"

      # ── direction 2: the REQUIRED role is off the ladder. Same 0, opposite
      # side of the `<`, and this is the one that used to widen.
      required_conn = gate(ctx.member_token, ctx.team.id, @unranked_min_role)

      assert refused?(required_conn),
             "unranked REQUIRED role #{inspect(@unranked_min_role)} ADMITTED a " <>
               "\"member\" — the two directions have drifted apart again. " <>
               "verdict: #{inspect(verdict(required_conn))}"

      # ── and both at once: neither side rescues the other.
      both_conn = gate(stray_token, ctx.team.id, @unranked_min_role)

      assert refused?(both_conn),
             "unranked HELD and unranked REQUIRED together were ADMITTED. " <>
               "verdict: #{inspect(verdict(both_conn))}"
    end

    test "a nil min_role is refused, not treated as rank 0 and waved through", ctx do
      conn = gate(ctx.member_token, ctx.team.id, nil)

      assert refused?(conn),
             "a nil min_role ADMITTED a \"member\". verdict: #{inspect(verdict(conn))}"
    end
  end

  describe "the six current callers are unmoved" do
    test "owner / admin / member / non-member answer exactly what they answer today", ctx do
      observed =
        Map.new(@routes, fn route ->
          {route,
           %{
             owner: run_route(route, ctx, ctx.owner_token).status,
             admin: run_route(route, ctx, ctx.admin_token).status,
             member: run_route(route, ctx, ctx.member_token).status,
             non_member: run_route(route, ctx, ctx.stranger_token).status
           }}
        end)

      expected = %{
        # min_role "member" — every member of the team reads the roster.
        members_list: %{owner: 200, admin: 200, member: 200, non_member: 404},
        # min_role "admin" — a plain member is 403, a non-member 404 (no leak).
        invite: %{owner: 201, admin: 201, member: 403, non_member: 404},
        invitations_list: %{owner: 200, admin: 200, member: 403, non_member: 404},
        invitation_revoke: %{owner: 200, admin: 200, member: 403, non_member: 404},
        member_patch: %{owner: 200, admin: 200, member: 403, non_member: 404},
        member_delete: %{owner: 200, admin: 200, member: 403, non_member: 404}
      }

      assert observed == expected,
             "a live caller moved:\n  observed: #{inspect(observed, pretty: true)}\n" <>
               "  expected: #{inspect(expected, pretty: true)}"
    end
  end
end
