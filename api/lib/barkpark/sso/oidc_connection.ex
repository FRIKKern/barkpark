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

    # Group-claims → role mapping (era-w7). `groups_claim` names the id_token
    # claim carrying group membership; `group_role_mappings` is the
    # admin-configured group→role map. Claims can only SELECT among these
    # mappings — a group name in a token can never name a role directly.
    field :groups_claim, :string, default: "groups"
    field :group_role_mappings, :map, default: %{}

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
      :groups_claim,
      :group_role_mappings,
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
    |> validate_change(:group_role_mappings, fn :group_role_mappings, map ->
      if is_map(map) and Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end) do
        []
      else
        [group_role_mappings: "must be a map of group name → role name"]
      end
    end)
    |> assoc_constraint(:organization)
    |> unique_constraint(:organization_id)
  end
end
