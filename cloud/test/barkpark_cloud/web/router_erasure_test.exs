defmodule BarkparkCloud.Web.RouterErasureTest do
  @moduledoc """
  HTTP-edge + cascade tests for the two erasure routes: `DELETE /v1/teams/:id`
  and `DELETE /v1/account`.

  The point of this file is that every assertion is a COUNT AGAINST THE DATABASE
  after the call, not a status code alone. A route that returned 200 and left the
  row flagged would pass a status-code test and fail every test below.

  Each arm also carries its CONTROL — the neighbouring case that must NOT be
  erased — because a delete that took too much is as wrong as one that took too
  little, and only the control can tell them apart.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.{AuditEvent, Erasure, Team, TeamMembership, User, UserToken}
  alias BarkparkCloud.Accounts.{TeamInvitation, UserSecurityEvent}
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Web.Router

  import Ecto.Query

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

  defp member_with_token(team, role) do
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, token}
  end

  defp call(method, path, body, token) do
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

  defp count(queryable, team_id_field \\ :team_id, id) do
    Repo.aggregate(from(r in queryable, where: field(r, ^team_id_field) == ^id), :count)
  end

  # An audit row on `team`, written the way a real route writes one.
  defp audit_fixture(team, actor) do
    {:ok, _} =
      Accounts.audit(
        %{
          team_id: team.id,
          actor_user_id: actor.id,
          action: "member.removed",
          target_type: "user",
          target_id: actor.id,
          metadata: %{}
        },
        fn -> {:ok, :noop} end
      )

    :ok
  end

  describe "DELETE /v1/teams/:id — authorization" do
    test "a plain member is 403 and the team survives" do
      team = team_fixture()
      {_owner, _} = member_with_token(team, "owner")
      {_m, member_token} = member_with_token(team, "member")

      conn = call(:delete, "/v1/teams/#{team.id}", nil, member_token)

      assert conn.status == 403
      assert Repo.get(Team, team.id)
    end

    test "an admin is 403 — erasure is owner-only, and the team survives" do
      team = team_fixture()
      {_owner, _} = member_with_token(team, "owner")
      {_a, admin_token} = member_with_token(team, "admin")

      conn = call(:delete, "/v1/teams/#{team.id}", nil, admin_token)

      assert conn.status == 403
      assert Repo.get(Team, team.id)
    end

    test "a non-member owner of ANOTHER team gets 404, not 403 — no existence leak" do
      victim = team_fixture()
      {_v_owner, _} = member_with_token(victim, "owner")

      other = team_fixture()
      {_o, other_token} = member_with_token(other, "owner")

      conn = call(:delete, "/v1/teams/#{victim.id}", nil, other_token)

      assert conn.status == 404
      assert Repo.get(Team, victim.id)
    end
  end

  describe "DELETE /v1/teams/:id — the refusal" do
    test "409 instances_present while the team still owns an instance, with counts" do
      team = team_fixture()
      {_owner, token} = member_with_token(team, "owner")
      n = System.unique_integer([:positive])
      {:ok, _bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

      conn = call(:delete, "/v1/teams/#{team.id}", nil, token)

      assert conn.status == 409
      body = json_body(conn)
      assert body["error"] == "instances_present"
      assert body["barkparks"] == 1

      # THE WHOLE POINT OF THE REFUSAL: the instance row — the only thing that
      # still names the billed server to tear down — is still there.
      assert Repo.get(Team, team.id)
      assert count(Barkpark, team.id) == 1
    end

    test "the same team erases once the instance is gone — the refusal is a state, not a wall" do
      team = team_fixture()
      {_owner, token} = member_with_token(team, "owner")
      n = System.unique_integer([:positive])
      {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

      assert call(:delete, "/v1/teams/#{team.id}", nil, token).status == 409

      {:ok, _} = Registry.delete_barkpark(bp)

      conn = call(:delete, "/v1/teams/#{team.id}", nil, token)
      assert conn.status == 200
      refute Repo.get(Team, team.id)
    end
  end

  describe "DELETE /v1/teams/:id — what is actually gone" do
    test "the team row and every dependent row are GONE, and a sibling team is untouched" do
      team = team_fixture()
      {owner, token} = member_with_token(team, "owner")
      {_member, _} = member_with_token(team, "member")

      {:ok, _inv} =
        Accounts.invite_member(
          team,
          "invited-#{System.unique_integer([:positive])}@example.com",
          "member",
          owner
        )

      :ok = audit_fixture(team, owner)

      # The CONTROL team: same shapes, never targeted.
      control = team_fixture()
      {control_owner, _} = member_with_token(control, "owner")
      :ok = audit_fixture(control, control_owner)

      assert count(TeamMembership, team.id) == 2
      assert count(TeamInvitation, team.id) == 1
      assert count(AuditEvent, team.id) == 1

      conn = call(:delete, "/v1/teams/#{team.id}", nil, token)
      assert conn.status == 200
      assert json_body(conn) == %{"ok" => true, "status" => "erased"}

      refute Repo.get(Team, team.id)
      assert count(TeamMembership, team.id) == 0
      assert count(TeamInvitation, team.id) == 0
      assert count(AuditEvent, team.id) == 0

      # CONTROL — the cascade took the target's rows and nothing else.
      assert Repo.get(Team, control.id)
      assert count(TeamMembership, control.id) == 1
      assert count(AuditEvent, control.id) == 1

      # The owner is a PERSON, not a possession of the team: erasing the team
      # does not erase them.
      assert Repo.get(User, owner.id)
    end

    test "audit_events cascades — which the append-only trigger would abort without the bypass" do
      team = team_fixture()
      {owner, token} = member_with_token(team, "owner")
      :ok = audit_fixture(team, owner)
      assert count(AuditEvent, team.id) == 1

      assert call(:delete, "/v1/teams/#{team.id}", nil, token).status == 200
      assert count(AuditEvent, team.id) == 0
    end
  end

  describe "the append-only guard is still a guard" do
    test "an ordinary DELETE on audit_events still raises — the bypass needs the GUC" do
      team = team_fixture()
      owner = user_fixture()
      {:ok, _} = Accounts.add_member(team, owner, "owner")
      :ok = audit_fixture(team, owner)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.delete_all(from(e in AuditEvent, where: e.team_id == ^team.id))
      end
    end

    test "an UPDATE still raises EVEN under the erasure flag — erasure removes, never rewrites" do
      team = team_fixture()
      owner = user_fixture()
      {:ok, _} = Accounts.add_member(team, owner, "owner")
      :ok = audit_fixture(team, owner)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL barkpark.erasure = 'on'")

          Repo.update_all(from(e in AuditEvent, where: e.team_id == ^team.id),
            set: [action: "member.added"]
          )
        end)
      end
    end
  end

  describe "DELETE /v1/account — reauthentication" do
    test "no password is 401 and the user survives" do
      team = team_fixture()
      {user, token} = member_with_token(team, "member")

      conn = call(:delete, "/v1/account", %{}, token)

      assert conn.status == 401
      assert json_body(conn)["error"] == "invalid_password"
      assert Repo.get(User, user.id)
    end

    test "a wrong password is 401 and the user survives" do
      team = team_fixture()
      {user, token} = member_with_token(team, "member")

      conn = call(:delete, "/v1/account", %{password: "not-the-password"}, token)

      assert conn.status == 401
      assert Repo.get(User, user.id)
    end

    test "no session is 401" do
      conn = call(:delete, "/v1/account", %{password: @password}, nil)
      assert conn.status == 401
    end
  end

  describe "DELETE /v1/account — the refusal" do
    test "409 sole_owner names the teams, and nothing is erased" do
      team = team_fixture()
      {user, token} = member_with_token(team, "owner")

      conn = call(:delete, "/v1/account", %{password: @password}, token)

      assert conn.status == 409
      body = json_body(conn)
      assert body["error"] == "sole_owner"
      assert body["teams"] == [team.slug]

      assert Repo.get(User, user.id)
      assert Repo.get(Team, team.id)
    end

    test "one of TWO owners is not refused — the team keeps an owner either way" do
      team = team_fixture()
      {user, token} = member_with_token(team, "owner")
      {_co_owner, _} = member_with_token(team, "owner")

      conn = call(:delete, "/v1/account", %{password: @password}, token)

      assert conn.status == 200
      refute Repo.get(User, user.id)
      assert Repo.get(Team, team.id)
      assert count(TeamMembership, team.id) == 1
    end

    test "the refusal lifts once another owner is promoted" do
      team = team_fixture()
      {user, token} = member_with_token(team, "owner")
      {other, _} = member_with_token(team, "member")

      assert call(:delete, "/v1/account", %{password: @password}, token).status == 409

      {:ok, _} = Accounts.update_member_role(team, other, "owner")

      assert call(:delete, "/v1/account", %{password: @password}, token).status == 200
      refute Repo.get(User, user.id)
    end
  end

  describe "DELETE /v1/account — what is deleted, what is anonymised" do
    test "the user row, their memberships, their sessions and their security trail are GONE" do
      team = team_fixture()
      {_owner, _} = member_with_token(team, "owner")
      {user, token} = member_with_token(team, "member")

      {:ok, _} =
        Accounts.record_user_security_event(%{
          user_id: user.id,
          action: "password_changed",
          metadata: %{}
        })

      # A CONTROL user with the same shapes, untouched by the call.
      {control, _control_token} = member_with_token(team, "member")

      {:ok, _} =
        Accounts.record_user_security_event(%{
          user_id: control.id,
          action: "password_changed",
          metadata: %{}
        })

      assert count(UserToken, :user_id, user.id) >= 1
      assert count(UserSecurityEvent, :user_id, user.id) == 1

      conn = call(:delete, "/v1/account", %{password: @password}, token)
      assert conn.status == 200
      assert json_body(conn) == %{"ok" => true, "status" => "erased"}

      refute Repo.get(User, user.id)
      assert count(TeamMembership, :user_id, user.id) == 0
      assert count(UserToken, :user_id, user.id) == 0
      assert count(UserSecurityEvent, :user_id, user.id) == 0

      # CONTROL — same shapes, still there.
      assert Repo.get(User, control.id)
      assert count(UserSecurityEvent, :user_id, control.id) == 1
      assert count(TeamMembership, :user_id, control.id) == 1

      # The team is NOT erased by a member leaving.
      assert Repo.get(Team, team.id)
    end

    test "the team's audit trail SURVIVES with the actor nulled — anonymised, not deleted" do
      team = team_fixture()
      {_owner, _} = member_with_token(team, "owner")
      {user, token} = member_with_token(team, "member")

      :ok = audit_fixture(team, user)
      assert count(AuditEvent, team.id) == 1
      assert Erasure.orphaned_audit_actor_count(team) == 0

      assert call(:delete, "/v1/account", %{password: @password}, token).status == 200

      # The ROW is still the team's record of what happened to the team…
      assert count(AuditEvent, team.id) == 1
      # …and the person is no longer in it.
      assert Erasure.orphaned_audit_actor_count(team) == 1
    end

    test "the session token stops working immediately after erasure" do
      team = team_fixture()
      {_owner, _} = member_with_token(team, "owner")
      {_user, token} = member_with_token(team, "member")

      assert call(:delete, "/v1/account", %{password: @password}, token).status == 200
      assert call(:get, "/v1/me", nil, token).status == 401
    end
  end

  describe "Erasure read helpers — the console's pre-check" do
    test "team_erasure_blockers counts instances and reads zero on a clean team" do
      team = team_fixture()
      assert Erasure.team_erasure_blockers(team) == %{barkparks: 0, sites: 0}

      n = System.unique_integer([:positive])
      {:ok, _bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

      assert %{barkparks: 1, sites: 0} = Erasure.team_erasure_blockers(team)
    end

    test "sole_owner_team_slugs is empty for a member and names the team for a sole owner" do
      team = team_fixture()
      {owner, _} = member_with_token(team, "owner")
      {member, _} = member_with_token(team, "member")

      assert Erasure.sole_owner_team_slugs(member) == []
      assert Erasure.sole_owner_team_slugs(owner) == [team.slug]
    end
  end
end
