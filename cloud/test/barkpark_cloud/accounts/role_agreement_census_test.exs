defmodule BarkparkCloud.Accounts.RoleAgreementCensusTest do
  @moduledoc """
  A CENSUS, not a test: it walks the WHOLE role population instead of pinning
  the three pairs someone happened to think of, and both sides of every
  assertion are DERIVED — never a re-typed role literal.

  Two arms:

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

  Plus the ratified behaviour change the rank drop makes reachable: an
  owner→admin demotion now ends the demoted user's sessions.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.{Authz, TeamMembership, UserToken}

  # The census's OWN pinned allowlist of authz actions — a same-file pin, not a
  # foreign count: it mirrors the policy table documented on `Authz`, and the
  # owner probe below reds if any of these stops being a real action.
  @actions ~w(read launch delete_barkpark connect_provider manage_members billing delete_team)a

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
end
