defmodule Barkpark.Repo.Migrations.CreateTenancyTables do
  use Ecto.Migration

  # Wave 1 tenancy foundation. Workspace = hard tenant boundary;
  # Project lives under a Workspace; Membership binds a principal (the API
  # token — there is NO users/accounts model) to a Workspace with a role.
  # No citext anywhere in this codebase, so slugs are plain text + unique
  # indexes (slug-format/reserved-word enforcement lives in the changesets).
  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :name, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspaces, [:slug])

    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :slug, :string, null: false
      add :name, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:workspace_id, :slug])

    create table(:workspace_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :principal_type, :string, null: false, default: "api_token"
      add :principal_id, :binary_id, null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :workspace_memberships,
             [:workspace_id, :principal_type, :principal_id],
             name: :workspace_memberships_principal_unique_idx
           )
  end
end
