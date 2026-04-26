defmodule Barkpark.Repo.Migrations.CreatePluginDocState do
  use Ecto.Migration

  def change do
    create table(:plugin_doc_state, primary_key: false) do
      add :plugin_name, :string, null: false, primary_key: true
      add :doc_id, references(:documents, type: :binary_id, on_delete: :delete_all), null: false, primary_key: true
      add :key, :string, null: false, primary_key: true
      add :value, :map, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:plugin_doc_state, [:doc_id])
  end
end
