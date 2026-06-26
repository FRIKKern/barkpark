defmodule BarkparkCloud.Registry.AgentToken do
  @moduledoc """
  A revocable bearer token an on-box agent uses to authenticate its reports to
  the control plane. Belongs to one Barkpark. Mirrors api/'s
  `Barkpark.Auth.ApiToken` revocable-token pattern:

    * Only a `token_hash` (SHA-256, hex) is stored — NEVER the plaintext. The
      plaintext is returned exactly once at mint time and is unrecoverable after.
    * `revoked_at` / `expires_at` gate validity; a verify must check both.
    * `scope` records the approved-command scope the agent may act within.

  A lookup is by hash: hash the presented plaintext, find the row, then check it
  is neither revoked nor expired. `hash_token/1` is the single source of the
  hashing scheme so mint and verify can never drift.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_tokens" do
    field :token_hash, :string
    field :scope, :string
    field :revoked_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :barkpark, BarkparkCloud.Registry.Barkpark

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token_hash, :scope, :revoked_at, :expires_at, :barkpark_id])
    |> validate_required([:token_hash, :barkpark_id])
    |> assoc_constraint(:barkpark)
    |> unique_constraint(:token_hash)
  end

  @doc "Hash a raw token string for storage / lookup (SHA-256, lowercase hex)."
  @spec hash_token(binary()) :: String.t()
  def hash_token(raw_token) when is_binary(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end
end
