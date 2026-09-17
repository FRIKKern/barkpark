defmodule BarkparkCloud.UnknownDeploymentStatus do
  @moduledoc """
  Seat a `deployments.status` the vocabulary has never seen, for the census
  tests whose whole subject is what happens when one arrives.

  ## Why this needs a helper at all

  `deployments_status_check` (migration 20260916080000) closed the status
  vocabulary IN THE DATABASE, so `Repo.insert!` can no longer write
  `"quarantined"` — which is exactly the point of that constraint.

  The census's `residual` cohort is still load-bearing, and for two reasons the
  constraint does not retire:

    * the 31k rows already on cloud-db-1 were written with no constraint at all,
      and the ledger reads the historical corpus, not just new writes;
    * the constraint is a `CHECK`, not a law of physics — a future migration
      widens `@statuses`, a superuser drops it, a restore predates it. A census
      that folds an unnamed status into `live` would then be silently wrong, and
      `residual` is the thing that refuses to be.

  So the residue tests keep asserting the behaviour, and this helper is how they
  reach the shape the database now refuses.

  ## Why dropping the constraint is safe HERE

  The `DROP CONSTRAINT` runs inside the test's own Ecto Sandbox transaction, and
  Postgres DDL is transactional: the sandbox rollback at the end of the test
  restores it with no explicit re-add. Its callers are `async: false` suites,
  which ExUnit runs serially and only after every async suite has finished, so
  the ACCESS EXCLUSIVE lock this takes on `deployments` cannot stall a
  concurrent test.

  Do NOT reach for this to make an ordinary fixture compile. A test that trips
  the constraint by accident has found a fixture writing a status the
  application cannot write — repair the fixture, not the schema.
  """

  alias BarkparkCloud.Repo

  @constraint "deployments_status_check"

  @doc """
  Runs `fun` with the `deployments.status` CHECK constraint dropped.

  The drop is scoped to the caller's sandbox transaction; nothing is restored by
  hand because nothing outside that transaction ever saw it go.
  """
  @spec without_status_constraint((-> result)) :: result when result: term()
  def without_status_constraint(fun) when is_function(fun, 0) do
    Repo.query!("ALTER TABLE deployments DROP CONSTRAINT #{@constraint}")
    fun.()
  end
end
