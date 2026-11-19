defmodule Barkpark.Repo.Migrations.AddRequestedRoleToWorkspaceAccessRequests do
  @moduledoc """
  task-018e79d8734a1b08: a member may ask for a higher role.

  `requested_role` is the role the asker named (nullable: a seat request may
  name none). `from_role` is the role the asker held when they asked; it is
  set only for a member's request, so a non-NULL `from_role` is what marks a
  request as a role change. Approve refuses it when the seat's role is no
  longer `from_role`.

  Additive only: two nullable columns, no change to any existing row.
  """
  use Ecto.Migration

  # `MANIFEST.sha256` is regenerated with this commit (migration_manifest_test).

  def change do
    alter table(:workspace_access_requests) do
      add :requested_role, :string
      add :from_role, :string
    end
  end
end
