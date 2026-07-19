defmodule Barkpark.Repo.Migrations.ValidateTaskLifecycleStatusCheck do
  @moduledoc """
  Task-lifecycle-visibility — Migration B of two: validate the widened
  `documents_task_lifecycle_status_check` that the companion migration
  `WidenTaskLifecycleStatusCheckTo7` added with `NOT VALID`.

  `ALTER TABLE … VALIDATE CONSTRAINT` scans the table under
  `SHARE UPDATE EXCLUSIVE` — it does NOT block reads or writes, only other
  schema changes. Because the widening is monotonic (a strict superset of the
  previously-accepted values), every existing row already satisfies the new
  constraint, so this scan can never fail. Kept a SEPARATE migration from the
  DROP+ADD so the ADD's `ACCESS EXCLUSIVE` lock is released before this scan.

  `down/0` is a no-op: a constraint that is merely validated has no distinct
  "unvalidated" state to restore, and dropping/re-adding lives in Migration A.
  """

  use Ecto.Migration

  def up do
    execute "ALTER TABLE documents VALIDATE CONSTRAINT documents_task_lifecycle_status_check"
  end

  def down, do: :ok
end
