defmodule Barkpark.Sso.SamlConnection do
  @moduledoc """
  A per-Organization SAML 2.0 SP connection. `idp_cert_pem` is the IdP's signing
  certificate; its fingerprint is the trust anchor esaml uses to verify assertion
  signatures.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "saml_connections" do
    field :idp_entity_id, :string
    field :idp_sso_url, :string
    # The IdP's Single Logout endpoint. Nullable — without it, SLO is simply
    # unavailable and Barkpark logout stays local-only.
    field :idp_slo_url, :string
    field :idp_cert_pem, :string
    field :active, :boolean, default: true

    belongs_to :organization, Barkpark.Tenancy.Organization

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(c, attrs) do
    c
    |> cast(attrs, [:organization_id, :idp_entity_id, :idp_sso_url, :idp_slo_url, :idp_cert_pem, :active])
    |> validate_required([:organization_id, :idp_entity_id, :idp_sso_url, :idp_cert_pem])
    |> assoc_constraint(:organization)
    |> unique_constraint(:organization_id)
  end
end
