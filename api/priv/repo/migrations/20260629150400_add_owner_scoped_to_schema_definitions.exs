defmodule Barkpark.Repo.Migrations.AddOwnerScopedToSchemaDefinitions do
  use Ecto.Migration

  # Phase 4 (core-auth) — row/ownership ACL opt-in flag. A schema with
  # `owner_scoped: true` restricts non-admin USER reads to their own rows plus
  # unowned (NULL owner_id) rows; admins and api-tokens still see all. ADDITIVE:
  # the column defaults to `false` and is NOT NULL, so every existing schema is
  # non-owner_scoped → byte-identical to today. Unlike the per-field visibility
  # metadata (Phase 3, which lives inline in the `fields` JSON), `owner_scoped`
  # is a WHOLE-SCHEMA attribute read on the row read/write paths, so it earns a
  # first-class column rather than a JSON sub-key.
  def change do
    alter table(:schema_definitions) do
      add :owner_scoped, :boolean, null: false, default: false
    end
  end
end
