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

    # Refuse a sign-in whose groups match no mapping, and remove the seats the
    # connection gave that user (`Barkpark.Sso.Oidc.handle_callback/3`). Off by
    # default.
    field :require_group_match, :boolean, default: false

    # Entra ID settings. Empty endpoints are read from the issuer's discovery
    # document. `strict_validation` turns on the stricter ID token checks and
    # subject matching in `Barkpark.Sso.Oidc`; `tenant_id` pins Entra's `tid`.
    field :scopes, :string, default: "openid email"
    field :token_endpoint_auth_method, :string, default: "client_secret_post"
    field :tenant_id, :string
    field :strict_validation, :boolean, default: false

    # Count the IdP's MFA as Barkpark MFA: `amr` containing "mfa", or `acr`
    # equal to `mfa_acr` when set. Off by default.
    field :trust_idp_mfa, :boolean, default: false
    field :mfa_acr, :string

    # The date the identity provider gave for `client_secret`, recorded by the
    # operator. `Barkpark.Sso.OidcSecretExpiryWarningWorker` warns 30, 14 and 7
    # days ahead and records the last step in `client_secret_expiry_warned_days`.
    # A new date clears that step. Nil means no date is recorded.
    field :client_secret_expires_at, :utc_datetime_usec
    field :client_secret_expiry_warned_days, :integer

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
      :require_group_match,
      :scopes,
      :token_endpoint_auth_method,
      :tenant_id,
      :strict_validation,
      :trust_idp_mfa,
      :mfa_acr,
      :client_secret_expires_at,
      :active
    ])
    |> reset_expiry_warning()
    |> validate_required([:organization_id, :issuer, :client_id])
    |> validate_inclusion(:token_endpoint_auth_method, ~w(client_secret_post client_secret_basic))
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

  # A new expiry date, or a cleared one, starts the warning steps again.
  defp reset_expiry_warning(changeset) do
    if Map.has_key?(changeset.changes, :client_secret_expires_at),
      do: force_change(changeset, :client_secret_expiry_warned_days, nil),
      else: changeset
  end
end
