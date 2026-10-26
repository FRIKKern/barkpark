defmodule Barkpark.Repo.Migrations.AddOidcConnectionEntraFields do
  use Ecto.Migration

  # Per-connection OIDC settings for Entra ID. The defaults keep every existing
  # connection behaving as before: the same scope string, the client secret in
  # the token request body, no tenant pin and no strict claim checks. The three
  # endpoints may now be left empty and read from the issuer's discovery
  # document instead.
  def change do
    alter table(:oidc_connections) do
      add :scopes, :string, null: false, default: "openid email"
      add :token_endpoint_auth_method, :string, null: false, default: "client_secret_post"
      add :tenant_id, :string
      add :strict_validation, :boolean, null: false, default: false
      modify :authorization_endpoint, :string, null: true, from: {:string, null: false}
      modify :token_endpoint, :string, null: true, from: {:string, null: false}
      modify :jwks_uri, :string, null: true, from: {:string, null: false}
    end
  end
end
