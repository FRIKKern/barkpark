defmodule Barkpark.Repo.Migrations.AddFieldVisibilityToSchemaDefinitions do
  use Ecto.Migration

  # Phase 3 (core-auth) — field visibility is DATA-ONLY. The new per-field
  # attributes (`private`, `visibility`, `readable_by`) live inline inside the
  # already-existing `schema_definitions.fields` JSON array; the parser supplies
  # safe defaults (`private: false`, `visibility: nil`, `readable_by: []`) for
  # any legacy row that lacks them. No column changes are required — this is an
  # intentional no-op kept only to preserve migration-sequence integrity.
  def change, do: :ok
end
