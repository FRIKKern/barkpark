defmodule Barkpark.Repo.Migrations.CreateSamlConnections do
  @moduledoc """
  era-w3-saml — a per-Organization SAML 2.0 Service-Provider connection. Barkpark
  is the SP; the org's IdP is trusted by its signing certificate (`idp_cert_pem`,
  used to build the trusted fingerprint that verifies assertion signatures). One
  connection per org.
  """
  use Ecto.Migration

  def change do
    create table(:saml_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :idp_entity_id, :string, null: false
      # The IdP's Single-Sign-On (redirect) endpoint.
      add :idp_sso_url, :string, null: false
      # The IdP's signing certificate (PEM) — its fingerprint is the trust anchor.
      add :idp_cert_pem, :text, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:saml_connections, [:organization_id])
  end
end
