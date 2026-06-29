defmodule BarkparkCloud.Accounts.AuthzTest do
  @moduledoc """
  Unit tests for the RBAC reader (rbac-roles). Exercises the role lookup, the
  admin/owner predicates, the TOTAL `authorize/3` action table, and the ranked
  anti-escalation guard `can_grant?/3`, plus the context-level
  `Accounts.add_member_as/4` that wraps it.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.Authz

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # A team plus a user holding `role` in it.
  defp member(role) do
    team = team_fixture()
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {user, team}
  end

  ## role/2

  describe "role/2" do
    test "returns the grant string for owner/admin/member" do
      for r <- ~w(owner admin member) do
        {user, team} = member(r)
        assert Authz.role(user, team) == r
      end
    end

    test "non-member → nil" do
      team = team_fixture()
      stranger = user_fixture()
      assert Authz.role(stranger, team) == nil
    end

    test "accepts raw binary ids as well as structs" do
      {user, team} = member("admin")
      assert Authz.role(user.id, team.id) == "admin"
    end
  end

  ## team_admin?/2 + team_owner?/2

  describe "team_admin?/2" do
    test "true for owner and admin, false for member and non-member" do
      {owner, t1} = member("owner")
      {admin, t2} = member("admin")
      {plain, t3} = member("member")
      stranger = user_fixture()

      assert Authz.team_admin?(owner, t1)
      assert Authz.team_admin?(admin, t2)
      refute Authz.team_admin?(plain, t3)
      refute Authz.team_admin?(stranger, t1)
    end
  end

  describe "team_owner?/2" do
    test "true only for owner" do
      {owner, t1} = member("owner")
      {admin, t2} = member("admin")
      {plain, t3} = member("member")

      assert Authz.team_owner?(owner, t1)
      refute Authz.team_owner?(admin, t2)
      refute Authz.team_owner?(plain, t3)
    end
  end

  ## authorize/3 — the policy table, total

  describe "authorize/3" do
    test "matrix over {owner,admin,member} × {read,launch,billing,delete_team}" do
      {owner, t_owner} = member("owner")
      {admin, t_admin} = member("admin")
      {plain, t_member} = member("member")

      # read — every member is allowed.
      assert Authz.authorize(owner, t_owner, :read) == :ok
      assert Authz.authorize(admin, t_admin, :read) == :ok
      assert Authz.authorize(plain, t_member, :read) == :ok

      # launch — admin gate.
      assert Authz.authorize(owner, t_owner, :launch) == :ok
      assert Authz.authorize(admin, t_admin, :launch) == :ok
      assert Authz.authorize(plain, t_member, :launch) == {:error, :forbidden}

      # billing — owner only.
      assert Authz.authorize(owner, t_owner, :billing) == :ok
      assert Authz.authorize(admin, t_admin, :billing) == {:error, :forbidden}
      assert Authz.authorize(plain, t_member, :billing) == {:error, :forbidden}

      # delete_team — owner only.
      assert Authz.authorize(owner, t_owner, :delete_team) == :ok
      assert Authz.authorize(admin, t_admin, :delete_team) == {:error, :forbidden}
    end

    test "non-member → forbidden for every action" do
      team = team_fixture()
      stranger = user_fixture()

      for action <- [:read, :launch, :connect_provider, :billing, :delete_team] do
        assert Authz.authorize(stranger, team, action) == {:error, :forbidden}
      end
    end

    test "unknown action → forbidden (total, never raises)" do
      {owner, team} = member("owner")
      assert Authz.authorize(owner, team, :launch_nukes) == {:error, :forbidden}
    end
  end

  ## rank/1

  describe "rank/1" do
    test "member < admin < owner, unknown → 0" do
      assert Authz.rank("member") == 1
      assert Authz.rank("admin") == 2
      assert Authz.rank("owner") == 3
      assert Authz.rank("superuser") == 0
      assert Authz.rank(nil) == 0
    end
  end

  ## can_grant?/3 — anti-escalation

  describe "can_grant?/3" do
    test "admin may grant member but NOT admin or owner (no escalation past own rank)" do
      {admin, team} = member("admin")
      assert Authz.can_grant?(admin, team, "member") == :ok
      # admin granting admin would be at-rank — Coolify forbids promoting to >= self.
      assert Authz.can_grant?(admin, team, "admin") == :ok
      assert Authz.can_grant?(admin, team, "owner") == {:error, :forbidden}
    end

    test "owner may grant admin and member" do
      {owner, team} = member("owner")
      assert Authz.can_grant?(owner, team, "admin") == :ok
      assert Authz.can_grant?(owner, team, "member") == :ok
    end

    test "a plain member may grant nothing" do
      {plain, team} = member("member")
      assert Authz.can_grant?(plain, team, "member") == {:error, :forbidden}
    end

    test "a non-member may grant nothing" do
      team = team_fixture()
      stranger = user_fixture()
      assert Authz.can_grant?(stranger, team, "member") == {:error, :forbidden}
    end
  end

  ## Accounts.add_member_as/4 — context guard

  describe "Accounts.add_member_as/4" do
    test "admin actor adds a member → {:ok, membership}" do
      {admin, team} = member("admin")
      newcomer = user_fixture()

      assert {:ok, m} = Accounts.add_member_as(admin, team, newcomer, "member")
      assert m.role == "member"
      assert Authz.role(newcomer, team) == "member"
    end

    test "member actor is refused → {:error, :forbidden}" do
      {plain, team} = member("member")
      newcomer = user_fixture()

      assert Accounts.add_member_as(plain, team, newcomer, "member") == {:error, :forbidden}
      assert Authz.role(newcomer, team) == nil
    end

    test "admin actor granting owner is refused (escalation)" do
      {admin, team} = member("admin")
      newcomer = user_fixture()

      assert Accounts.add_member_as(admin, team, newcomer, "owner") == {:error, :forbidden}
      assert Authz.role(newcomer, team) == nil
    end

    test "defaults the granted role to member" do
      {owner, team} = member("owner")
      newcomer = user_fixture()

      assert {:ok, m} = Accounts.add_member_as(owner, team, newcomer)
      assert m.role == "member"
    end
  end
end
