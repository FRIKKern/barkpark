defmodule Barkpark.Repo.Migrations.CreateSsoFlows do
  use Ecto.Migration

  # One row per started OIDC or social sign-in, keyed by a hash of its state.
  # The callback takes the row once; a row lives 10 minutes. Two starts in one
  # browser no longer overwrite each other's state.
  def change do
    create table(:sso_flows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :state_hash, :binary, null: false
      add :provider, :string, null: false
      add :nonce, :string
      add :code_verifier, :binary
      add :studio, :map
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:sso_flows, [:state_hash])
    create index(:sso_flows, [:expires_at])
  end
end
