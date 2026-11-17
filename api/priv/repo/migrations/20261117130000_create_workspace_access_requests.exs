defmodule Barkpark.Repo.Migrations.CreateWorkspaceAccessRequests do
  @moduledoc """
  task-1b99ba8512bb758e: a signed-in user with no seat in a workspace asks for
  one, and a workspace admin approves (the seat is created through
  `Tenancy.Members.add_user_member/4`) or denies.

  `workspace_slug` is what the user sent. `workspace_id` is NULL when no
  workspace has that slug, so the asker's answer and list look the same
  whether the workspace exists or not, and no admin ever sees the row.

  Additive only: a new table, no change to any existing row.
  """
  use Ecto.Migration

  def change do
    create table(:workspace_access_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :workspace_slug, :string, null: false
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
      add :note, :text
      # pending | approved | denied
      add :status, :string, null: false, default: "pending"
      # The role the seat was created with, set on approve.
      add :role, :string
      # "api_token:<id>" or "user:<id>" of the admin who decided.
      add :decided_by, :string
      add :decided_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # At most one pending request per user per workspace slug.
    create unique_index(:workspace_access_requests, [:user_id, :workspace_slug],
             where: "status = 'pending'",
             name: :workspace_access_requests_one_pending_idx
           )

    create index(:workspace_access_requests, [:workspace_id, :status])
    create index(:workspace_access_requests, [:user_id])
  end
end
