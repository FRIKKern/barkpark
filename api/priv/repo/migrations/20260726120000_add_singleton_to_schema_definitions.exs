defmodule Barkpark.Repo.Migrations.AddSingletonToSchemaDefinitions do
  use Ecto.Migration

  # Desk-placement opt-in (issue #8463). `Barkpark.Structure.build_settings_group/2`
  # used to treat EVERY private, non-plugin-owned schema as a siteSettings-style
  # singleton — a desk node whose pane looks up a document whose id equals the
  # type name. Fine for the handful of real host config objects (siteSettings,
  # navigation, colors); silently dead for a consumer-registered content type
  # with N real documents (the pane opens and finds nothing).
  #
  # `singleton: true` is now the explicit opt-IN for the old behavior; the
  # unmarked (default `false`) case gets a generic `:document_type_list` node
  # instead — see `Structure.build_generic_types_group/2`. ADDITIVE + NOT NULL
  # with `default: false`, so every existing schema starts non-singleton →
  # byte-identical to a *fixed* desk, not to the old broken one. The three real
  # host singletons are flipped back to `true` by the companion backfill
  # migration (`20260726130000_backfill_singleton_for_host_settings_types.exs`)
  # so upgrading an existing instance keeps its Settings pane exactly as it was.
  def change do
    alter table(:schema_definitions) do
      add :singleton, :boolean, null: false, default: false
    end
  end
end
