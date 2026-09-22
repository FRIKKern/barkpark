defmodule BarkparkCloud.OffLadderRole do
  @moduledoc """
  Seat a `team_memberships.role` the ladder has never ranked, for the census
  tests whose whole subject is what happens when one arrives.

  ## Why this needs a helper at all

  `team_memberships_role_check` (migration 20260918120000) closed the role
  vocabulary IN THE DATABASE, so an `update_all` can no longer write
  `"superadmin"` — which is exactly the point of that constraint.

  The off-ladder cohort is still load-bearing, and for two reasons the
  constraint does not retire it:

    * the memberships already in cloud-db-1 were written with no constraint at
      all, and `Authz`/`TeamMembership` read whatever the column holds;
    * the constraint is a `CHECK`, not a law of physics — a future migration
      widens `@roles`, a superuser drops it, a restore predates it. Charter
      D493 rules that an unrankable role ranks 0 (`Map.get(@ranks, role, 0)`),
      and the tests that prove BOTH `team_admin?` encodings agree on such a
      role are the thing that keeps that ruling honest.

  So the off-ladder tests keep asserting the behaviour, and this helper is how
  they reach the shape the database now refuses. It mirrors
  `BarkparkCloud.UnknownDeploymentStatus`, which solved the same problem for
  `deployments_status_check`.

  ## Why dropping the constraint is safe HERE

  The `DROP CONSTRAINT` runs inside the test's own Ecto Sandbox transaction,
  and Postgres DDL is transactional: the sandbox rollback at the end of the
  test restores it with no explicit re-add. Its callers are `async: false`
  suites, which ExUnit runs serially and only after every async suite has
  finished, so the ACCESS EXCLUSIVE lock this takes on `team_memberships`
  cannot stall a concurrent test.

  Do NOT reach for this to make an ordinary fixture compile. A test that trips
  the constraint by accident has found a fixture writing a role the application
  cannot write — repair the fixture, not the schema.
  """

  alias BarkparkCloud.Repo

  @constraint "team_memberships_role_check"

  @doc """
  Runs `fun` with the `team_memberships.role` CHECK constraint dropped.

  The drop is scoped to the caller's sandbox transaction; nothing is restored by
  hand because nothing outside that transaction ever saw it go.

  `IF EXISTS` is load-bearing, not defensive: ARM C of the role census calls
  this once PER off-ladder role inside a single test, so the second call would
  hit an already-dropped constraint. The existence of the constraint is proved
  where it belongs — the drift arm of
  `BarkparkCloud.Accounts.TeamMembershipRoleConstraintTest` — and every caller
  here asserts the off-ladder write actually LANDED, so a no-op drop cannot make
  a caller vacuous.
  """
  @spec without_role_constraint((-> result)) :: result when result: term()
  def without_role_constraint(fun) when is_function(fun, 0) do
    Repo.query!("ALTER TABLE team_memberships DROP CONSTRAINT IF EXISTS #{@constraint}")
    fun.()
  end
end
