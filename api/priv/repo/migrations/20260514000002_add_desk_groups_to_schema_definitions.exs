defmodule Barkpark.Repo.Migrations.AddDeskGroupsToSchemaDefinitions do
  use Ecto.Migration

  def change do
    alter table(:schema_definitions) do
      add :desk_groups, {:array, :map}, default: [], null: false
    end
  end
end
