defmodule Barkpark.Repo.Migrations.CreateWorkspaceInvitations do
  @moduledoc """
  OWNER RULING 2026-10-03 #7 (task-a08da65bc33083d0): seating an EXISTING
  user in a workspace becomes an invitation the user accepts. A pending
  invitation lives in its own table, NOT as a flagged membership row, so no
  reader of `workspace_memberships` can mistake a pending seat for a real one.

  Additive only: a new table, no change to any existing row.
  """
  use Ecto.Migration

  def change do
    create table(:workspace_invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false
      # Who invited: "api_token:<id>" or "user:<id>". Informational only.
      add :invited_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspace_invitations, [:workspace_id, :user_id])
    create index(:workspace_invitations, [:user_id])
  end
end
