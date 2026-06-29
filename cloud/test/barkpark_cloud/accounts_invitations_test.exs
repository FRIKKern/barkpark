defmodule BarkparkCloud.AccountsInvitationsTest do
  @moduledoc """
  Context-level tests for the teams-invitations slice: invite/accept lifecycle,
  member management, role gating, and session eviction on removal/demotion.
  Kept in its own module (not folded into accounts_test.exs) so the invitation
  surface is reviewable in isolation.
  """
  use BarkparkCloud.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.{TeamInvitation, TeamMembership}
  alias BarkparkCloud.Repo

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

  # A team with `user` as its owner. Returns {user, team}.
  defp owned_team(user \\ nil) do
    user = user || user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  describe "team_role/2 + team_admin?/2" do
    test "reports the held role and admin status; nil/false for a non-member" do
      {owner, team} = owned_team()
      admin = user_fixture()
      member = user_fixture()
      stranger = user_fixture()
      {:ok, _} = Accounts.add_member(team, admin, "admin")
      {:ok, _} = Accounts.add_member(team, member, "member")

      assert Accounts.team_role(owner, team) == "owner"
      assert Accounts.team_role(admin, team) == "admin"
      assert Accounts.team_role(member, team) == "member"
      assert Accounts.team_role(stranger, team) == nil

      assert Accounts.team_admin?(owner, team)
      assert Accounts.team_admin?(admin, team)
      refute Accounts.team_admin?(member, team)
      refute Accounts.team_admin?(stranger, team)
    end
  end

  describe "invite_member/4" do
    test "returns the raw token ONCE; only the hash is stored" do
      {owner, team} = owned_team()

      assert {:ok, %{invitation: inv, token: raw}} =
               Accounts.invite_member(team, "Invitee@Example.com", "member", owner)

      assert is_binary(raw)
      # email is canonicalized to lowercase.
      assert inv.email == "invitee@example.com"
      # the persisted row carries only the hash, never the plaintext.
      stored = Repo.get!(TeamInvitation, inv.id)
      assert stored.token_hash == TeamInvitation.hash_token(raw)
      refute stored.token_hash == raw
    end

    test "an admin may invite member/admin but NOT owner" do
      {_owner, team} = owned_team()
      admin = user_fixture()
      {:ok, _} = Accounts.add_member(team, admin, "admin")

      assert {:ok, _} = Accounts.invite_member(team, "a@example.com", "member", admin)
      assert {:ok, _} = Accounts.invite_member(team, "b@example.com", "admin", admin)

      assert {:error, :role_too_high} =
               Accounts.invite_member(team, "c@example.com", "owner", admin)
    end

    test "a plain member may invite nothing" do
      {_owner, team} = owned_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")

      assert {:error, :role_too_high} =
               Accounts.invite_member(team, "x@example.com", "member", member)
    end

    test "rejects an unknown role" do
      {owner, team} = owned_team()

      assert {:error, :invalid_role} =
               Accounts.invite_member(team, "x@example.com", "superuser", owner)
    end

    test ":already_member when the email already belongs to a team member" do
      {owner, team} = owned_team()
      existing = user_fixture(email: "joined@example.com")
      {:ok, _} = Accounts.add_member(team, existing, "member")

      assert {:error, :already_member} =
               Accounts.invite_member(team, "Joined@example.com", "member", owner)
    end

    test "a duplicate LIVE invite is rejected; a fresh one is allowed after accept" do
      {owner, team} = owned_team()
      invitee = user_fixture(email: "dup@example.com")

      assert {:ok, %{token: raw}} =
               Accounts.invite_member(team, "dup@example.com", "member", owner)

      assert {:error, %Ecto.Changeset{}} =
               Accounts.invite_member(team, "dup@example.com", "member", owner)

      # accept the first, then a new invite for the same email is permitted.
      assert {:ok, _} = Accounts.accept_invitation(raw, invitee)
      # invitee is now a member, so re-inviting them is :already_member (not the
      # unique violation) — prove the partial-unique no longer blocks a fresh row
      # by removing them first.
      assert {:ok, :removed} = Accounts.remove_member(team, invitee)
      assert {:ok, _} = Accounts.invite_member(team, "dup@example.com", "member", owner)
    end
  end

  describe "get_live_invitation/1" do
    test "resolves a live token with the team preloaded; nil for accepted/expired/garbage" do
      {owner, team} = owned_team()
      {:ok, %{token: raw}} = Accounts.invite_member(team, "look@example.com", "member", owner)

      inv = Accounts.get_live_invitation(raw)
      assert inv.team.id == team.id
      assert inv.email == "look@example.com"

      assert Accounts.get_live_invitation("not-a-real-token") == nil

      # expire it directly and confirm it drops out.
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      Repo.get!(TeamInvitation, inv.id)
      |> Ecto.Changeset.change(expires_at: past)
      |> Repo.update!()

      assert Accounts.get_live_invitation(raw) == nil
    end
  end

  describe "accept_invitation/2" do
    test "happy path attaches the membership at the invited role and stamps accepted_at" do
      {owner, team} = owned_team()
      invitee = user_fixture(email: "newbie@example.com")

      {:ok, %{invitation: inv, token: raw}} =
        Accounts.invite_member(team, "newbie@example.com", "admin", owner)

      assert {:ok, %TeamMembership{role: "admin"}} = Accounts.accept_invitation(raw, invitee)
      assert Accounts.team_role(invitee, team) == "admin"
      assert Repo.get!(TeamInvitation, inv.id).accepted_at != nil
    end

    test "replaying an accepted token → :invalid_token (single-use)" do
      {owner, team} = owned_team()
      invitee = user_fixture(email: "once@example.com")
      {:ok, %{token: raw}} = Accounts.invite_member(team, "once@example.com", "member", owner)

      assert {:ok, _} = Accounts.accept_invitation(raw, invitee)
      assert {:error, :invalid_token} = Accounts.accept_invitation(raw, invitee)
    end

    test "an expired token → :invalid_token" do
      {owner, team} = owned_team()
      invitee = user_fixture(email: "late@example.com")

      {:ok, %{invitation: inv, token: raw}} =
        Accounts.invite_member(team, "late@example.com", "member", owner)

      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      Repo.get!(TeamInvitation, inv.id)
      |> Ecto.Changeset.change(expires_at: past)
      |> Repo.update!()

      assert {:error, :invalid_token} = Accounts.accept_invitation(raw, invitee)
    end

    test "wrong logged-in user (email mismatch) → :email_mismatch" do
      {owner, team} = owned_team()
      {:ok, %{token: raw}} = Accounts.invite_member(team, "intended@example.com", "member", owner)
      other = user_fixture(email: "someone-else@example.com")

      assert {:error, :email_mismatch} = Accounts.accept_invitation(raw, other)
    end
  end

  describe "remove_member/2" do
    test "deletes the membership AND evicts the user's sessions" do
      {_owner, team} = owned_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")
      {:ok, token} = Accounts.create_user_session_token(member)
      assert Accounts.verify_user_session_token(token)

      assert {:ok, :removed} = Accounts.remove_member(team, member)
      assert Accounts.get_membership(team, member) == nil
      # the removed user is logged out everywhere.
      assert Accounts.verify_user_session_token(token) == nil
    end

    test "the sole owner cannot be removed" do
      {owner, team} = owned_team()
      assert {:error, :last_owner} = Accounts.remove_member(team, owner)
    end

    test "a non-member → :not_found" do
      {_owner, team} = owned_team()
      stranger = user_fixture()
      assert {:error, :not_found} = Accounts.remove_member(team, stranger)
    end
  end

  describe "update_member_role/3" do
    test "demoting the sole owner → :last_owner" do
      {owner, team} = owned_team()
      assert {:error, :last_owner} = Accounts.update_member_role(team, owner, "member")
    end

    test "promotes a member to admin" do
      {_owner, team} = owned_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")

      assert {:ok, %TeamMembership{role: "admin"}} =
               Accounts.update_member_role(team, member, "admin")
    end

    test "demoting an admin to member evicts that user's sessions" do
      {_owner, team} = owned_team()
      admin = user_fixture()
      {:ok, _} = Accounts.add_member(team, admin, "admin")
      {:ok, token} = Accounts.create_user_session_token(admin)

      assert {:ok, %TeamMembership{role: "member"}} =
               Accounts.update_member_role(team, admin, "member")

      assert Accounts.verify_user_session_token(token) == nil
    end

    test "rejects an unknown role" do
      {_owner, team} = owned_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")
      assert {:error, :invalid_role} = Accounts.update_member_role(team, member, "superuser")
    end
  end

  describe "delete_user_session_tokens/1" do
    test "deletes every session row for the user" do
      user = user_fixture()
      {:ok, _} = Accounts.create_user_session_token(user)
      {:ok, _} = Accounts.create_user_session_token(user)

      assert {:ok, 2} = Accounts.delete_user_session_tokens(user)

      assert Repo.aggregate(
               from(t in "user_tokens", where: t.user_id == type(^user.id, :binary_id)),
               :count
             ) == 0
    end
  end
end
