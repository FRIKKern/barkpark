defmodule Barkpark.Repo.Migrations.CreateWebauthnCredentials do
  use Ecto.Migration

  # A registered WebAuthn/passkey credential for a user. `credential_id` is the
  # raw authenticator credential handle (unique); `cose_key` is the stored
  # public key (term-encoded COSE map) used to verify future assertions;
  # `sign_count` is the authenticator's monotonic counter for clone detection.
  def change do
    create table(:webauthn_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :credential_id, :binary, null: false
      add :cose_key, :binary, null: false
      add :sign_count, :bigint, null: false, default: 0
      add :nickname, :string
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webauthn_credentials, [:credential_id])
    create index(:webauthn_credentials, [:user_id])
  end
end
