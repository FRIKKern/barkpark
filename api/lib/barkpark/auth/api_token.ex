defmodule Barkpark.Auth.ApiToken do
  @moduledoc """
  The API-token schema (`api_tokens`) — bearer tokens for the HTTP API. The raw
  token is never stored, only its SHA-256 hash (`hash_token/1`). Each token
  carries a `permissions` list (default `["read"]`), optional `expires_at` /
  `revoked_at`, and tenant scope (workspace + dataset). `share_scope` marks the
  P5 scoped-share EDIT tokens — inert everywhere except a live `:edit-share` at
  that exact scope (enforced by `RequireShareEditToken`).
  """
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

    # P5 scoped-share EDIT tokens: the one "ws/project/dataset" this token may
    # write, NULL for every normal token. The OPAQUE `share-edit-*` permission +
    # NO membership row keep the token inert everywhere except a live :edit-share
    # at exactly this scope (enforced by RequireShareEditToken).
    field :share_scope, :string

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
    |> cast(attrs, [
      :token_hash,
      :label,
      :dataset,
      :permissions,
      :workspace_id,
      :revoked_at,
      :expires_at,
      :share_scope
    ])
    |> validate_required([:token_hash])
    |> unique_constraint(:token_hash)
  end

  @type t :: %__MODULE__{}

  @doc "Hash a raw token string for storage/lookup."
  def hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end
end
