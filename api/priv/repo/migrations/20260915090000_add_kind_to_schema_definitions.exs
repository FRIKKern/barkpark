defmodule Barkpark.Repo.Migrations.AddKindToSchemaDefinitions do
  use Ecto.Migration

  # Gyldendal parity E3.6 (task-5064727fdda5a5df): a schema definition can be
  # a DOCUMENT type (every row today) or a named OBJECT type — a composite
  # declared once per dataset and referenced by name as a field type from any
  # document schema (Sanity's reusable `seo` / `banner` object types). Object
  # types own no documents and never appear on the desk; they exist to be
  # inlined into the schemas that reference them.
  #
  # Additive: the column defaults to "document", so every existing row keeps
  # its meaning byte-identically. `down` drops only this column.
  #
  # `MANIFEST.sha256` is regenerated with this commit (migration_manifest_test).
  def up do
    alter table(:schema_definitions) do
      add :kind, :string, null: false, default: "document"
    end
  end

  def down do
    alter table(:schema_definitions) do
      remove :kind
    end
  end
end
