defmodule Barkpark.Repo.Migrations.WidenTaskLifecycleStatusCheckTo7 do
  @moduledoc """
  Task-lifecycle-visibility — widen the defense-in-depth
  `documents_task_lifecycle_status_check` from 5 to 7 values, adding the two
  thought states `considering` and `researching`.

  ## Migration A of two (never combined)

  This is the DROP+ADD half. The companion migration
  `ValidateTaskLifecycleStatusCheck` (a SEPARATE migration, so a SEPARATE
  transaction) runs `ALTER TABLE documents VALIDATE CONSTRAINT …` afterwards.

  Why two migrations: combining DROP+ADD+VALIDATE in one transaction would hold
  the ADD's `ACCESS EXCLUSIVE` lock through the full-table validation scan. By
  adding the widened constraint with `validate: false` (Postgres `NOT VALID` —
  metadata-only, no scan, no table lock beyond the brief catalog update) and
  validating in a later migration (`SHARE UPDATE EXCLUSIVE`, non-blocking), the
  widening never blocks concurrent writers. The widening is monotonic (a strict
  superset of the accepted values), so the later VALIDATE can never fail.

  The 5→7 enum truth lives in `Barkpark.Tasks.lifecycle_statuses/0`; this
  constraint is the DB-layer defense-in-depth mirror. "OPEN MEANS READY" is
  unaffected — the DB does not gate claimability, the ready/claim allowlist does.

  Reversible: `down/0` restores the original 5-value constraint (validated —
  the narrowing back would need every considering/researching row gone first,
  which is the caller's responsibility on a real downgrade).
  """

  use Ecto.Migration

  @constraint_name :documents_task_lifecycle_status_check

  def up do
    drop constraint(:documents, @constraint_name)

    create constraint(
             :documents,
             @constraint_name,
             check: """
             type <> 'task'
             OR NOT (content ? 'lifecycle_status')
             OR content->>'lifecycle_status' IN ('open','in_progress','blocked','done','cancelled','considering','researching')
             """,
             validate: false
           )
  end

  def down do
    drop constraint(:documents, @constraint_name)

    create constraint(
             :documents,
             @constraint_name,
             check: """
             type <> 'task'
             OR NOT (content ? 'lifecycle_status')
             OR content->>'lifecycle_status' IN ('open','in_progress','blocked','done','cancelled')
             """
           )
  end
end
