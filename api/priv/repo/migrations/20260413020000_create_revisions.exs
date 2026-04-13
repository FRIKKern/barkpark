defmodule Barkpark.Repo.Migrations.CreateRevisions do
  use Ecto.Migration

  def change do
    create table(:revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :doc_id, :string, null: false
      add :type, :string, null: false
      add :dataset, :string, null: false, default: "production"
      add :title, :string
      add :status, :string
      add :content, :map
      add :action, :string, null: false  # "create", "update", "publish", "unpublish", "delete"

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:revisions, [:doc_id, :type, :dataset])
    create index(:revisions, [:inserted_at])
  end
end
