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

    # Token tier (Barkpark Tickets). "api" is every normal bearer — the
    # fail-closed `Auth.verify_token/1` WHERE clause (`t.kind == "api"`) resolves
    # ONLY these, so every existing consumer rejects a ticket key by
    # construction. "ticket" marks a low-trust ticket key, resolvable solely by
    # `Barkpark.Plugins.Tickets.Keys.verify/1`. `paused_at` mutes a ticket key
    # (→ 403 "key paused") WITHOUT the finality of `revoked_at` (→ 401).
    field :kind, :string, default: "api"
    field :paused_at, :utc_datetime

    # PAT fast-follow fields (additive). `name` is the user-facing description
    # (distinct from the internal `label`); `last_used_at` is the throttled
    # liveness stamp from RequireToken; `created_by` is the audit breadcrumb of
    # the admin who minted a self-service Studio token.
    field :name, :string
    field :last_used_at, :utc_datetime_usec
    field :created_by, :string

    # P5 scoped-share EDIT tokens: the one "ws/project/dataset" this token may
    # write, NULL for every normal token. The OPAQUE `share-edit-*` permission +
    # NO membership row keep the token inert everywhere except a live :edit-share
    # at exactly this scope (enforced by RequireShareEditToken).
    field :share_scope, :string

    # ag-bp-user-identity-auth: optional USER identity for a token. NULL for
    # every existing/machine token (they authenticate exactly as before —
    # verify_token never reads this column). When set (only via the
    # session-gated self-mint, HARD-BOUND to current_user.id), the token
    # resolves to this %User{} on the grantee claim/mine surface, so a terminal
    # `bp access claim` / `bp access mine` carries a user identity.
    belongs_to :owner_user, Barkpark.Accounts.User, type: :binary_id

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
      :share_scope,
      :name,
      :last_used_at,
      :created_by,
      :kind,
      :paused_at,
      :owner_user_id
    ])
    |> validate_required([:token_hash])
    |> unique_constraint(:token_hash)
    # FK-abort containment (Felix W18, the W13 changeset-FK-abort scar-class —
    # sibling of MediaFile/Event/SchemaDefinition/Document). Both columns are
    # real Postgres FKs with `on_delete: :nilify_all` (migrations
    # 20260527110100_add_tenancy_columns + 20260708130000_add_owner_user_id_to_api_tokens,
    # default-derived names `api_tokens_<col>_fkey`). Without these, a mint that
    # references a workspace/user deleted concurrently RAISES Ecto.ConstraintError
    # out of Repo.insert (a 500) instead of returning {:error, changeset}.
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:owner_user_id)
  end

  @type t :: %__MODULE__{}

  @doc "Hash a raw token string for storage/lookup."
  def hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end
end
