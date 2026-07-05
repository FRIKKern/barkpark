defmodule Barkpark.Sso.OidcConnection do
  @moduledoc """
  A per-Organization OIDC relying-party connection. `client_secret` is encrypted
  at rest via Cloak (`Barkpark.EncryptedBinary`), never returned in the clear.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "oidc_connections" do
    field :issuer, :string
    field :client_id, :string
    field :client_secret, Barkpark.EncryptedBinary, redact: true
    field :authorization_endpoint, :string
    field :token_endpoint, :string
    field :jwks_uri, :string
    field :active, :boolean, default: true

    belongs_to :organization, Barkpark.Tenancy.Organization

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(conn, attrs) do
    conn
    |> cast(attrs, [
      :organization_id,
      :issuer,
      :client_id,
      :client_secret,
      :authorization_endpoint,
      :token_endpoint,
      :jwks_uri,
      :active
    ])
    |> validate_required([
      :organization_id,
      :issuer,
      :client_id,
      :authorization_endpoint,
      :token_endpoint,
      :jwks_uri
    ])
    |> assoc_constraint(:organization)
    |> unique_constraint(:organization_id)
  end
end
