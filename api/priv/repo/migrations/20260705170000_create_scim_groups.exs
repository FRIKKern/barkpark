defmodule Barkpark.Repo.Migrations.CreateScimGroups do
  @moduledoc """
  era-w4-scim-groups — SCIM 2.0 Groups. An IdP group maps to a Barkpark role
  (`role_name`); adding a user to the group grants that role in the
  organization's workspaces, removing them reverts it. Org-scoped like
  scim_tokens / scim Users.
  """
  use Ecto.Migration

  def change do
    create table(:scim_groups, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :display_name, :string, null: false
      # The Barkpark role this group grants (built-in or a custom role name).
      add :role_name, :string, null: false
      add :external_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scim_groups, [:organization_id, :display_name],
             name: :scim_groups_org_display_idx
           )

    create index(:scim_groups, [:organization_id])
  end
end
