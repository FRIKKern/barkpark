defmodule Barkpark.Repo.Migrations.AddFieldsetsToSchemaDefinitions do
  use Ecto.Migration

  # A schema's top-level `fieldsets` (`[{name, title, options}]`, Sanity's
  # shape) had no column, so cast dropped them on write (task-344d5275adc4270c).
  def change do
    alter table(:schema_definitions) do
      add :fieldsets, {:array, :map}, default: [], null: false
    end
  end
end
