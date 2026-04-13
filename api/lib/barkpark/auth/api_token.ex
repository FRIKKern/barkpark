defmodule Barkpark.Auth.ApiToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "api_tokens" do
    field :token_hash, :string
    field :label, :string
    field :dataset, :string, default: "production"
    field :permissions, {:array, :string}, default: ["read"]

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token_hash, :label, :dataset, :permissions])
    |> validate_required([:token_hash])
    |> unique_constraint(:token_hash)
  end

  @doc "Hash a raw token string for storage/lookup."
  def hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end
end
