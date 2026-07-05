defmodule Barkpark.Repo.Migrations.CreateOidcConnections do
  @moduledoc """
  era-w3-oidc-rp — a per-Organization OIDC relying-party connection. Barkpark
  is the RP; the org's IdP is the OP. `client_secret` is encrypted at rest
  (Cloak / `Barkpark.EncryptedBinary`). One connection per org for now.
  """
  use Ecto.Migration

  def change do
    create table(:oidc_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :issuer, :string, null: false
      add :client_id, :string, null: false
      # Encrypted at rest.
      add :client_secret, :binary
      add :authorization_endpoint, :string, null: false
      add :token_endpoint, :string, null: false
      add :jwks_uri, :string, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oidc_connections, [:organization_id])
  end
end
