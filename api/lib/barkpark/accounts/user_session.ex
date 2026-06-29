defmodule Barkpark.Accounts.UserSession do
  @moduledoc """
  A login session bearer for a `User`. Hash-at-rest: only `token_hash`
  (SHA-256, lowercase hex) is stored; the plaintext is returned once at mint and
  is unrecoverable. `revoked_at` is the kill switch (logout / sign-out-everywhere);
  `expires_at` bounds lifetime. Mirrors `cloud/`'s `Accounts.UserToken` session
  context and the core `Barkpark.Auth.ApiToken` hashing scheme.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @default_validity_days 30

  schema "user_sessions" do
    field :token_hash, :string
    field :context, :string, default: "session"
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :ip_address, :string
    field :user_agent, :string

    belongs_to :user, Barkpark.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Default session validity, in days."
  def default_validity_days, do: @default_validity_days

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :token_hash,
      :context,
      :expires_at,
      :revoked_at,
      :last_used_at,
      :ip_address,
      :user_agent,
      :user_id
    ])
    |> validate_required([:token_hash, :user_id])
    |> assoc_constraint(:user)
    |> unique_constraint(:token_hash)
  end

  @doc "Hash a raw token for storage / lookup (SHA-256, lowercase hex)."
  @spec hash_token(binary()) :: String.t()
  def hash_token(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end
end
