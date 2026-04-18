defmodule Barkpark.Repo.Migrations.AddCorsOriginsToSchemaDefinitions do
  use Ecto.Migration

  def change do
    alter table(:schema_definitions) do
      add :cors_origins, {:array, :text}, default: [], null: false
    end
  end
end
