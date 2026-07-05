defmodule Barkpark.Repo.Migrations.CreateOrganizations do
  @moduledoc """
  era-w1-org-admin-shell — a THIN Organization tier above Workspace.

  An Organization groups one or more Workspaces so a single enterprise identity
  connection (SSO/SCIM, later waves) maps to a customer that may span several
  workspaces. The tier is additive and behaviour-preserving: `workspaces
  .organization_id` is nullable and nothing reads it for authorization yet.
  Existing workspaces are back-filled to a `default` organization so the
  concept exists without changing any current behaviour. Deleting an
  organization NILIFIES its workspaces' `organization_id` — it never cascades
  into tenant data.
  """
  use Ecto.Migration

  def up do
    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :name, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:organizations, [:slug])

    alter table(:workspaces) do
      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:workspaces, [:organization_id])

    # Back-fill: a single default organization owns every existing workspace.
    execute """
    INSERT INTO organizations (id, slug, name, inserted_at, updated_at)
    VALUES (gen_random_uuid(), 'default', 'Default Organization', now(), now())
    """

    execute """
    UPDATE workspaces
    SET organization_id = (SELECT id FROM organizations WHERE slug = 'default')
    WHERE organization_id IS NULL
    """
  end

  def down do
    alter table(:workspaces) do
      remove :organization_id
    end

    drop table(:organizations)
  end
end
