defmodule SanityApi.Repo.Migrations.CreateInitialTables do
  use Ecto.Migration

  def change do
    # Documents — all content stored as JSONB
    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :doc_id, :string, null: false
      add :type, :string, null: false
      add :dataset, :string, null: false, default: "production"
      add :title, :string
      add :status, :string, default: "draft"
      add :content, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:documents, [:doc_id, :type, :dataset])
    create index(:documents, [:type, :dataset])
    create index(:documents, [:status])

    # Schema definitions — document types with visibility
    create table(:schema_definitions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :title, :string, null: false
      add :icon, :string
      add :visibility, :string, null: false, default: "public"
      add :fields, {:array, :map}, default: []
      add :dataset, :string, null: false, default: "production"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:schema_definitions, [:name, :dataset])

    # API tokens — authentication
    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :string, null: false
      add :label, :string
      add :dataset, :string, null: false, default: "production"
      add :permissions, {:array, :string}, default: ["read"]

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_tokens, [:token_hash])
  end
end
