defmodule Barkpark.Repo.Migrations.AddDeskToSchemaDefinitions do
  use Ecto.Migration

  # Gyldendal parity stage E3.1 — the schema-level `desk` block. Today it holds
  # `orderings` (Sanity's `orderings`: [{field, direction}]) that the Studio
  # desk list applies; later slices add `hidden` and `section`. ADDITIVE, NOT
  # NULL with `default: %{}`, so every existing schema starts with no desk
  # declaration and renders byte-identically.
  def change do
    alter table(:schema_definitions) do
      add :desk, :map, default: %{}, null: false
    end
  end
end
