defmodule BarkparkCloud.Accounts.UserToken do
  @moduledoc """
  A USER session token — the bearer credential a logged-in User presents on the
  control-plane HTTP API (cloud-12a) after `POST /v1/auth/login`. The web-layer
  twin of `Registry.AgentToken`: same hash-at-rest discipline, different
  principal (a human User instead of an on-box agent).

  Mirrors `Registry.AgentToken` deliberately so the two never drift:

    * Only a `token_hash` (SHA-256, lowercase hex) is stored — NEVER the
      plaintext. The plaintext is returned exactly once at mint time
      (`Accounts.create_user_session_token/1`) and is unrecoverable after.
    * `expires_at` gates validity; `verify_user_session_token/1` rejects an
      expired token. (No `revoked_at` yet — explicit logout / revocation is a
      later task. YAGNI.)

  A lookup is by hash: hash the presented plaintext, find the row, then check it
  is not past `expires_at`. `hash_token/1` is the single source of the hashing
  scheme so mint and verify can never drift.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # How long a freshly minted session token stays valid. Sessions are cheap to
  # re-mint (just log in again), so a bounded lifetime is the safe default; a
  # "remember me" / refresh flow is a later concern (YAGNI).
  @default_validity_days 30

  schema "user_tokens" do
    field :token_hash, :string
    field :context, :string, default: "session"
    field :expires_at, :utc_datetime_usec

    belongs_to :user, BarkparkCloud.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Default session-token validity, in days."
  def default_validity_days, do: @default_validity_days

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token_hash, :context, :expires_at, :user_id])
    |> validate_required([:token_hash, :user_id])
    |> assoc_constraint(:user)
    |> unique_constraint(:token_hash)
  end

  @doc "Hash a raw token string for storage / lookup (SHA-256, lowercase hex)."
  @spec hash_token(binary()) :: String.t()
  def hash_token(raw_token) when is_binary(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end
end
