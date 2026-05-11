defmodule Barkpark.Repo.Migrations.AddActionsToSchemaDefinitions do
  use Ecto.Migration

  def change do
    alter table(:schema_definitions) do
      add :actions, {:array, :map}, default: [], null: false
    end
  end
end
