defmodule Barkpark.Repo.Migrations.CreateSearchSurfaceConfig do
  use Ecto.Migration

  def change do
    create table(:search_surface_config, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :surface, :text, null: false
      add :scope, :text, null: false
      add :searchable_fields, {:array, :map}, null: false, default: []
      add :typo_policy, :map, null: false, default: %{}
      add :zero_hit_strategy, :text, null: false, default: "drop_tokens"
      add :highlight_fields, {:array, :text}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:search_surface_config, [:surface, :scope],
             name: :search_surface_config_surface_scope_idx
           )
  end
end
