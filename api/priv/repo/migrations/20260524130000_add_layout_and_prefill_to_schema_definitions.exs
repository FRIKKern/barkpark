defmodule Barkpark.Repo.Migrations.AddLayoutAndPrefillToSchemaDefinitions do
  use Ecto.Migration

  # Expectation layer (Exp-P1, barkpark-u7q5) — two ADDITIVE, SOFT columns on
  # schema_definitions. `layout` is an ordered list interleaving field-refs
  # with free-content region markers; `prefill` is the create-time scaffold
  # that evolves the flat `initial_values`. Both default empty so every
  # existing schema keeps a derived default Expectation with no data change.
  def change do
    alter table(:schema_definitions) do
      add :layout, {:array, :map}, default: [], null: false
      add :prefill, :map, default: %{}, null: false
    end
  end
end
