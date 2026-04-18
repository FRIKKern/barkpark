defmodule Barkpark.Repo.Migrations.CreateIdempotencyKeys do
  use Ecto.Migration

  def change do
    create table(:idempotency_keys, primary_key: false) do
      add :key_hash, :string, primary_key: true, null: false
      add :scope, :string, null: false
      add :status_code, :integer, null: false
      add :response_body, :text, null: false
      add :response_headers, :map, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:idempotency_keys, [:inserted_at])
  end
end
