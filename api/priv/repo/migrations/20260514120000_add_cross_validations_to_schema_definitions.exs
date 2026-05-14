defmodule Barkpark.Repo.Migrations.AddCrossValidationsToSchemaDefinitions do
  use Ecto.Migration

  def change do
    alter table(:schema_definitions) do
      add :cross_validations, {:array, :map}, default: [], null: false
    end
  end
end
