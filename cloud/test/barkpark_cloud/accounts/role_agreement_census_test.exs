defmodule BarkparkCloud.Accounts.RoleAgreementCensusTest do
  @moduledoc """
  A CENSUS, not a test: it walks the WHOLE role population instead of pinning
  the three pairs someone happened to think of, and both sides of every
  assertion are DERIVED — never a re-typed role literal.

  Four arms:

    * ARM A — DEMOTION AGREEMENT. For every ordered pair of roles and every PAT
      ability, a PAT survives `update_member_role/3` IFF the NEW role could
      mint it, where "could mint it" is measured through the real PUBLIC seam
      `create_personal_access_token/3` (never a test-only accessor for the
      private `pat_abilities_allowed?/2`). This is what a role literal in front
      of the derived revoker breaks: split owner and admin in the mint fence
      and the owner→admin cell reds by name.

    * ARM B — LADDER AND POLICY AGREEMENT. Every role the schema accepts must
      be ranked identically by BOTH ladders (`TeamMembership.rank/1` and
      `Authz.rank/1`) and must be granted something by `Authz`'s policy table.
      A fourth role that validates on the changeset but is unknown to authz is
      invisible to every other test in the suite; here it reds by name.

    * ARM C — THE TWO `team_admin?` ARE ONE PREDICATE. The control plane states
      "who may" twice: `Accounts.team_admin?/2` delegates to
      `TeamMembership.admin?/1` (`rank(role) >= rank("admin")`), while
      `Authz.team_admin?/2` tests membership of a role LITERAL list. Both are
      live — `require_team_admin` routes through Authz, `require_current_team_admin`
      through Accounts — and nothing asserted they agree. ARM C walks the FULL
      role domain, not just the three canonical roles: the schema roles, `nil`
      (non-member), and off-ladder strings. The off-ladder half is not
      hypothetical — there is NO CHECK constraint on `team_memberships.role` in
      any migration, so a migration or a hand-edit puts an unknown string in
      that column, and a third test proves that write survives.

    * ARM D — THE TWO `can_grant?` ARE ONE POLICY. The invitation path carries
      its OWN private literal triple (`Accounts.can_grant?/2`, reached from
      `invite_member/4`); the membership role-change path uses the rank-derived
      `Authz.can_grant?/3`. ARM D walks the whole (actor, target) matrix and
      measures the invitation side ONLY through the public `invite_member/4`
      seam — never a test-only accessor for the private function.

  Plus the ratified behaviour change the rank drop makes reachable: an
  owner→admin demotion now ends the demoted user's sessions.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.{Authz, TeamInvitation, TeamMembership, UserToken}

  # The census's OWN pinned allowlist of authz actions — a same-file pin, not a
  # foreign count: it mirrors the policy table documented on `Authz`, and the
  # owner probe below reds if any of these stops being a real action.
  @actions ~w(read launch delete_barkpark connect_provider manage_members billing delete_team)a

  # The OFF-LADDER half of ARM C's domain: role strings no changeset accepts
  # but the COLUMN does. Physically reachable —
  # `grep -rn role priv/repo/migrations/*.exs | grep -i 'check\|constraint'`
  # returns ZERO, so nothing in Postgres refuses these. Two of them ("OWNER",
  # "Admin") are case variants of real roles, which is exactly where a
  # "hardening" edit that downcases one side and not the other splits the two
  # predicates. These are this file's OWN pinned domain, not a foreign count:
  # the persistence test below proves each one is still writable.
  @off_ladder ["wizard", "OWNER", "Admin", "root", ""]

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "rac-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Census #{n}", slug: "census-#{n}"})
    team
  end

  # A team that ALWAYS has a standing owner, so the last-owner guard is never
  # what the census measures, plus `user` holding `role` in it.
  defp team_with_member_at(role) do
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user_fixture(), "owner")
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {user, team}
  end

  # THE DERIVED RIGHT-HAND SIDE: could a holder of `role` mint `abilities`
  # TODAY? Measured by asking the real public mint seam, in a throwaway team.
  defp mintable?(role, abilities) do
    {user, team} = team_with_member_at(role)

    case Accounts.create_personal_access_token(user, team, %{
           name: "probe",
           abilities: abilities
         }) do
      {:ok, _plaintext, _token} -> true
      {:error, :forbidden} -> false
    end
  end

  defp alive?(plaintext), do: Accounts.verify_personal_access_token(plaintext) != nil

  # ARM C/D's domain: every role a membership row can actually hold, plus the
  # absence of a row. `nil` means "no membership at all" — the non-member case
  # both predicates must also agree on.
  #
  # DERIVED FROM BOTH LADDERS, never re-typed. ARM C compares a RANK THRESHOLD
  # (`TeamMembership.@ranks`, via `Accounts.team_admin?/2`) against SET
  # MEMBERSHIP (`Authz.@admin_roles`, via `Authz.team_admin?/2`) — two
  # hand-maintained tables in two modules. A domain that re-typed
  # `~w(owner admin ...)` would pin the literal against itself and could never
  # lose: a role added to ONE ladder only would never enter the domain, so the
  # split it creates would ship green. Reading `ranked_roles/0` and
  # `admin_roles/0` means a single-limb edit puts its own new role into the
  # population that convicts it. `Enum.uniq/1` keeps the order stable and makes
  # the union free on clean main, where the two ladders already agree.
  defp full_role_domain do
    (TeamMembership.roles() ++
       TeamMembership.ranked_roles() ++
       Authz.admin_roles() ++ [nil] ++ @off_ladder)
    |> Enum.uniq()
  end

  # A team plus a user standing at `role` in it. Canonical roles go through the
  # public `add_member/3`; off-ladder roles are written straight to the column
  # (the changeset would refuse them — the DATABASE does not), which is the
  # whole point of the off-ladder half. `nil` yields a user who is simply not a
  # member.
  defp team_with_role_in_domain(nil) do
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user_fixture(), "owner")
    {user_fixture(), team}
  end

  defp team_with_role_in_domain(role) do
    if role in TeamMembership.roles() do
      team_with_member_at(role)
    else
      {user, team} = team_with_member_at("member")

      {1, _} =
        Repo.update_all(
          from(m in TeamMembership, where: m.team_id == ^team.id and m.user_id == ^user.id),
          set: [role: role]
        )

      {user, team}
    end
  end

  # THE PUBLIC INVITATION SEAM: may `actor` mint an invite at `target_role`?
  # Measured only by what `invite_member/4` DOES — never by reaching for the
  # private `can_grant?/2`. A fresh unique email keeps `:already_member` and the
  # duplicate-invite collision out of the measurement.
  defp invite_allows?(team, actor, target_role) do
    email = "census-invitee-#{System.unique_integer([:positive])}@example.com"

    case Accounts.invite_member(team, email, target_role, actor) do
      {:ok, %{invitation: _, token: _}} -> true
      {:error, :role_too_high} -> false
    end
  end

  ## ARM A — demotion agreement over the whole ordered role population

  describe "ARM A: after a role change, a PAT lives IFF the new role could mint it" do
    test "every ordered role pair × every PAT ability agrees with the mint fence" do
      roles = TeamMembership.roles()
      # One set per ability — the changeset normalizes a set down to its
      # strongest member, so singletons cover the vocabulary exactly.
      ability_sets = Enum.map(UserToken.abilities(), &[&1])

      for from_role <- roles,
          to_role <- roles,
          abilities <- ability_sets,
          mintable?(from_role, abilities) do
        {user, team} = team_with_member_at(from_role)

        {:ok, plaintext, _token} =
          Accounts.create_personal_access_token(user, team, %{
            name: "census",
            abilities: abilities
          })

        assert {:ok, %TeamMembership{role: ^to_role}} =
                 Accounts.update_member_role(team, user, to_role)

        still_alive? = alive?(plaintext)
        could_mint? = mintable?(to_role, abilities)
        ability = Enum.join(abilities, "+")

        assert still_alive? == could_mint?,
               "ROLE-AGREEMENT SPLIT: after #{from_role} -> #{to_role}, " <>
                 "#{ability} PAT alive?=#{still_alive?} but a #{to_role} " <>
                 "could mint it? #{could_mint?}"
      end
    end

    test "the census actually exercises an elevated grant (it cannot pass vacuously)" do
      elevated =
        Enum.filter(UserToken.abilities(), fn ability ->
          Enum.any?(TeamMembership.roles(), &(not mintable?(&1, [ability])))
        end)

      refute elevated == [],
             "no PAT ability is role-gated at all — ARM A would prove nothing"
    end
  end

  ## ARM B — the two rank ladders and the policy table agree on every role

  describe "ARM B: every schema role is known to the ladders and the policy table" do
    test "both ladders rank every schema role, identically" do
      for role <- TeamMembership.roles() do
        assert TeamMembership.rank(role) > 0, "TeamMembership has no rank for #{role}"
        assert Authz.rank(role) > 0, "Authz has no rank for #{role}"

        assert TeamMembership.rank(role) == Authz.rank(role),
               "LADDER SPLIT: #{role} ranks #{TeamMembership.rank(role)} on " <>
                 "TeamMembership but #{Authz.rank(role)} on Authz"
      end
    end

    test "the policy table grants every schema role at least one action" do
      for role <- TeamMembership.roles() do
        {user, team} = team_with_member_at(role)

        granted = Enum.filter(@actions, &(Authz.authorize(user, team, &1) == :ok))

        refute granted == [],
               "POLICY HOLE: Authz's policy table grants #{role} nothing — the " <>
                 "role validates on the membership changeset but confers no access"
      end
    end

    test "the census's pinned action list is real (an owner satisfies all of it)" do
      {owner, team} = team_with_member_at("owner")

      for action <- @actions do
        assert Authz.authorize(owner, team, action) == :ok,
               "STALE CENSUS: #{action} is no longer an action an owner satisfies — " <>
                 "the pinned action list has drifted from Authz's policy table"
      end
    end
  end

  ## ARM C — the two `team_admin?` predicates are one predicate

  describe "ARM C: Accounts and Authz state team-admin authority identically" do
    test "the two team_admin?/2 agree over every schema role, nil, and off-ladder" do
      verdicts =
        for role <- full_role_domain() do
          {user, team} = team_with_role_in_domain(role)

          accounts? = Accounts.team_admin?(user, team)
          authz? = Authz.team_admin?(user, team)

          assert accounts? == authz?,
                 "TEAM-ADMIN SPLIT: at role #{inspect(role)}, " <>
                   "Accounts.team_admin?=#{accounts?} but Authz.team_admin?=#{authz?} — " <>
                   "the control plane states 'who may' twice and the two statements disagree"

          accounts?
        end

      # VACUITY: a domain that answers only false would pass the equality above
      # while proving nothing.
      assert true in verdicts and false in verdicts,
             "VACUOUS CENSUS: the role domain produced #{inspect(Enum.uniq(verdicts))} only — " <>
               "ARM C must see both an admin and a non-admin verdict"
    end

    test "TeamMembership.admin?/1 equals the set Authz actually gates :manage_members with" do
      # The right-hand side is DERIVED through the public `authorize/3` seam —
      # the set Authz really gates with today. A re-typed ~w(owner admin) here
      # would pin the literal against itself and catch nothing.
      verdicts =
        for role <- full_role_domain() do
          {user, team} = team_with_role_in_domain(role)

          schema_admin? = TeamMembership.admin?(role)
          authz_admin? = Authz.authorize(user, team, :manage_members) == :ok

          assert schema_admin? == authz_admin?,
                 "ADMIN-SET SPLIT: at role #{inspect(role)}, " <>
                   "TeamMembership.admin?=#{schema_admin?} but Authz gates " <>
                   ":manage_members open?=#{authz_admin?} — the rank ladder and the " <>
                   "policy table disagree about who is an admin"

          schema_admin?
        end

      assert true in verdicts and false in verdicts,
             "VACUOUS CENSUS: the role domain produced #{inspect(Enum.uniq(verdicts))} only — " <>
               "ARM C must see both an admin and a non-admin verdict"
    end

    test "an off-ladder role string really persists (no CHECK constraint guards the column)" do
      for role <- @off_ladder do
        {user, team} = team_with_role_in_domain(role)

        assert %TeamMembership{role: ^role} = Accounts.get_membership(team, user),
               "UNREACHABLE DOMAIN: #{inspect(role)} no longer survives a write to " <>
                 "team_memberships.role — if a CHECK constraint now guards the column, " <>
                 "ARM C's off-ladder half is dead weight and should be re-cut"
      end
    end
  end

  ## ARM D — the two `can_grant?` encodings are one policy

  describe "ARM D: the invitation grant policy agrees with the rank-derived one" do
    test "invite_member/4 and Authz.can_grant?/3 agree over the whole (actor, target) matrix" do
      actor_roles = TeamMembership.roles() ++ [nil]

      verdicts =
        for actor_role <- actor_roles, target_role <- TeamInvitation.roles() do
          {actor, team} = team_with_role_in_domain(actor_role)

          invite? = invite_allows?(team, actor, target_role)
          authz? = Authz.can_grant?(actor, team, target_role) == :ok

          assert invite? == authz?,
                 "GRANT-POLICY SPLIT: a #{inspect(actor_role)} granting #{target_role} — " <>
                   "invite_member allows?=#{invite?} but Authz.can_grant? says #{authz?} — " <>
                   "the invitation path's private literal triple has drifted from the " <>
                   "rank-derived rule the role-change path uses"

          invite?
        end

      assert true in verdicts and false in verdicts,
             "VACUOUS CENSUS: the (actor, target) matrix produced " <>
               "#{inspect(Enum.uniq(verdicts))} only — ARM D must see both a grant and a refusal"
    end
  end

  ## The ratified behaviour change the rank drop makes reachable (charter D355)

  describe "session eviction on a demotion" do
    test "owner -> admin now ends the demoted user's sessions" do
      {user, team} = team_with_member_at("owner")
      {:ok, session} = Accounts.create_user_session_token(user)

      assert {:ok, %TeamMembership{role: "admin"}} =
               Accounts.update_member_role(team, user, "admin")

      refute Accounts.verify_user_session_token(session),
             "an owner demoted to admin must lose the elevated session"
    end

    test "a promotion leaves the session alone" do
      {user, team} = team_with_member_at("member")
      {:ok, session} = Accounts.create_user_session_token(user)

      assert {:ok, %TeamMembership{role: "admin"}} =
               Accounts.update_member_role(team, user, "admin")

      assert Accounts.verify_user_session_token(session),
             "a promotion must not log the user out"
    end
  end

  ## THE FOURTH ENCODING, DELIBERATELY NOT ASSERTED (charter D462)
  #
  # `Accounts.remove_member_as/3` states anti-escalation a fourth way:
  # `actor_role == "owner" or TeamMembership.outranks?(actor_role, target_role)`.
  # There is NO ARM E, because an equality against the outrank rule is RED ON
  # CLEAN MAIN: an owner removing a PEER owner is allowed, while
  # `outranks?("owner", "owner")` is false (rank 3 > rank 3 does not hold). That
  # divergence is INTENTIONAL and is already pinned by
  # `test/barkpark_cloud/accounts_invitations_test.exs` — "an owner may remove a
  # peer owner while another remains; the last owner cannot" (the last-owner
  # guard, not the rank ladder, is what stops the team losing its owner).
  #
  # Per charter D462, collapsing removal onto the rank rule would be a BEHAVIOUR
  # CHANGE, not a dedup, so it is a decision for a charter — not something this
  # census may quietly force by asserting an equality that does not hold. Nor is
  # the implementation re-typed into a pin here: a literal copy of the rule would
  # assert only that the census can read `accounts.ex`.
end
