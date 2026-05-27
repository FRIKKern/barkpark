defmodule Barkpark.Repo.Migrations.W7aTaskSchema do
  @moduledoc """
  W7a step 1 — defense-in-depth check constraint for task lifecycle_status.

  ## Status-axis choice (b): `content.lifecycle_status`

  The W7 plan (§1, "Status widening") offered two options for storing the
  task lifecycle (`open / in_progress / blocked / done / cancelled`):

    (a) Widen the existing `documents.status` enum and use the new values
        only for `type='task'` rows.
    (b) Keep `documents.status` as-is (Sanity draft/published axis) and
        store task lifecycle in `content.lifecycle_status` (jsonb).

  This migration commits to **(b)** — see the moduledoc on
  `Barkpark.Tasks` for the full rationale. The headline: `documents.status`
  already mixes two orthogonal axes (Sanity draft/published + project-type
  active/planning/completed); adding a third would force every reader
  pattern-matching on `status` to know which axis applies. The lifecycle
  axis owns its own field and the draft/published axis stays unchanged on
  the same row.

  The authoritative validation lives in `Barkpark.Tasks.validate_task_content/1`
  and is invoked by `Content.create_document/4` + `Content.upsert_document/4`
  before the DB write. This migration adds a **defense-in-depth** CHECK
  constraint so a write that bypasses the application validator (a raw
  `Repo.insert` from a hot console, a migration backfill that forgets the
  validator, etc.) still cannot land a `type='task'` row with a malformed
  `lifecycle_status`.

  ## Constraint shape

      documents_task_lifecycle_status_check:
        type <> 'task'
        OR content ? 'lifecycle_status' = false
        OR content->>'lifecycle_status' IN
             ('open','in_progress','blocked','done','cancelled')

  Three branches:

    * non-task rows are unconstrained (the existing post/page/paper flow
      keeps working unchanged);
    * task rows whose `content` does NOT yet carry `lifecycle_status` are
      allowed (so an early-life task row stamped before the field is set —
      e.g. the importer in W7-d — can still land; the validator catches
      the missing field at the application boundary);
    * task rows that DO carry `lifecycle_status` must use one of the five
      string values from `Barkpark.Tasks.lifecycle_statuses/0`.

  Reversible: `down/0` drops the constraint cleanly.
  """

  use Ecto.Migration

  @constraint_name :documents_task_lifecycle_status_check

  def up do
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

  def down do
    drop constraint(:documents, @constraint_name)
  end
end
