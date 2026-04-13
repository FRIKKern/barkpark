defmodule Barkpark.Repo.Migrations.CreateMutationEvents do
  use Ecto.Migration

  def change do
    create table(:mutation_events, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :dataset, :text, null: false
      add :type, :text, null: false
      add :doc_id, :text, null: false
      add :mutation, :text, null: false
      add :rev, :text, null: false
      add :previous_rev, :text
      add :document, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:mutation_events, [:dataset, :id])
  end
end
