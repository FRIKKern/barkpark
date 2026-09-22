defmodule BarkparkCloud.AccountsInvitationsTest do
  @moduledoc """
  Context-level tests for the teams-invitations slice: invite/accept lifecycle,
  member management, role gating, and session eviction on removal/demotion.
  Kept in its own module (not folded into accounts_test.exs) so the invitation
  surface is reviewable in isolation.
  """
  # async: false — `off_ladder!/3` DROPS `team_memberships_role_check` inside this
  # test's sandbox transaction (see `BarkparkCloud.OffLadderRole`), which takes
  # ACCESS EXCLUSIVE on `team_memberships`. ExUnit runs sync suites serially and
  # only after every async suite, so that lock cannot stall a concurrent test.
  use BarkparkCloud.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.OffLadderRole
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
  # `@roles`), and since `team_memberships_role_check` (migration
  # 20260918120000) so does the DATABASE — so the write goes through
  # `OffLadderRole.without_role_constraint/1`, which drops the CHECK inside this
  # test's own sandbox transaction. The shape is still real: rows written before
  # that migration hold such strings, and charter D493 rules they rank 0.
  # Writing it HERE, past the changeset, is what
  # makes the assertions that use it independent of `validate_inclusion` ever
  # having run: the guard under test must hold on a row the changeset would
  # never have produced.
  defp off_ladder!(team, user, role) do
    refute role in TeamMembership.roles(),
           "off_ladder!/3 was handed #{inspect(role)}, which the changeset ACCEPTS — " <>
             "the caller would no longer be measuring the off-ladder branch"

    {1, _} =
      OffLadderRole.without_role_constraint(fn ->
        Repo.update_all(
          from(m in TeamMembership, where: m.team_id == ^team.id and m.user_id == ^user.id),
          set: [role: role]
        )
      end)

    # Non-vacuity: if the write ever stops landing (a second guard, a failed
    # drop), every off-ladder assertion below would pass for the wrong reason. Asserted through `match?/2` so the message is live — a bare
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

    test "owner on THEMSELVES: BOTH verbs allow it — and the console now offers both" do
      # WAS the cell the console knowingly under-offered: it withheld `Remove` on
      # the self row (charter D492 variant B) while the server answered
      # {:ok, :removed}. cch-w44-bl closed that gap — `canRemoveMember` no longer
      # opens with a blanket `if (isSelf) return false`, and the console's
      # MEMBER_AUTHORITY_MATRIX cell "owner acting on THEIR OWN row" now pins
      # Remove as OFFERED. This test is the SERVER half of that pair: it is what
      # makes the offered button honest, so if it reds, the console is over-
      # offering and cloud/priv/static/__app.test.mjs must move with it.
      #
      # The only refusal left on an owner's own row is STATE, not authority —
      # the sole-owner arm at the bottom of this test — and the console models
      # exactly that one with `isSoleOwnerSelf`, never with a self rule.
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
      # themselves. The console offers it (cch-w44-bl).
      assert {:ok, :removed} = Accounts.remove_member_as("owner", team2, owner3)
    end

    test "the SOLE owner on themselves: :last_owner, a STATE refusal — never :forbidden" do
      # THE PRECONDITION FOR THE CONSOLE'S ONE REMAINING SELF-ROW OMISSION.
      # cch-w44-bl gates the self Remove on `isSoleOwnerSelf`, i.e. on STATE,
      # and that is only honest if the sole owner's own removal is refused by
      # do_remove's `locked_owner_count(team) <= 1 -> Repo.rollback(:last_owner)`
      # rather than by an authority arm. The two answers are NOT interchangeable:
      # a :forbidden here would mean the withholding belongs in canRemoveMember,
      # a :last_owner means it belongs where it now is.
      #
      # THE CONTROL is the test above: on a team with a SECOND owner the very
      # same call answers {:ok, :removed}. Without it this assertion could not
      # tell "the sole-owner guard fired" from "owners can never self-remove".
      {owner, team} = owned_team()
      assert [%{role: "owner"}] = Accounts.list_team_members(team)

      assert {:error, :last_owner} = Accounts.remove_member_as("owner", team, owner)
      # …and the refusal ROLLED BACK: the membership survives, so the console is
      # withholding a control over a member who is genuinely still there.
      assert %TeamMembership{role: "owner"} = Accounts.get_membership(team, owner)
    end
  end

  describe "the REMAINDER of the member relation-by-verb matrix (cch-w44-bl)" do
    # The describe above pins the cells where the two verbs DISAGREE. These are
    # the cells where they AGREE and nothing asserted them: a census of
    # cloud/test/** at cab3bf2fe found each of the five below reachable by no
    # assertion in the tree, so the server could change its answer and every
    # cloud test would stay green while the console's MEMBER_AUTHORITY_MATRIX
    # went on mirroring the old law.
    #
    # Each test names the ARM it covers, because each one is mutation-proved
    # against a DIFFERENT mutation of that arm — two tests that die to the same
    # edit have proved one thing, not two.

    test "owner on an ADMIN: removal is allowed — the outranks? conjunct" do
      # ARM: remove_member_as/3's `outranks?(actor_role, target_role)`. The owner
      # ESCAPE HATCH is not what carries this cell — owner strictly outranks
      # admin, so the rank conjunct answers on its own. Narrowing that conjunct
      # to "…and the target is a plain member" is the regression this catches.
      {_owner, team} = owned_team()
      admin = user_fixture()
      {:ok, _} = Accounts.add_member(team, admin, "admin")

      assert {:ok, :removed} = Accounts.remove_member_as("owner", team, admin)
      assert is_nil(Accounts.get_membership(team, admin))
    end

    test "owner on an ADMIN: demotion to member is allowed — the current-role outranks? arm" do
      # ARM: update_member_role_as/4's `not self? and not outranks?(actor, current_role)`.
      # The SIBLING of the cell above, in the verb that has no owner hatch: here
      # the owner's authority comes from the rank comparison alone, exactly as it
      # does for removal, which is why these two cells agree while the
      # owner-on-peer-OWNER pair (the describe above) does not.
      {owner, team} = owned_team()
      admin = user_fixture()
      {:ok, _} = Accounts.add_member(team, admin, "admin")

      assert {:ok, %TeamMembership{role: "member"}} =
               Accounts.update_member_role_as(owner, team, admin, "member")

      assert %TeamMembership{role: "member"} = Accounts.get_membership(team, admin)
    end

    test "admin on a MEMBER: promotion to ADMIN is allowed — can_grant?'s EQUAL-RANK rule" do
      # ARM: Authz.can_grant?/3's `rank(target_role) > actor_rank`, a STRICT `>`,
      # so minting a PEER of your own rank is permitted. Coolify's own guard is
      # the stricter form and Authz's own @doc calls this an OPEN POLICY
      # QUESTION, which is precisely why the shipped answer needs a witness: if
      # the comparison is ever tightened to `>=`, an admin loses the ability to
      # mint another admin and this cell must be the thing that says so.
      {_owner, team} = owned_team()
      admin = user_fixture()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, admin, "admin")
      {:ok, _} = Accounts.add_member(team, member, "member")

      assert {:ok, %TeamMembership{role: "admin"}} =
               Accounts.update_member_role_as(admin, team, member, "admin")
    end

    test "MEMBER as actor: removal is refused on EVERY in-ladder target" do
      # ARM: remove_member_as/3's rank comparison. The one member-as-actor cell
      # already in this file uses an OFF-LADDER target (the actor-tier floor),
      # and that test cannot see this arm: an off-ladder target ranks 0, so it is
      # the `admin?(actor_role)` conjunct that refuses there. On an IN-LADDER
      # target the floor and the ladder agree, and this pins the ladder half —
      # loosening `outranks?/2` from `>` to `>=` flips the peer cell below while
      # leaving the off-ladder test perfectly green.
      {owner, team} = owned_team()
      peer = user_fixture()
      admin = user_fixture()
      {:ok, _} = Accounts.add_member(team, peer, "member")
      {:ok, _} = Accounts.add_member(team, admin, "admin")

      assert {:error, :forbidden} = Accounts.remove_member_as("member", team, peer)
      assert {:error, :forbidden} = Accounts.remove_member_as("member", team, admin)
      assert {:error, :forbidden} = Accounts.remove_member_as("member", team, owner)

      # CONTROL — the refusals above are about the ACTOR, not about these three
      # rows being unremovable: the very same target falls to an admin.
      assert {:ok, :removed} = Accounts.remove_member_as("admin", team, peer)
    end

    test "MEMBER as actor on THEMSELVES: a self role-change is refused — can_grant?'s floor" do
      # ARM: Authz.can_grant?/3's `not team_admin?(actor, team)` clause, and this
      # is the ONLY cell in the matrix that can see it. A self role-change takes
      # update_member_role_as/4's `self?` bypass, so the outranks? clause never
      # runs and the actor-tier floor is the whole guard. On any OTHER target a
      # member is refused twice over, and deleting this floor there changes
      # nothing observable — which is exactly how a floor rots unseen.
      {owner, team} = owned_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")

      assert {:error, :forbidden} = Accounts.update_member_role_as(member, team, member, "member")
      assert {:error, :forbidden} = Accounts.update_member_role_as(member, team, member, "admin")

      # CONTROL — the row is not frozen: an owner may change the very same row.
      assert {:ok, %TeamMembership{role: "admin"}} =
               Accounts.update_member_role_as(owner, team, member, "admin")
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

  # The read is `Repo.get_by(TeamInvitation, id: inv_id, team_id: tid)`. The
  # `id:` half is exercised by every caller; the `team_id:` half had NO
  # behavioural coverage (the only `revoke_invitation` mention under
  # cloud/test was a vocabulary-census entry), so deleting it left the whole
  # cloud suite green. These tests are that half.
  #
  # THE TWO FIXTURES, field for field. Both invitations are minted by
  # `invite_member/4` from the SAME literal email and role, by the SAME
  # inviter user (`alice`, made owner of BOTH teams on purpose so
  # `invited_by_id` is not free either):
  #
  #   field          happy-path (team_a)      cross-team (team_b)
  #   email          "twin@example.com"       "twin@example.com"     same
  #   role           "member"                 "member"               same
  #   invited_by_id  alice.id                 alice.id               same
  #   accepted_at    nil                      nil                    same
  #   team_id        team_a.id                team_b.id              THE VARIABLE
  #   id             uuid A                   uuid B                 FORCED: @primary_key
  #                                                                  {:id, :binary_id,
  #                                                                  autogenerate: true}
  #   token_hash     sha256(raw A)            sha256(raw B)          FORCED:
  #                                                                  invite_member/4 mints a
  #                                                                  fresh `generate_token()`
  #                                                                  per row and stores only
  #                                                                  its hash
  #   expires_at     now_A + 7d               now_B + 7d             FORCED: derived from
  #                                                                  DateTime.utc_now() at
  #                                                                  mint time; differs by
  #                                                                  microseconds
  #   inserted_at/   two clock reads          two clock reads        FORCED: timestamps()
  #   updated_at
  #
  # Nothing else differs. Note the email being IDENTICAL is legal: the partial
  # UNIQUE index on (team_id, email) WHERE accepted_at IS NULL is per-team, so
  # the same address may hold one live invite in each team — which is exactly
  # the collision the fence has to survive.
  defp twin_invitations do
    alice = user_fixture()
    team_a = team_fixture()
    team_b = team_fixture()
    {:ok, _} = Accounts.add_member(team_a, alice, "owner")
    {:ok, _} = Accounts.add_member(team_b, alice, "owner")

    {:ok, %{invitation: inv_a}} =
      Accounts.invite_member(team_a, "twin@example.com", "member", alice)

    {:ok, %{invitation: inv_b}} =
      Accounts.invite_member(team_b, "twin@example.com", "member", alice)

    %{team_a: team_a, team_b: team_b, inv_a: inv_a, inv_b: inv_b}
  end

  describe "revoke_invitation/2 — the team_id fence" do
    test "the twins differ ONLY in team_id (plus the identity/secret/clock fields forced by the schema)" do
      %{inv_a: a, inv_b: b, team_a: team_a, team_b: team_b} = twin_invitations()

      # The free fields are equal...
      assert a.email == b.email
      assert a.role == b.role
      assert a.invited_by_id == b.invited_by_id
      assert a.accepted_at == nil and b.accepted_at == nil

      # ...the variable under test is not...
      assert a.team_id == team_a.id
      assert b.team_id == team_b.id
      refute a.team_id == b.team_id

      # ...and every REMAINING difference is one the schema forces, named with
      # the constraint that forces it. Anything not in this list is equal above.
      forced = [:id, :token_hash, :expires_at, :inserted_at, :updated_at, :team_id]

      differing =
        for f <- [
              :id,
              :email,
              :role,
              :token_hash,
              :expires_at,
              :accepted_at,
              :team_id,
              :invited_by_id,
              :inserted_at,
              :updated_at
            ],
            Map.get(a, f) != Map.get(b, f),
            do: f

      # Subset, not equality: two clock reads CAN land on the same microsecond,
      # so a forced field is allowed to come out equal. What may never happen is
      # a difference this list does not name.
      assert differing -- forced == []
      assert :team_id in differing
    end

    # [0] has TWO halves — the RETURN VALUE and the ROW SURVIVING. They are two
    # tests on purpose: ExUnit stops a test at its first failing assertion, so a
    # single test leading with the return value would leave the destructive half
    # (the half that matters) unproved under the mutation. Each test below leads
    # with its own claim, so each reds on its own.
    test "[0a] a cross-team invitation id RETURNS exactly what an unknown id returns" do
      %{team_a: team_a, inv_b: inv_b} = twin_invitations()

      assert {:error, :not_found} = Accounts.revoke_invitation(team_a, inv_b.id)

      # Byte-for-byte identical to a NEVER-EXISTED id: the refusal leaks nothing
      # about whether the id is real.
      unknown = Ecto.UUID.generate()

      assert Accounts.revoke_invitation(team_a, inv_b.id) ==
               Accounts.revoke_invitation(team_a, unknown)
    end

    test "[0b] the other team's invitation row SURVIVES the call (re-read from the database)" do
      %{team_a: team_a, inv_a: inv_a, inv_b: inv_b} = twin_invitations()

      _ = Accounts.revoke_invitation(team_a, inv_b.id)

      # The re-read is the assertion — NOT the return value. A refusal that still
      # deleted the row would pass [0a] and be the whole bug. This is the FIRST
      # assertion in this test so the mutation reds it directly.
      assert %TeamInvitation{team_id: still_b} = Repo.get(TeamInvitation, inv_b.id)
      assert still_b == inv_b.team_id

      # team_a's own pending list never grew or shrank either.
      assert [%TeamInvitation{id: only_live}] = Accounts.list_invitations(team_a)
      assert only_live == inv_a.id
    end

    test "HAPPY-PATH CONTROL — the same call with the id's OWN team revokes it" do
      %{team_a: team_a, inv_a: inv_a, inv_b: inv_b} = twin_invitations()

      assert {:ok, %TeamInvitation{id: revoked_id}} = Accounts.revoke_invitation(team_a, inv_a.id)
      assert revoked_id == inv_a.id
      assert Repo.get(TeamInvitation, inv_a.id) == nil

      # So the not_found in [0a] is the FENCE refusing, not revoke_invitation/2
      # being dead — and the twin in team B is untouched by the control.
      assert %TeamInvitation{} = Repo.get(TeamInvitation, inv_b.id)
    end
  end
end
