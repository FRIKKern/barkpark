defmodule BarkparkCloud.Repo.Migrations.AddRoleCheckConstraintToTeamMemberships do
  @moduledoc """
  cch-w44: THE ROLE LADDER GETS A FLOOR BELOW ECTO.

  ## The defect (measured)

  `create_team_memberships` declares `add :role, :string, null: false` and
  nothing else: a grep for `check_constraint` / `CHECK (` across ALL of
  `cloud/priv/repo/migrations` returned NOTHING. The only thing keeping the
  ladder honest was `BarkparkCloud.Accounts.TeamMembership.changeset/2`'s
  `validate_inclusion(:role, @roles)`.

  A changeset is not a constraint. Anything that reaches the column another
  way — an `update_all`, an `insert_all`, a repair script, a psql session —
  seats a word the ladder has never ranked.

  ## Severity, stated honestly

  LOW, and deliberately so. `grep -rn "insert_all|update_all" cloud/lib | grep
  -i member` is EMPTY: there is no changeset-bypassing membership write
  anywhere in the application, so an off-ladder role is reachable only by
  direct SQL. This is defence in depth, not a live user-reachable defect.

  ## What an off-ladder role DOES, if one is ever seated

  `TeamMembership.rank/1` is `Map.get(@ranks, role, 0)` — an unrankable role
  ranks 0, BELOW every real role. That is the ratified behaviour (charter
  D493) and this migration does NOT change it: the console's comparator still
  mirrors it verbatim. The constraint only removes the STATE that makes the
  question askable.

  ## Two statements, matching `deployments_status_check`

  `ADD CONSTRAINT … NOT VALID` is a catalog-only write — ACCESS EXCLUSIVE for
  microseconds, no table scan — and from that instant every INSERT and UPDATE
  is checked, which is the half that closes the defect. `VALIDATE CONSTRAINT`
  then scans existing rows under SHARE UPDATE EXCLUSIVE, blocking neither
  reads nor writes.

  ## The pre-flight, and what a red here MEANS

  Before validating, this migration COUNTS the rows whose role is outside the
  vocabulary and raises with the offending values and their counts. A bare
  `VALIDATE` failure names a constraint and says nothing about the data; the
  first question an operator has is "which word, and how many rows". A red
  here is a finding delivered with its evidence, not a broken migration.
  Recovery is an owner decision (reclassify, or widen `@roles` and cut a
  follow-up migration) — nothing here repairs data.

  ## The vocabulary is DUPLICATED here on purpose, and LOCKED by a test

  A migration is a historical record: it must keep meaning what it meant on
  the day it ran, so it cannot call `TeamMembership.roles()` at migrate time —
  a later edit to that list would retroactively change what this file did.
  The two lists are kept honest by
  `cloud/test/barkpark_cloud/accounts/team_membership_role_constraint_test.exs`,
  which reads the constraint definition out of `pg_constraint` and compares it
  against `TeamMembership.roles()`. Adding a role to the module attribute
  without cutting a follow-up migration reds that test. A hand-copied list
  with no lock is an unlocked mirror; this one is locked.
  """

  use Ecto.Migration

  @disable_ddl_transaction true

  # BarkparkCloud.Accounts.TeamMembership's @roles as of this migration.
  @roles ~w(owner admin member)

  @constraint "team_memberships_role_check"

  def up do
    values = Enum.map_join(@roles, ", ", &"'#{&1}'")

    execute("""
    ALTER TABLE team_memberships
      ADD CONSTRAINT #{@constraint}
      CHECK (role IN (#{values}))
      NOT VALID
    """)

    # flush/0 IS LOAD-BEARING. Ecto QUEUES `execute/1` and flushes at the end of
    # the function, so without this the pre-flight below would run BEFORE the
    # constraint existed — and a raise would then abort having added nothing,
    # leaving new writes unguarded while the owner investigates.
    flush()

    preflight(values)

    execute("ALTER TABLE team_memberships VALIDATE CONSTRAINT #{@constraint}")
  end

  def down do
    execute("ALTER TABLE team_memberships DROP CONSTRAINT IF EXISTS #{@constraint}")
  end

  # Name the offenders before Postgres refuses to name them.
  defp preflight(values) do
    %{rows: rows} =
      repo().query!("""
      SELECT role, count(*)
        FROM team_memberships
       WHERE role NOT IN (#{values})
       GROUP BY role
       ORDER BY count(*) DESC
      """)

    if rows != [] do
      offenders = Enum.map_join(rows, ", ", fn [role, n] -> "#{inspect(role)}=#{n}" end)

      # Leave the NOT VALID constraint in place: it is already guarding new
      # writes, and dropping it would re-open the hole while the owner decides.
      raise """
      team_memberships.role holds values outside the TeamMembership @roles ladder: #{offenders}

      The CHECK constraint #{@constraint} has been added NOT VALID (new writes are
      already refused). VALIDATE was NOT attempted. Decide whether these rows are
      mislabelled (reclassify them) or whether the ladder is wrong (widen @roles
      and cut a follow-up migration), then run:

        ALTER TABLE team_memberships VALIDATE CONSTRAINT #{@constraint};
      """
    end
  end
end
