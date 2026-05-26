defmodule Barkpark.Auth.ApiToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "api_tokens" do
    field :token_hash, :string
    field :label, :string
    field :dataset, :string, default: "production"
    field :permissions, {:array, :string}, default: ["read"]
    field :revoked_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id

    # W2 additive seam. Association is `:dataset_entity` because the legacy
    # `dataset` STRING field still occupies the `:dataset` name (dual presence).
    # FK column is `dataset_id`; the string stays authoritative for now.
    belongs_to :dataset_entity, Barkpark.Tenancy.Dataset,
      foreign_key: :dataset_id,
      type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token_hash, :label, :dataset, :permissions, :workspace_id, :revoked_at, :expires_at])
    |> validate_required([:token_hash])
    |> unique_constraint(:token_hash)
  end

  @type t :: %__MODULE__{}

  @doc "Hash a raw token string for storage/lookup."
  def hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end
end
