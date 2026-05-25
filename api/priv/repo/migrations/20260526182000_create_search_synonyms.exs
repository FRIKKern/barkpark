defmodule Barkpark.Repo.Migrations.CreateSearchSynonyms do
  use Ecto.Migration

  def change do
    create table(:search_synonyms, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :surface, :text, null: false
      add :scope, :text, null: false
      add :from_query, :text, null: false
      add :to_query, :text, null: false
      add :kind, :text, null: false, default: "one_way"
      add :source, :text, null: false, default: "manual"
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :search_synonyms,
             [:surface, :scope, :from_query, :to_query, :kind],
             name: :search_synonyms_unique_idx
           )

    create index(:search_synonyms, [:surface, :scope, :enabled])
  end
end
