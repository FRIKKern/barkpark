defmodule BarkparkCloud.Repo.Migrations.AddUpdateLastFailureToBarkparks do
  @moduledoc """
  The box's last failed self-update, mirrored from `GET /v1/admin/self-update`
  (`failure`: phase, how the phase was derived, exit code, a redacted log tail
  of at most 40 lines, and when the run finished). Lets an operator read WHY an
  update failed — build or migrate — in `bp cloud status` without SSH.

  ADDITIVE ONLY: one nullable jsonb column. NULL means "no failed run on file"
  (never measured, or the last run did not fail), so no backfill is needed.
  """
  use Ecto.Migration

  def change do
    alter table(:barkparks) do
      add :update_last_failure, :map, null: true
    end
  end
end
