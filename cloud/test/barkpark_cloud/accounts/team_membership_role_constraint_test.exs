defmodule BarkparkCloud.Accounts.TeamMembershipRoleConstraintTest do
  @moduledoc """
  cch-w44: `team_memberships.role` is a CLOSED vocabulary IN THE DATABASE, not
  merely in a changeset.

  Until the `team_memberships_role_check` migration, the only thing standing
  between the role ladder and an unranked string was
  `validate_inclusion(:role, @roles)` on `TeamMembership.changeset/2` — so any
  writer that reached the column another way (`update_all`, `insert_all`, a
  repair script, psql) could seat a role `TeamMembership.rank/1` has never
  ranked. `rank/1` is `Map.get(@ranks, role, 0)`, so such a row does not arrive
  as a loud unknown; it arrives as a silent rank-0 member.

  These tests deliberately BYPASS the changeset — they issue raw SQL — because
  the claim under test is about the DATABASE, and a changeset test cannot
  distinguish "Ecto refused" from "Postgres refused".

  NON-VACUITY IS BUILT IN: every rejection arm has a CONTROL that issues the
  SAME statement with a real role and asserts it lands. A rejection test whose
  insert was malformed would red its control too.

  The drift arm is what keeps this honest over time: it reads the live
  constraint definition out of `pg_constraint` and compares it against
  `TeamMembership.roles()`. The migration PINS its own copy of the vocabulary
  (a migration must keep meaning what it meant the day it ran); this arm is the
  LOCK on that copy — adding a role to `@roles` without cutting a follow-up
  migration reds here.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.TeamMembership

  @constraint "team_memberships_role_check"

  defp team_and_user do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "role-constraint-#{n}@example.com",
        password: "correct horse battery staple"
      })

    {team, user}
  end

  # A raw INSERT, no changeset anywhere in the path — the only shape that can
  # prove WHO refused.
  defp raw_insert(team_id, user_id, role) do
    Repo.query(
      """
      INSERT INTO team_memberships (id, user_id, team_id, role, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, $3::uuid, $4, now(), now())
      """,
      [
        Ecto.UUID.bingenerate(),
        Ecto.UUID.dump!(user_id),
        Ecto.UUID.dump!(team_id),
        role
      ]
    )
  end

  defp raw_update(team_id, user_id, role) do
    Repo.query(
      "UPDATE team_memberships SET role = $1 WHERE team_id = $2::uuid AND user_id = $3::uuid",
      [role, Ecto.UUID.dump!(team_id), Ecto.UUID.dump!(user_id)]
    )
  end

  describe "MUTATION PROOF — the database refuses an off-ladder role" do
    test "a raw INSERT of a role outside @roles is rejected by Postgres" do
      {team, user} = team_and_user()

      assert {:error, %Postgrex.Error{postgres: pg}} = raw_insert(team.id, user.id, "bogus")

      assert pg.code == :check_violation
      assert pg.constraint == @constraint

      # THE CONTROL, same statement, real role: proves the rejection above came
      # from the CHECK and not from a malformed INSERT.
      assert {:ok, %{num_rows: 1}} = raw_insert(team.id, user.id, "admin")
      assert Accounts.team_role(user, team) == "admin"
    end

    test "a raw UPDATE off the ladder is rejected, and onto it is not" do
      {team, user} = team_and_user()
      {:ok, _} = Accounts.add_member(team, user, "member")

      assert {:error, %Postgrex.Error{postgres: pg}} = raw_update(team.id, user.id, "superadmin")
      assert pg.code == :check_violation
      assert pg.constraint == @constraint

      # The row is untouched, and the SAME update with a real role lands.
      assert Accounts.team_role(user, team) == "member"
      assert {:ok, %{num_rows: 1}} = raw_update(team.id, user.id, "owner")
      assert Accounts.team_role(user, team) == "owner"
    end

    test "the empty string is off the ladder too" do
      {team, user} = team_and_user()

      assert {:error, %Postgrex.Error{postgres: pg}} = raw_insert(team.id, user.id, "")
      assert pg.code == :check_violation
      assert pg.constraint == @constraint
    end
  end

  describe "the constraint stays QUIET for the real ladder" do
    test "every role in TeamMembership.roles() inserts through raw SQL" do
      for role <- TeamMembership.roles() do
        {team, user} = team_and_user()

        assert {:ok, %{num_rows: 1}} = raw_insert(team.id, user.id, role),
               "expected the database to accept the declared role #{inspect(role)}"

        assert Accounts.team_role(user, team) == role
      end
    end

    test "the changeset validation is STILL there — defence in depth, not a swap" do
      # Criterion 2: the constraint is the floor, not a replacement. An
      # off-ladder role must still be refused by Ecto BEFORE it reaches Postgres
      # — an Ecto.Changeset error, never a Postgrex.Error.
      {team, user} = team_and_user()

      assert {:error, %Ecto.Changeset{} = changeset} = Accounts.add_member(team, user, "bogus")
      assert "is invalid" in errors_on(changeset).role
    end
  end

  describe "DRIFT GUARD — the constraint and @roles are the same vocabulary" do
    test "pg_constraint's definition lists exactly TeamMembership.roles()" do
      %{rows: [[definition]]} =
        Repo.query!(
          """
          SELECT pg_get_constraintdef(oid)
            FROM pg_constraint
           WHERE conrelid = 'team_memberships'::regclass
             AND conname = $1
          """,
          [@constraint]
        )

      in_db =
        ~r/'([a-z-]+)'/
        |> Regex.scan(definition)
        |> Enum.map(fn [_, value] -> value end)
        |> MapSet.new()

      assert in_db == MapSet.new(TeamMembership.roles()),
             """
             #{@constraint} and TeamMembership.@roles have drifted.

             constraint: #{inspect(Enum.sort(in_db))}
             @roles:     #{inspect(Enum.sort(TeamMembership.roles()))}

             Widening @roles is only half the change — the database holds the
             other half. Cut a migration that drops and re-adds the constraint.
             """
    end

    test "the constraint is VALIDATED, not merely NOT VALID" do
      # A NOT VALID constraint guards new writes but certifies nothing about the
      # rows already there; the migration validates it, and a half-applied
      # migration would leave convalidated false.
      assert %{rows: [[true]]} =
               Repo.query!(
                 """
                 SELECT convalidated
                   FROM pg_constraint
                  WHERE conrelid = 'team_memberships'::regclass
                    AND conname = $1
                 """,
                 [@constraint]
               )
    end
  end
end
