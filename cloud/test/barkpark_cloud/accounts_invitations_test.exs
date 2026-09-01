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

  # Put an OFF-LADDER role string straight into `team_memberships.role`.
  # `TeamMembership.changeset/2` refuses it (`validate_inclusion` against
  # `@roles`); the DATABASE does not — no migration puts a CHECK on that column,
  # proven independently by `Accounts.RoleAgreementCensusTest`'s "an off-ladder
  # role string really persists". Writing it HERE, past the changeset, is what
  # makes the assertions that use it independent of `validate_inclusion` ever
  # having run: the guard under test must hold on a row the changeset would
  # never have produced.
  defp off_ladder!(team, user, role) do
    refute role in TeamMembership.roles(),
           "off_ladder!/3 was handed #{inspect(role)}, which the changeset ACCEPTS — " <>
             "the caller would no longer be measuring the off-ladder branch"

    {1, _} =
      Repo.update_all(
        from(m in TeamMembership, where: m.team_id == ^team.id and m.user_id == ^user.id),
        set: [role: role]
      )

    # Non-vacuity: if a CHECK constraint ever guards the column, the write stops
    # landing and every off-ladder assertion below would pass for the wrong
    # reason. Asserted through `match?/2` so the message is live — a bare
    # `assert pattern = expr, msg` raises MatchError before assert/2 can speak.
    assert match?(%TeamMembership{role: ^role}, Accounts.get_membership(team, user)),
           "the off-ladder write did not survive — `team_memberships.role` now refuses " <>
             "#{inspect(role)}, so this test is vacuous and must be re-cut"

    :ok
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

  describe "update_member_role_as/4 (B1 anti-escalation)" do
    test "an admin cannot promote anyone to owner — incl. themselves → :forbidden" do
      {_owner, team} = owned_team()
      admin = user_fixture()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, admin, "admin")
      {:ok, _} = Accounts.add_member(team, member, "member")

      # self-promotion admin → owner is blocked by can_grant? (rank guard)
      assert {:error, :forbidden} = Accounts.update_member_role_as(admin, team, admin, "owner")
      # minting an owner from a member is likewise blocked
      assert {:error, :forbidden} = Accounts.update_member_role_as(admin, team, member, "owner")
    end

    test "an admin cannot demote an owner or a peer admin (does not out-rank) → :forbidden" do
      {owner, team} = owned_team()
      admin = user_fixture()
      peer_admin = user_fixture()
      {:ok, _} = Accounts.add_member(team, admin, "admin")
      {:ok, _} = Accounts.add_member(team, peer_admin, "admin")

      assert {:error, :forbidden} = Accounts.update_member_role_as(admin, team, owner, "member")

      assert {:error, :forbidden} =
               Accounts.update_member_role_as(admin, team, peer_admin, "member")
    end

    test "an owner may promote a member to admin" do
      {owner, team} = owned_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")

      assert {:ok, %TeamMembership{role: "admin"}} =
               Accounts.update_member_role_as(owner, team, member, "admin")
    end

    test "the sole owner self-demoting still hits the last-owner guard (not :forbidden)" do
      {owner, team} = owned_team()
      assert {:error, :last_owner} = Accounts.update_member_role_as(owner, team, owner, "member")
    end

    test "an invalid role is rejected before the authority check" do
      {owner, team} = owned_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")

      assert {:error, :invalid_role} =
               Accounts.update_member_role_as(owner, team, member, "superuser")
    end
  end

  describe "remove_member_as/3 (B1 anti-escalation)" do
    test "an admin may remove a member but NOT an owner or a peer admin" do
      {owner, team} = owned_team()
      peer_admin = user_fixture()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, peer_admin, "admin")
      {:ok, _} = Accounts.add_member(team, member, "member")

      assert {:error, :forbidden} = Accounts.remove_member_as("admin", team, owner)
      assert {:error, :forbidden} = Accounts.remove_member_as("admin", team, peer_admin)
      assert {:ok, :removed} = Accounts.remove_member_as("admin", team, member)
    end

    test "an owner may remove a peer owner while another remains; the last owner cannot" do
      {owner1, team} = owned_team()
      owner2 = user_fixture()
      {:ok, _} = Accounts.add_member(team, owner2, "owner")

      assert {:ok, :removed} = Accounts.remove_member_as("owner", team, owner2)
      assert {:error, :last_owner} = Accounts.remove_member_as("owner", team, owner1)
    end
  end

  describe "remove_member_as/3 carries its OWN actor tier (cch-w44)" do
    # WHAT WAS WRONG, said as a mechanism rather than a diff: the guard was
    # `actor_role == "owner" or outranks?(actor_role, target_role)`, and
    # `TeamMembership.rank/1` answers 0 for a role it does not know. So an
    # off-ladder TARGET sits BELOW everyone, `outranks?("member", "superadmin")`
    # is `1 > 0` = true, and a plain MEMBER was accepted as the remover. Nothing
    # in `remove_member_as/3` refused them — the only thing that did was
    # `with_team_role(conn, "admin", …)` at the single call site
    # (`Web.Router`'s `delete "/v1/teams/:id/members/:user_id"`). The safety held
    # only in COMPOSITION, so the context function was not safe to call from
    # anywhere else, and the two tests above never saw it: both act as an
    # {admin, owner} actor on an ON-LADDER target, so the off-ladder branch was
    # unreachable from their fixtures — vacuous-by-fixture, not by assertion.
    #
    # The remedy is on the ACTOR side (`TeamMembership.admin?/1`), NOT a
    # fail-closed `rank/1`. Fail-closing the ladder would have flipped
    # (admin, off-ladder) to a REFUSAL and broken two callers that rely on
    # off-ladder ranking 0 to fail CLOSED already — `Web.Auth.require_team_role/3`
    # and `Authz.can_grant?/3`, both of which compare an actor rank UPWARD
    # against a threshold. This mirrors the tier floor `update_member_role_as/4`
    # already has via `Authz.can_grant?/3`; it restores symmetry between the two
    # member verbs rather than inventing a rule.

    test "a MEMBER cannot remove an off-ladder target — and this holds with NO route in front" do
      {_owner, team} = owned_team()
      stray = user_fixture()
      {:ok, _} = Accounts.add_member(team, stray, "member")
      off_ladder!(team, stray, "superadmin")

      # COMPOSITION-INDEPENDENCE, proven directly: no Plug, no Router, no
      # `with_team_role/3`, no changeset. The context function is called on its
      # own, which is the whole point of the row — if this refusal ever depends
      # again on a gate that ran earlier, this assertion reds.
      assert {:error, :forbidden} = Accounts.remove_member_as("member", team, stray)

      # THE GUARD ON THE GUARD — do not delete this line. The refusal above must
      # be bought on the ACTOR side only. cch-w42-s3 pins the console mirror's
      # "admin acting on an OFF-LADDER row" cell to Remove-OFFERED
      # (`cloud/priv/static/__app.test.mjs`, `MEMBER_AUTHORITY_MATRIX`), because
      # hiding a control the server accepts is a FALSE REFUSAL — this epic's
      # failure class running backwards. If someone "hardens" `rank/1` or
      # `outranks?/2` to fail closed on an unknown role, THIS line reds and the
      # mirror cell stops being a lie by accident.
      assert {:ok, :removed} = Accounts.remove_member_as("admin", team, stray)
    end

    test "the owner escape hatch survives the new tier floor (D462)" do
      # D462 forbids collapsing this verb onto the rank ladder. `admin?/1` is a
      # CONJUNCT in front of the existing disjunction, never a replacement for
      # the hatch: an owner still removes a peer owner, which strict `>` alone
      # would refuse.
      {_owner1, team} = owned_team()
      owner2 = user_fixture()
      {:ok, _} = Accounts.add_member(team, owner2, "owner")

      assert {:ok, :removed} = Accounts.remove_member_as("owner", team, owner2)
    end

    test "an OFF-LADDER ACTOR is refused on every target" do
      # Green before the fix as well as after — a PIN, not a red. It states the
      # half of the ladder's softness that was always correct: an unknown actor
      # role ranks 0, so it outranks nobody and matches no hatch. `admin?/1`
      # keeps it that way instead of relying on `>` to.
      {owner, team} = owned_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")

      assert {:error, :forbidden} = Accounts.remove_member_as("superadmin", team, member)
      assert {:error, :forbidden} = Accounts.remove_member_as("superadmin", team, owner)
    end
  end

  describe "the two member verbs DISAGREE — the law the console mirrors" do
    # This describe pins the four cells the console's members row mirrors
    # (cch-w42-s3, charter D492/D496) and that no other test in cloud/test/**
    # asserts. The two verbs answer owner-on-peer-owner DIFFERENTLY, and that
    # single disagreement is why the console needs TWO predicates, not one:
    #
    #   remove_member_as/3   carries an OWNER ESCAPE HATCH — accounts.ex:1722
    #                        `actor_role == "owner" or outranks?(...)`
    #   update_member_role_as/4 has NO such hatch — accounts.ex:1801 demands
    #                        `outranks?(...)` outright (unless acting on SELF)
    #
    # Adding the hatch to :1801 (or removing it from :1722) must RED here, not
    # ship green and silently turn the console's mirror into a lie.

    test "owner on a PEER OWNER: role-change is forbidden, removal is allowed" do
      {owner1, team} = owned_team()
      owner2 = user_fixture()
      {:ok, _} = Accounts.add_member(team, owner2, "owner")

      # TWO owners on the team, so `last_owner` (a 409 STATE refusal) can never
      # confound the AUTHORITY answer either verb gives.
      assert {:error, :forbidden} = Accounts.update_member_role_as(owner1, team, owner2, "admin")
      assert {:ok, :removed} = Accounts.remove_member_as("owner", team, owner2)
    end

    test "admin on THEMSELVES: removal is forbidden, self-demotion is allowed" do
      {_owner, team} = owned_team()
      admin = user_fixture()
      {:ok, _} = Accounts.add_member(team, admin, "admin")

      # remove_member_as/3 has no `self?` branch at all — an admin does not
      # outrank themselves, so leaving via DELETE is refused…
      assert {:error, :forbidden} = Accounts.remove_member_as("admin", team, admin)
      # …while update_member_role_as/4's `self?` bypass lets them demote
      # themselves to "member" (can_grant? alone governs a self role-change).
      assert {:ok, %TeamMembership{role: "member"}} =
               Accounts.update_member_role_as(admin, team, admin, "member")
    end

    test "owner on THEMSELVES: BOTH verbs allow it — the cell the console knowingly under-offers" do
      # The console withholds `Remove` on the self row (charter D492 variant B)
      # because the pure authority mirror reds the merge-blocking members smoke,
      # whose 3-row roster has the actor at row 0. That withholding is a CONSOLE
      # RULING that contradicts the server, filed as
      # cch-w44-bl-self-row-underoffers-three-server-legal-cells — and an
      # under-offer, not this epic's offered-but-refused class.
      #
      # It is pinned HERE so the contradiction stays a decision rather than
      # decaying into a belief. If this test ever reds, the server moved TOWARD
      # the console and the withholding stopped being an under-offer — at which
      # point the console's matrix cell and the backlog task must be revisited
      # together, not silently.
      {owner1, team} = owned_team()
      owner2 = user_fixture()
      {:ok, _} = Accounts.add_member(team, owner2, "owner")

      # Two owners, so `last_owner` (a 409 STATE refusal) is not in play and the
      # answer below is purely about AUTHORITY.
      assert {:ok, %TeamMembership{role: "admin"}} =
               Accounts.update_member_role_as(owner1, team, owner1, "admin")

      {owner3, team2} = owned_team()
      owner4 = user_fixture()
      {:ok, _} = Accounts.add_member(team2, owner4, "owner")
      # remove_member_as/3 has no `self?` branch, so the OWNER ESCAPE HATCH at
      # accounts.ex:1722 answers for the self row too: an owner may remove
      # themselves. The console does not offer it.
      assert {:ok, :removed} = Accounts.remove_member_as("owner", team2, owner3)
    end
  end

  describe "invite_member/4 — expired re-invite (M5)" do
    test "an EXPIRED unaccepted invite no longer blocks re-inviting the same email" do
      {owner, team} = owned_team()

      {:ok, %{invitation: inv}} =
        Accounts.invite_member(team, "lapsed@example.com", "member", owner)

      # Expire it directly (still unaccepted).
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      Repo.get!(TeamInvitation, inv.id)
      |> Ecto.Changeset.change(expires_at: past)
      |> Repo.update!()

      # A fresh invite for the same email succeeds (the expired row is reaped).
      assert {:ok, %{invitation: fresh}} =
               Accounts.invite_member(team, "lapsed@example.com", "member", owner)

      refute fresh.id == inv.id
      # Exactly one live invitation remains.
      assert [%TeamInvitation{}] = Accounts.list_invitations(team)
    end

    test "a still-LIVE duplicate is still rejected (409 guard preserved)" do
      {owner, team} = owned_team()
      {:ok, _} = Accounts.invite_member(team, "live@example.com", "member", owner)

      assert {:error, %Ecto.Changeset{}} =
               Accounts.invite_member(team, "live@example.com", "member", owner)
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
