defmodule Barkpark.Repo.Migrations.MakeTaskSchemaPrivate do
  use Ecto.Migration

  # Owner ruling #10 (2026-10-03, task-771adf3d4bb86c69): the `task` schema is
  # private. `Tasks.Schema.task_schema/1` now declares it, but the boot upsert
  # only rewrites the Default slot's row, skips a pulled workspace's row, and
  # never touches the per-workspace copies `mix barkpark.workspace.provision_schemas`
  # made. This flips every stored `task` row that is still public. It is the
  # whole data change: one column, reversible by setting it back, nothing else
  # touched. An anonymous `GET /v1/data/query|doc/:ds/task…` then answers 404,
  # anonymous search and the Indx corpus leave tasks out, and every
  # credentialed reader (bp task, Studio, the board, the CI task gate's
  # BARKPARK_TASK_TOKEN) is unchanged.
  def up do
    execute("""
    UPDATE schema_definitions
    SET visibility = 'private', updated_at = now()
    WHERE name = 'task' AND visibility IS DISTINCT FROM 'private'
    """)
  end

  # Down does not re-publish the ledger: which rows were public before is not
  # recorded, and re-opening security rows to anonymous readers is the very
  # exposure this closes. Set a row back by hand if a workspace wants it.
  def down, do: :ok
end
