defmodule Barkpark.Scim.Token do
  @moduledoc """
  A per-Organization SCIM bearer token. Scoped to exactly one organization;
  only the SHA-256 hash is stored (the plaintext is returned once at mint).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "scim_tokens" do
    field :token_hash, :string
    field :label, :string
    field :revoked_at, :utc_datetime_usec

    belongs_to :organization, Barkpark.Tenancy.Organization

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:organization_id, :token_hash, :label, :revoked_at])
    |> validate_required([:organization_id, :token_hash])
    |> assoc_constraint(:organization)
    |> unique_constraint(:token_hash)
  end

  @doc "SHA-256 hex hash of a raw token (storage + lookup)."
  @spec hash_token(binary()) :: String.t()
  def hash_token(raw) when is_binary(raw),
    do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
