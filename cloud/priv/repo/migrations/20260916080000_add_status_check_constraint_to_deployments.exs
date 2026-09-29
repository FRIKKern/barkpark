defmodule BarkparkCloud.Repo.Migrations.AddStatusCheckConstraintToDeployments do
  @moduledoc """
  deploy-reliability W16 backlog: THE DATABASE LEARNS THE STATUS VOCABULARY.

  ## The defect

  `deployments.status` was `character varying(255) NOT NULL DEFAULT 'queued'`
  with no CHECK and no enum — `select count(*) from pg_constraint where
  conrelid = 'deployments'::regclass and contype = 'c'` answered zero, and no
  migration in this tree ever declared one. The vocabulary lived ONLY in the
  application: `BarkparkCloud.Registry.Deployment`'s `@statuses` module
  attribute (grep: `grep -n '@statuses'
  cloud/lib/barkpark_cloud/registry/deployment.ex`) enforced through
  `validate_inclusion(:status, @statuses)` on the changesets.

  A changeset is not a constraint. `status` is not even in the create
  changeset's cast list, so it moves through explicit writer paths — and
  anything that writes the column without going through one of those
  changesets (an `update_all`, an `insert_all`, a repair script, a psql
  session, a future writer that forgets) can seat a word the vocabulary has
  never seen.

  ## Why that is worse than an odd string in a column

  `BarkparkCloud.DeployLedger.classify/1` (grep: `grep -n 'def classify(%{status'
  cloud/lib/barkpark_cloud/deploy_ledger.ex`) matches `failed` and `deferred`
  and ends in a catch-all that answers `nil`. `nil` there means "this row did
  not fail" — the SAME answer a successful `live` deploy gets. So an unknown
  status does not arrive as a loud unknown; it arrives as a silent success, and
  every failure numerator built on `classify/1` shrinks by exactly the rows
  nobody can name. The census's `residual` line makes such a row VISIBLE after
  the fact; it cannot PREVENT it.

  The honest place for a closed vocabulary is the schema that stores it.

  ## Two statements, because this is a live 31k-row table

  `ADD CONSTRAINT … CHECK (…) NOT VALID` is a CATALOG-ONLY write: Postgres
  takes ACCESS EXCLUSIVE for the catalog update and does NOT scan the table, so
  the lock is held for microseconds rather than for a scan of every deployment
  ever made. From that instant forward every INSERT and UPDATE is checked —
  which is the half that actually closes the defect.

  `VALIDATE CONSTRAINT` then scans the existing rows under SHARE UPDATE
  EXCLUSIVE, which does not block reads or writes. Splitting it this way is the
  difference between a deploy that pauses the fleet and one that does not.

  ## The precheck, and what a failure here MEANS

  Before validating, this migration counts the rows whose status is outside the
  vocabulary and RAISES with the offending values and their counts if there are
  any. That is deliberate: a bare `VALIDATE` failure reports a constraint name
  and nothing about the data, and the very first question an operator has is
  "which word, and how many rows". A red here is not a broken migration — it is
  the finding this row was filed to surface, delivered with its evidence.

  Recovery is an owner decision (reclassify the rows, or widen `@statuses` and
  re-cut this constraint), never an automatic one, so nothing here repairs data.

  ## The vocabulary is DUPLICATED here on purpose

  A migration is a historical record: it must keep meaning what it meant on the
  day it ran, so it cannot read `Deployment.statuses()` at run time — a later
  edit to that list would retroactively change what this file did. The two
  lists are kept honest by a test instead
  (`cloud/test/barkpark_cloud/registry/deployment_status_constraint_test.exs`),
  which reads the constraint out of `pg_constraint` and compares it against
  `Deployment.statuses()`: adding a status to the module attribute without
  cutting a follow-up migration reds that test.
  """

  use Ecto.Migration

  @disable_ddl_transaction true

  # BarkparkCloud.Registry.Deployment's @statuses as of this migration.
  @statuses ~w(queued building pushing live failed cancelled deferred)

  @constraint "deployments_status_check"

  def up do
    values = Enum.map_join(@statuses, ", ", &"'#{&1}'")

    execute("""
    ALTER TABLE deployments
      ADD CONSTRAINT #{@constraint}
      CHECK (status IN (#{values}))
      NOT VALID
    """)

    # flush/0 IS LOAD-BEARING. Ecto's migration runner QUEUES `execute/1` and
    # flushes at the end of the function, so without this the precheck below
    # would run BEFORE the constraint existed — and a raise would then abort the
    # migration having added nothing, leaving new writes unguarded while the
    # owner investigates. Flushing here makes the NOT VALID constraint real
    # before anything can raise.
    flush()

    precheck(values)

    execute("ALTER TABLE deployments VALIDATE CONSTRAINT #{@constraint}")
  end

  def down do
    execute("ALTER TABLE deployments DROP CONSTRAINT IF EXISTS #{@constraint}")
  end

  # Name the offenders before Postgres refuses to name them.
  defp precheck(values) do
    %{rows: rows} =
      repo().query!("""
      SELECT status, count(*)
        FROM deployments
       WHERE status NOT IN (#{values})
       GROUP BY status
       ORDER BY count(*) DESC
      """)

    if rows != [] do
      offenders = Enum.map_join(rows, ", ", fn [status, n] -> "#{inspect(status)}=#{n}" end)

      # Leave the NOT VALID constraint in place: it is already guarding new
      # writes, and dropping it would re-open the hole while the owner decides.
      raise """
      deployments.status holds values outside the Deployment @statuses vocabulary: #{offenders}

      The CHECK constraint #{@constraint} has been added NOT VALID (new writes are
      already refused). VALIDATE was NOT attempted. Decide whether these rows are
      mislabelled (reclassify them) or whether the vocabulary is wrong (widen
      @statuses and cut a follow-up migration), then run:

        ALTER TABLE deployments VALIDATE CONSTRAINT #{@constraint};
      """
    end
  end
end
