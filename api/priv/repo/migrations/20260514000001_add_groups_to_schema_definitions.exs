defmodule Barkpark.Repo.Migrations.AddGroupsToSchemaDefinitions do
  use Ecto.Migration

  def change do
    alter table(:schema_definitions) do
      add :groups, {:array, :map}, default: [], null: false
    end
  end
end
