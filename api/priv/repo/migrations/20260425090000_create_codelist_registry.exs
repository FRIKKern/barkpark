defmodule Barkpark.Repo.Migrations.CreateCodelistRegistry do
  use Ecto.Migration

  def up do
    # Codelist headers — one row per (plugin, list_id, issue).
    # `plugin_name` is the explicit Decision-20 discriminator: two plugins
    # may register a list_id like "language" without collision.
    create table(:codelists, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :plugin_name, :string, null: false
      add :list_id, :string, null: false
      add :issue, :string, null: false
      add :name, :string
      add :description, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:codelists, [:plugin_name, :list_id, :issue])
    create index(:codelists, [:plugin_name])

    # Codelist values — entries within a codelist, optionally hierarchical
    # via `parent_id` (self-reference, e.g. Thema codelist 93 ~3000 nodes).
    create table(:codelist_values, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :codelist_id,
          references(:codelists, type: :binary_id, on_delete: :delete_all),
          null: false

      add :parent_id,
          references(:codelist_values, type: :binary_id, on_delete: :delete_all)

      add :code, :string, null: false
      add :position, :integer
      add :metadata, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:codelist_values, [:codelist_id])
    create index(:codelist_values, [:codelist_id, :parent_id])
    create unique_index(:codelist_values, [:codelist_id, :code])

    # Per-language labels for a codelist value.
    create table(:codelist_value_translations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :codelist_value_id,
          references(:codelist_values, type: :binary_id, on_delete: :delete_all),
          null: false

      add :language, :string, null: false
      add :label, :string, null: false
      add :description, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:codelist_value_translations, [:codelist_value_id, :language])
  end

  def down do
    # Drop in reverse FK order so dependent tables go first.
    drop table(:codelist_value_translations)
    drop table(:codelist_values)
    drop table(:codelists)
  end
end
