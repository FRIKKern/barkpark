defmodule Barkpark.Repo.Migrations.CreateSecrets do
  use Ecto.Migration

  # Cloud run-secrets — a GENERAL encrypted-at-rest KV store keyed by `name`,
  # mirroring `plugin_settings` (single-value column via `Barkpark.EncryptedBinary`
  # rather than a JSON map). The ingest token is the first consumer (DB row
  # `name = "ingest_token"`), but the table is consumer-agnostic.
  def change do
    create table(:secrets, primary_key: false) do
      add :name, :string, primary_key: true, null: false
      add :value, :binary, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :updated_by, :string
    end

    create table(:secrets_audit) do
      add :name, :string, null: false
      add :action, :string, null: false
      add :actor, :string
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:secrets_audit, [:name, :inserted_at])
  end
end
