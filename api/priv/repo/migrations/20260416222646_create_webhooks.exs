defmodule Barkpark.Repo.Migrations.CreateWebhooks do
  use Ecto.Migration

  def change do
    create table(:webhooks, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :url, :string, null: false
      add :dataset, :string, null: false, default: "production"
      add :events, {:array, :string}, null: false, default: []
      add :types, {:array, :string}, null: false, default: []
      add :secret, :string
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:webhooks, [:dataset])
    create index(:webhooks, [:active])
  end
end
