defmodule Barkpark.Repo.Migrations.AddInitialValuesToSchemaDefinitions do
  use Ecto.Migration

  def change do
    alter table(:schema_definitions) do
      add :initial_values, :map, default: %{}, null: false
    end
  end
end
