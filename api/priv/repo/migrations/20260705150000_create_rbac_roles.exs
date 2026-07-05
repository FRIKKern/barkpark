defmodule Barkpark.Repo.Migrations.CreateRbacRoles do
  @moduledoc """
  era-w1-custom-rbac (Stage A) — data-driven roles for USER principals.

  A `role` groups a set of granted actions (`role_permissions`). A NULL
  `workspace_id` is a GLOBAL built-in role (owner/admin/member), valid in every
  workspace; a non-NULL one is a custom role scoped to that workspace (e.g.
  "editor-no-publish"). The USER authorization path (`Tenancy.Auth.role_permits?`)
  resolves a membership role to its action set here. The API-TOKEN permission
  model is untouched.
  """
  use Ecto.Migration

  def change do
    create table(:roles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # NULL = global built-in; non-NULL = custom, scoped to that workspace.
      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all)

      add :name, :string, null: false
      add :built_in, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    # A name is unique per workspace.
    create unique_index(:roles, [:workspace_id, :name], name: :roles_workspace_name_idx)
    # And unique among the global built-ins (so no two rows claim global "admin").
    create unique_index(:roles, [:name],
             where: "workspace_id IS NULL",
             name: :roles_global_name_idx
           )

    create table(:role_permissions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :role_id, references(:roles, type: :binary_id, on_delete: :delete_all), null: false

      # A GRANTED ACTION for the USER path: "read" | "write" | "admin".
      add :action, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:role_permissions, [:role_id, :action],
             name: :role_permissions_role_action_idx
           )
  end
end
