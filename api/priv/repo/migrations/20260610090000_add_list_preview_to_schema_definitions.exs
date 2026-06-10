defmodule Barkpark.Repo.Migrations.AddListPreviewToSchemaDefinitions do
  @moduledoc """
  Generic list-row preview metadata on schema definitions.

  `list_preview` lets a schema (host seed OR plugin-declared) name 1–2
  content fields the Studio list panes render per row — a right-aligned
  badge plus a dimmed suffix — consumed generically by
  `BarkparkWeb.Studio.PaneBuilder` for EVERY document type. Shape:

      %{"badge" => "lifecycle_status",
        "meta"  => %{"field" => "priority", "prefix" => "P"}}

  Each slot is a content-field name (string) or a map with `"field"` +
  optional `"prefix"`. Empty map (the default) → rows render exactly as
  before. Mirrors the `desk_groups` precedent: schema-level data,
  host-level generic consumption — no type-specific branches in the
  render path.
  """
  use Ecto.Migration

  def change do
    alter table(:schema_definitions) do
      add :list_preview, :map, default: %{}, null: false
    end
  end
end
