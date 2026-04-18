defmodule Barkpark.Repo.Migrations.CreatePreviewTokenJti do
  use Ecto.Migration

  def change do
    create table(:preview_token_jti, primary_key: false) do
      add :jti, :string, primary_key: true, null: false
      add :token_id, :binary_id
      add :dataset, :string, null: false
      add :doc_ids, {:array, :string}, default: []
      add :issued_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
    end

    create index(:preview_token_jti, [:expires_at])
    create index(:preview_token_jti, [:dataset])
  end
end
